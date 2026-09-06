// TaskRamen.ai
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

/**
 * Browser Viewer Server
 * Streams Chrome tab via CDP screencast, forwards input events back.
 *
 * Listens on 127.0.0.1:3000. Every request and the input WebSocket are gated on
 * a single-use session token minted by POST /start-session; with no active
 * session the server is fail-closed. Reaching it over an SSH port-forward
 * therefore still needs a token, unless VIEWER_ALLOW_NO_TOKEN=1 is set.
 *
 * Usage:
 *   node $CLAUDE_HOME/browser-viewer/server.js
 *
 * Intervention flow:
 *   1. Agent writes /tmp/browser_intervention.json with { task, message }
 *   2. Agent sends Telegram to user with localhost:3000 link
 *   3. User interacts with browser
 *   4. User replies "done" on Telegram
 *   5. Main Claude session creates /tmp/browser_intervention_done.flag
 *   6. Agent polling for that file resumes
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const WebSocket = require('ws');

// ── Token auth ────────────────────────────────────────────────────────────────
const crypto = require('crypto');
const TOKEN_FILE = '/tmp/browser_viewer_token.json';
let activeToken = null; // { value, expiresAt }

// Fail-closed by default: with no active session token, every request is denied.
// The viewer relays a full CDP input channel into the agent's logged-in Chrome,
// and it is reachable through a public cloudflared tunnel — so "no token" must
// never mean "no auth". Set VIEWER_ALLOW_NO_TOKEN=1 only for a purely local
// setup where the sole access path is an SSH tunnel you control.
const ALLOW_NO_TOKEN = process.env.VIEWER_ALLOW_NO_TOKEN === '1';

// How long to wait after the last viewer disconnects before declaring the
// session over (reconnect window). Documented in the browser-intervention skill.
const VIEWER_DISCONNECT_GRACE_MS = 15000;

// Session lifetime. This is an IDLE timeout, not an absolute one: every
// authenticated request pushes it forward (see touchSession). The flows the
// viewer exists for — OTP, then card entry, then a purchase confirmation — run
// well past ten minutes of wall clock, and an absolute cap would kill the
// session under the user mid-form. The viewer page polls /status every 5s while
// it is open, so "idle" genuinely means the user has gone away.
// Override with VIEWER_SESSION_IDLE_MS to tighten or loosen the window.
const SESSION_IDLE_MS = Number(process.env.VIEWER_SESSION_IDLE_MS) > 0
  ? Number(process.env.VIEWER_SESSION_IDLE_MS)
  : 10 * 60 * 1000;
// Persisting on every 5s poll would be pointless disk churn; the on-disk copy
// only has to be good enough to survive a server restart.
const TOKEN_PERSIST_THROTTLE_MS = 60 * 1000;
let lastTokenPersist = 0;

// Whether the agent waiting on this session has already been told it ended.
// Exactly one webhook must fire per session: /done posts "intervention done",
// every other ending posts "viewer closed". Without this an expiring session
// fired NOTHING and the agent's wait loop blocked until the freeze watchdog.
let sessionEndNotified = false;

// Load persisted token on startup — survives server restarts.
//
// Deferred to restoreSession(), called from main() rather than run here at
// module load: an expired token has to notify the agent waiting on it, and
// postToWebhook depends on `webhookSecret`, a const declared below. Calling it
// from here would hit the temporal dead zone and throw.
function restoreSession() {
  let saved;
  try {
    saved = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
  } catch {
    return; // no session to restore
  }
  if (saved && saved.expiresAt > Date.now()) {
    activeToken = saved;
    console.log(`Restored active token (expires in ${Math.round((saved.expiresAt - Date.now()) / 1000)}s)`);
    return;
  }
  // Expired token from a session that ended while the server was down. The
  // agent that opened it is still blocked on its flag file, so this must end
  // the session properly rather than just deleting the file — adopt the token
  // so endSession() can read the agentId off it and post the webhook.
  console.log('Found an expired session token at startup — ending that session');
  activeToken = saved;
  endSession();
}

function persistToken() {
  if (!activeToken) return;
  fs.writeFileSync(TOKEN_FILE, JSON.stringify(activeToken), { mode: 0o600 });
  try { fs.chmodSync(TOKEN_FILE, 0o600); } catch {}
  lastTokenPersist = Date.now();
}

// Push the idle deadline forward. Called on every authenticated request, so an
// open viewer page keeps its own session alive.
function touchSession() {
  if (!activeToken) return;
  activeToken.expiresAt = Date.now() + SESSION_IDLE_MS;
  if (Date.now() - lastTokenPersist > TOKEN_PERSIST_THROTTLE_MS) {
    try { persistToken(); } catch {}
  }
}

function generateToken(agentId) {
  sessionEndNotified = false;
  activeToken = {
    value: crypto.randomUUID(),
    expiresAt: Date.now() + SESSION_IDLE_MS,
    agentId: agentId || null,
  };
  // Persist to disk, owner-only: the token grants remote browser control, so
  // it must not be readable by other local users. chmod covers a pre-existing
  // file created with looser permissions (writeFileSync mode only applies on
  // creation).
  persistToken();
  return activeToken.value;
}

function validateToken(req) {
  // No active token = deny (see ALLOW_NO_TOKEN above). This used to return true,
  // which meant that once a session ended or its 10-minute token expired, every
  // endpoint AND the input WebSocket went unauthenticated while the public
  // tunnel was potentially still up.
  if (!activeToken) return ALLOW_NO_TOKEN;
  // Idle expiry. Tearing the session down here matters: this is how a session
  // ends when the user wanders off instead of tapping "Return to AI".
  if (Date.now() > activeToken.expiresAt) {
    endSession();
    return false;
  }
  const url = new URL(req.url, 'http://localhost');
  const token = url.searchParams.get('token');
  if (!token || token !== activeToken.value) return false;
  touchSession();
  return true;
}

// Terminate the cloudflared quick tunnel, if one is running. Idempotent: a
// missing/stale pidfile is not an error.
//
// The pidfile outlives the process it names — nothing clears it when cloudflared
// crashes or the host reboots — so the PID can have been recycled by an
// unrelated process. Confirm identity before signalling; a wrong SIGTERM here
// would be this server killing something it has no business touching.
function killTunnel() {
  try {
    const pid = parseInt(fs.readFileSync('/tmp/cloudflared.pid', 'utf8').trim(), 10);
    if (pid > 0) {
      let isTunnel = false;
      try {
        // /proc/<pid>/cmdline is NUL-separated; argv[0] is enough to identify it.
        const cmdline = fs.readFileSync(`/proc/${pid}/cmdline`, 'utf8');
        isTunnel = cmdline.split('\0').some(a => a.includes('cloudflared'));
      } catch {
        // No /proc entry: the process is already gone. Nothing to kill.
        isTunnel = false;
      }
      if (isTunnel) process.kill(pid, 'SIGTERM');
      else console.log(`Stale cloudflared pidfile (pid ${pid} is not cloudflared) — not signalling`);
    }
  } catch {}
  try { fs.unlinkSync('/tmp/cloudflared.pid'); } catch {}
}

// Ends the session: drops the token, unpins the target, closes the public entry
// point, and — crucially — tells the waiting agent the session is over.
//
// Every ending goes through here. `notify: false` is for /done, which posts its
// own "intervention done" message instead. Leaving the tunnel up after the token
// died is what made the old code exploitable; not notifying on expiry is what
// left the agent blocked on a flag file that would never appear.
function endSession({ notify = true } = {}) {
  const agentId = activeToken && activeToken.agentId ? activeToken.agentId : null;
  activeToken = null;
  pinnedTarget = null; // clear target pin when session ends
  try { fs.unlinkSync(TOKEN_FILE); } catch {}
  killTunnel();
  if (notify && agentId && !sessionEndNotified) {
    sessionEndNotified = true;
    postToWebhook(`Browser viewer closed [agentId: ${agentId}]`);
  }
}

// ── Load .env for WEBHOOK_CHANNEL_SECRET ─────────────────────────────────────
if (!process.env.WEBHOOK_CHANNEL_SECRET) {
  try {
    const envPath = path.join(__dirname, '..', '.env');
    const envContent = fs.readFileSync(envPath, 'utf-8');
    const match = envContent.match(/^WEBHOOK_CHANNEL_SECRET=(.+)$/m);
    if (match) {
      let val = match[1].trim();
      val = val.replace(/^(['"])(.*)\1$/, '$2');
      process.env.WEBHOOK_CHANNEL_SECRET = val;
    }
  } catch {}
}

// ── Webhook channel helper ───────────────────────────────────────────────────
const webhookSecret = process.env.WEBHOOK_CHANNEL_SECRET || '';

// ── Admin auth for /start-session ────────────────────────────────────────────
// The viewer is exposed to the internet via a cloudflared quick tunnel, and the
// tunnel forwards to localhost — so remoteAddress is 127.0.0.1 for tunnel
// traffic too and can NOT be used to tell the local agent apart from an
// internet visitor. Minting a session token is therefore gated on a shared
// secret that only local agent-side callers can read from .env
// (WEBHOOK_CHANNEL_SECRET, generated at install). Fail closed: no secret
// configured means no tokens can be minted.
function validateAdminSecret(req) {
  if (!webhookSecret) return false;
  const auth = req.headers['authorization'] || '';
  const expected = `Bearer ${webhookSecret}`;
  const a = Buffer.from(auth);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function postToWebhook(message) {
  const data = JSON.stringify({ text: `[SYSTEM CRON TRIGGER]: ${message}` });
  const req = http.request({
    hostname: '127.0.0.1',
    port: 8788,
    path: '/message',
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${webhookSecret}`,
      'Content-Length': Buffer.byteLength(data)
    },
    timeout: 5000
  }, (res) => { res.resume(); });
  req.on('error', (e) => console.error('webhook POST failed:', e.message));
  req.write(data);
  req.end();
}

const CDP_HOST = '127.0.0.1';
const CDP_PORT = 9222;
const VIEWER_PORT = 3000;

// ── Pinned target (set via /start-session to lock viewer to a specific tab) ──
let pinnedTarget = null; // { targetId?, targetUrl? }

// ── Get active page target from CDP ──────────────────────────────────────────
async function getPageTarget(filter) {
  const f = filter || pinnedTarget || {};
  return new Promise((resolve, reject) => {
    http.get(`http://${CDP_HOST}:${CDP_PORT}/json/list`, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        let targets;
        try {
          targets = JSON.parse(data);
          if (!Array.isArray(targets)) throw new Error('response is not an array');
        } catch (err) {
          return reject(new Error(`CDP /json/list returned invalid response (Chrome still booting?): ${err.message}`));
        }
        const realPages = targets.filter(t => t.type === 'page' && !t.url.startsWith('chrome://'));
        let page = null;
        // Priority 1: exact target ID match
        if (f.targetId) {
          page = realPages.find(t => t.id === f.targetId);
        }
        // Priority 2: URL substring match
        if (!page && f.targetUrl) {
          page = realPages.find(t => t.url.includes(f.targetUrl));
        }
        // Fallback: first non-chrome page (original behavior)
        if (!page) {
          page = realPages[0] || null;
        }
        if (!page) return reject(new Error('No active page target found'));
        resolve(page);
      });
    }).on('error', reject);
  });
}

// ── CDP WebSocket connection ──────────────────────────────────────────────────
class CDPSession {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.callbacks = new Map();
    this.eventHandlers = new Map();
    this.msgId = 1;

    this.ws.on('message', (data) => {
      const msg = JSON.parse(data);
      if (msg.id && this.callbacks.has(msg.id)) {
        const { resolve, reject } = this.callbacks.get(msg.id);
        this.callbacks.delete(msg.id);
        msg.error ? reject(new Error(msg.error.message)) : resolve(msg.result);
      } else if (msg.method) {
        const handler = this.eventHandlers.get(msg.method);
        if (handler) handler(msg.params);
      }
    });

    // If the socket dies, fail every in-flight send() — otherwise a caller
    // awaiting a reply that will never arrive hangs forever (this is what
    // wedged /start-session when Chrome restarted mid-handshake).
    const failPending = (err) => {
      for (const { reject } of this.callbacks.values()) reject(err);
      this.callbacks.clear();
    };
    this.ws.on('close', () => failPending(new Error('CDP WebSocket closed')));
    this.ws.on('error', (err) => failPending(err));
  }

  ready() {
    return new Promise((resolve, reject) => {
      if (this.ws.readyState === WebSocket.OPEN) return resolve();
      this.ws.on('open', resolve);
      this.ws.on('error', reject);
    });
  }

  send(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = this.msgId++;
      this.callbacks.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  on(event, handler) {
    this.eventHandlers.set(event, handler);
  }
}

// ── Module-level CDP state (allows reconnect on tab switch) ──────────────────
const IPHONE_W = 390, IPHONE_H = 844;
let cdp = null;
let currentUrl = '';
let currentTitle = '';
let latestFrame = null;
let currentTargetId = null;
let broadcast = () => {}; // set after wss is created

async function connectToTarget(target) {
  // Tear down existing session
  if (cdp) {
    try { await cdp.send('Page.stopScreencast'); } catch {}
    try { cdp.ws.close(); } catch {}
    cdp = null;
  }

  currentTargetId = target.id;
  currentUrl = target.url;
  currentTitle = target.title;
  latestFrame = null;

  console.log(`Connecting to: ${target.title} (${target.url})`);
  try {
    await connectSession(target);
  } catch (err) {
    // Failed partway (e.g. Chrome died mid-handshake). Clear the half-set
    // state — otherwise watchActiveTab() sees currentTargetId already equal
    // to this target's id and never retries the connection.
    if (cdp) { try { cdp.ws.close(); } catch {} }
    cdp = null;
    currentTargetId = null;
    latestFrame = null;
    throw err;
  }
}

async function connectSession(target) {
  const session = new CDPSession(target.webSocketDebuggerUrl);
  await session.ready();
  cdp = session;

  // If Chrome dies or the tab closes (e.g. nightly Chrome restart), drop the
  // stale session so watchActiveTab() reconnects to the next available target
  // instead of streaming the last frame forever.
  session.ws.on('close', () => {
    if (cdp === session) {
      console.log('CDP connection closed — waiting for a target to reconnect');
      cdp = null;
      currentTargetId = null;
      latestFrame = null;
    }
  });

  // Use the local `session` (not the global `cdp`) for the rest of the setup
  // and the event handlers, so a concurrent connect that reassigns `cdp`
  // can't interleave with a half-initialized session.
  await session.send('Page.enable');
  await session.send('Input.enable').catch(() => {});

  await session.send('Emulation.setDeviceMetricsOverride', {
    width: IPHONE_W, height: IPHONE_H, deviceScaleFactor: 3, mobile: true,
  });
  await session.send('Emulation.setUserAgentOverride', {
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1',
    acceptLanguage: 'en-US,en;q=0.9',
    platform: 'iPhone',
  });
  await session.send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  console.log('iPhone 14 profile applied (390×844, iOS 16.6 Safari UA)');

  session.on('Page.frameNavigated', (params) => {
    if (cdp !== session) return; // stale session — ignore
    if (params.frame.parentId === undefined) {
      currentUrl = params.frame.url;
      currentTitle = params.frame.name || currentUrl;
      broadcast({ type: 'navigate', url: currentUrl });
    }
  });

  await session.send('Page.startScreencast', {
    format: 'jpeg', quality: 80,
    maxWidth: IPHONE_W, maxHeight: IPHONE_H, everyNthFrame: 1,
  });

  session.on('Page.screencastFrame', async (params) => {
    if (cdp !== session) return; // stale session — ignore
    latestFrame = params.data;
    await session.send('Page.screencastFrameAck', { sessionId: params.sessionId }).catch(() => {});
    broadcast({ type: 'frame', data: params.data, url: currentUrl });
  });
}

// Poll every 2s — if the resolved target changed, reconnect
// When pinnedTarget is set, this only reconnects if that specific tab's ID changed
function watchActiveTab() {
  setInterval(async () => {
    try {
      const target = await getPageTarget();
      if (target.id !== currentTargetId) {
        console.log(`Active tab changed → ${target.title}`);
        await connectToTarget(target);
        broadcast({ type: 'navigate', url: currentUrl });
      }
    } catch {}
  }, 2000);
}

// ── Main ──────────────────────────────────────────────────────────────────────
async function main() {
  // Adopt or wind up any session left behind by a previous process. Must run
  // before the server accepts requests, and after the module-level consts it
  // depends on are initialised.
  restoreSession();

  // ── HTTP server ─────────────────────────────────────────────────────────────
  const htmlPath = path.join(__dirname, 'index.html');
  const server = http.createServer((req, res) => {
    // Route on the pathname so endpoints keep working when the viewer page
    // appends its ?token=… query (required now that /done and /status are
    // token-gated like everything else).
    const pathname = new URL(req.url, 'http://localhost').pathname;

    // /start-session mints a viewer token and is reachable through the public
    // tunnel — it authenticates via the shared admin secret (see
    // validateAdminSecret) instead of the viewer token.
    const isAdminEndpoint = pathname === '/start-session';
    // Everything else (including /done, which the viewer page calls with its
    // token) is gated on the session token — UNCONDITIONALLY. The old
    // `activeToken && !validateToken(req)` form skipped the check entirely
    // whenever no token was active, which is exactly the state a session ends in.
    if (!isAdminEndpoint && !validateToken(req)) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('Access denied: invalid or expired token');
      return;
    }

    if (pathname === '/') {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      fs.createReadStream(htmlPath).pipe(res);
    } else if (pathname === '/snapshot' && latestFrame) {
      res.writeHead(200, { 'Content-Type': 'image/jpeg' });
      res.end(Buffer.from(latestFrame, 'base64'));
    } else if (pathname === '/status') {
      // Return current intervention context if any
      let intervention = null;
      try {
        intervention = JSON.parse(fs.readFileSync('/tmp/browser_intervention.json', 'utf8'));
      } catch {}
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ url: currentUrl, title: currentTitle, intervention }));
    } else if (pathname === '/done' && req.method === 'POST') {
      const agentId = activeToken && activeToken.agentId ? activeToken.agentId : null;
      // notify:false — this path sends its own, more specific message below.
      // Marking the session notified first stops a later teardown double-posting.
      sessionEndNotified = true;
      endSession({ notify: false }); // drops the token AND kills the tunnel
      // Notify the waiting agent via webhook channel → main Claude session
      if (agentId) {
        postToWebhook(`Browser intervention done [agentId: ${agentId}]`);
      } else {
        // Legacy fallback: write the generic done flag
        fs.writeFileSync('/tmp/browser_intervention_done.flag', '');
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    } else if (pathname === '/start-session' && req.method === 'POST') {
      if (!validateAdminSecret(req)) {
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end(webhookSecret
          ? 'Access denied: invalid admin secret'
          : 'Access denied: WEBHOOK_CHANNEL_SECRET not configured — token minting disabled');
        return;
      }
      let agentId = null;
      let body = '';
      req.on('data', chunk => body += chunk);
      req.on('end', async () => {
        let parsed = {};
        try { parsed = JSON.parse(body); } catch {}
        agentId = parsed.agentId || null;

        // Pin viewer to a specific CDP target if provided
        if (parsed.targetId || parsed.targetUrl) {
          pinnedTarget = {};
          if (parsed.targetId) pinnedTarget.targetId = parsed.targetId;
          if (parsed.targetUrl) pinnedTarget.targetUrl = parsed.targetUrl;
          console.log('Pinned target:', JSON.stringify(pinnedTarget));
          // Reconnect in the background — never block the token response on
          // the CDP handshake (a wedged handshake used to hang this request,
          // and the caller's curl, forever). watchActiveTab() retries every
          // 2s anyway, so the viewer still converges on the pinned tab.
          (async () => {
            const target = await getPageTarget(pinnedTarget);
            if (target.id !== currentTargetId) {
              await connectToTarget(target);
              broadcast({ type: 'navigate', url: currentUrl });
            }
          })().catch(e => console.error('Failed to connect to pinned target:', e.message));
        } else {
          pinnedTarget = null; // no pinning — use default behavior
        }

        const token = generateToken(agentId);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ token, expiresAt: activeToken.expiresAt }));
      });
      return;
    } else {
      res.writeHead(404);
      res.end('Not found');
    }
  });

  // ── WebSocket server ─────────────────────────────────────────────────────────
  const wss = new WebSocket.Server({ server });
  const clients = new Set();

  // Wire up the module-level broadcast to real clients
  broadcast = (msg) => {
    const str = JSON.stringify(msg);
    for (const c of clients) {
      if (c.readyState === WebSocket.OPEN) c.send(str);
    }
  };

  wss.on('connection', (ws, req) => {
    // Validate unconditionally — this socket carries Input.* CDP commands, i.e.
    // full mouse/keyboard control of the agent's browser.
    if (!validateToken(req)) {
      ws.close(1008, 'Invalid token');
      return;
    }
    clients.add(ws);
    console.log(`Viewer connected (${clients.size} total)`);
    // Send current URL immediately
    ws.send(JSON.stringify({ type: 'navigate', url: currentUrl }));
    // Send latest frame if available
    if (latestFrame) ws.send(JSON.stringify({ type: 'frame', data: latestFrame, url: currentUrl }));

    ws.on('message', async (data) => {
      // JSON.parse must stay inside the try: a malformed frame would otherwise
      // become an unhandled rejection and kill the whole viewer process.
      try {
        const msg = JSON.parse(data);
        if (msg.type === 'mouseEvent') {
          await cdp.send('Input.dispatchMouseEvent', {
            type: msg.eventType, // mousePressed, mouseReleased, mouseMoved
            x: msg.x,
            y: msg.y,
            button: msg.button || 'left',
            clickCount: msg.clickCount || 1,
            modifiers: msg.modifiers || 0,
          });
        } else if (msg.type === 'touchEvent') {
          await cdp.send('Input.dispatchTouchEvent', {
            type: msg.eventType, // touchStart, touchMove, touchEnd
            touchPoints: msg.touchPoints,
            modifiers: msg.modifiers || 0,
          });
        } else if (msg.type === 'scroll') {
          await cdp.send('Input.dispatchMouseEvent', {
            type: 'mouseWheel',
            x: msg.x,
            y: msg.y,
            deltaX: msg.deltaX || 0,
            deltaY: msg.deltaY || 0,
          });
        } else if (msg.type === 'keyEvent') {
          await cdp.send('Input.dispatchKeyEvent', {
            type: msg.eventType, // keyDown, keyUp, char
            key: msg.key,
            text: msg.text || '',
            code: msg.code || '',
            windowsVirtualKeyCode: msg.keyCode || 0,
            nativeVirtualKeyCode: msg.keyCode || 0,
            modifiers: msg.modifiers || 0,
          });
        } else if (msg.type === 'navigate') {
          if (msg.url === '__back__') {
            await cdp.send('Runtime.evaluate', { expression: 'history.back()' });
          } else if (msg.url === '__forward__') {
            await cdp.send('Runtime.evaluate', { expression: 'history.forward()' });
          } else {
            await cdp.send('Page.navigate', { url: msg.url });
          }
        }
      } catch (err) {
        console.error('Input error:', err.message);
      }
    });

    ws.on('close', () => {
      clients.delete(ws);
      console.log(`Viewer disconnected (${clients.size} remaining)`);
      // If last viewer disconnects with session still active, notify agent after
      // a grace period, then end the session. Ending it matters as much as the
      // notification: closing the tab without tapping "Return to AI ✓" is the
      // normal way a session dies, and it must not leave a live public tunnel
      // behind. The grace period is the reconnect window (a mobile network blip
      // should not tear the session down) and is documented in SKILL.md — keep
      // the two in step if you change it.
      if (clients.size === 0 && activeToken && activeToken.agentId) {
        const agentId = activeToken.agentId;
        setTimeout(() => {
          // Only fire if still no clients and the session was not already ended
          // by /done. endSession posts the "viewer closed" webhook itself.
          if (clients.size === 0 && activeToken && activeToken.agentId === agentId) {
            endSession();
          }
        }, VIEWER_DISCONNECT_GRACE_MS);
      }
    });
  });

  server.listen(VIEWER_PORT, '127.0.0.1', () => {
    console.log(`Browser viewer running at http://localhost:${VIEWER_PORT}`);
    console.log(`(SSH tunnel: ssh -L ${VIEWER_PORT}:localhost:${VIEWER_PORT} user@<server>)`);
  });

  // Initial CDP connect is best-effort: right after the nightly Chrome restart
  // there may be no non-chrome:// tab yet, or CDP :9222 may still be booting.
  // The server must come up regardless — watchActiveTab() keeps polling and
  // connects as soon as an eligible target appears.
  try {
    const target = await getPageTarget();
    await connectToTarget(target);
  } catch (err) {
    console.log(`No CDP target yet (${err.message}) — will connect when a tab appears`);
  }
  watchActiveTab();

  // Idle-expiry sweep. validateToken() expires a session lazily, on an
  // incoming request — but a link the user never opens produces no requests
  // at all, so without a timer such a session would never end: no "closed"
  // webhook, no flag file, and the agent waiting on the flags blocks until
  // its freeze watchdog. Sweep the deadline on a timer so every session ends
  // through endSession() (webhook + tunnel teardown) even when nobody ever
  // connected.
  setInterval(() => {
    if (activeToken && Date.now() > activeToken.expiresAt) endSession();
  }, 30 * 1000);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
