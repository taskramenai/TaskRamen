// common.mjs — shared OAuth helpers for the rewrite scripts.
//
// Design rules (see README.md):
//   • NO site-specific hardcoding — endpoints/scopes/client_id come from args or
//     from standard RFC discovery. There is no provider table.
//   • NO secret storage — nothing is written to disk. Results are EMITTED as JSON
//     events on stdout; the caller (Claude) is responsible for storing them.
//
// Pure Node built-ins (crypto/http/child_process/fetch). Zero dependencies.

import crypto from 'node:crypto';
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';

export const b64url = (buf) =>
  Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

/** PKCE verifier + S256 challenge (RFC 7636). */
export const pkce = () => {
  const verifier = b64url(crypto.randomBytes(32));
  const challenge = b64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
};

/** Opaque single-use CSRF state. */
export const mkState = () => b64url(crypto.randomBytes(24));

/** Emit one JSON event per line on stdout (the machine interface). */
export const emit = (obj) => process.stdout.write(JSON.stringify(obj) + '\n');

/** Emit an error event and exit with a specific code. */
export const fail = (exitCode, code, message, extra = {}) => {
  emit({ event: 'error', code, message, ...extra });
  process.exit(exitCode);
};

// ---- standard discovery (RFC 9728 -> RFC 8414). Protocol, not site-specific. ----

async function getJson(url) {
  const r = await fetch(url, { headers: { accept: 'application/json' } });
  if (!r.ok) throw new Error(`GET ${url} -> ${r.status}`);
  return r.json();
}

function wellKnown(base, suffix) {
  const u = new URL(base);
  const path = u.pathname.replace(/\/$/, '');
  u.pathname = `/.well-known/${suffix}${path}`;
  return u.toString();
}

/** MCP URL -> { issuer, authorization_endpoint, token_endpoint, registration_endpoint, scopes, resource }. */
export async function discover(mcpUrl) {
  let pr = null;
  try { pr = await getJson(wellKnown(mcpUrl, 'oauth-protected-resource')); } catch { /* optional */ }
  const issuer = pr?.authorization_servers?.[0] || new URL(mcpUrl).origin;
  let as = null;
  for (const sfx of ['oauth-authorization-server', 'openid-configuration']) {
    try {
      const m = await getJson(wellKnown(issuer, sfx));
      if (m.authorization_endpoint && m.token_endpoint) { as = m; break; }
    } catch { /* try next */ }
  }
  if (!as) throw new Error(`no authorization-server metadata for issuer ${issuer}`);
  return {
    issuer,
    authorization_endpoint: as.authorization_endpoint,
    token_endpoint: as.token_endpoint,
    registration_endpoint: as.registration_endpoint || null,
    scopes: pr?.scopes_supported || as.scopes_supported || [],
    resource: pr?.resource || mcpUrl,
  };
}

/** Dynamic Client Registration (RFC 7591). Public PKCE client (no secret). */
export async function registerClient(registrationEndpoint, redirectUri, scopes) {
  const body = {
    client_name: 'connect',
    redirect_uris: [redirectUri],
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    token_endpoint_auth_method: 'none',
  };
  if (scopes?.length) body.scope = scopes.join(' ');
  const r = await fetch(registrationEndpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`DCR failed ${r.status}: ${t.slice(0, 200)}`);
  return JSON.parse(t); // { client_id, ... }
}

/** Build the authorization URL (OAuth 2.1 + PKCE S256). */
export function buildAuthUrl({ authorizationEndpoint, clientId, redirectUri, state, challenge, scopes, resource, extra }) {
  const u = new URL(authorizationEndpoint);
  u.searchParams.set('response_type', 'code');
  u.searchParams.set('client_id', clientId);
  u.searchParams.set('redirect_uri', redirectUri);
  u.searchParams.set('state', state);
  u.searchParams.set('code_challenge', challenge);
  u.searchParams.set('code_challenge_method', 'S256');
  if (scopes?.length) u.searchParams.set('scope', Array.isArray(scopes) ? scopes.join(' ') : scopes);
  if (resource) u.searchParams.set('resource', resource);
  for (const [k, v] of Object.entries(extra || {})) u.searchParams.set(k, v);
  return u.toString();
}

/** Exchange an authorization code for tokens. Returns the raw token response. */
export async function exchange({ tokenEndpoint, code, redirectUri, clientId, clientSecret, verifier, resource }) {
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirectUri,
    client_id: clientId,
    code_verifier: verifier,
  });
  if (resource) body.set('resource', resource);
  const headers = { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' };
  if (clientSecret) headers.authorization = 'Basic ' + Buffer.from(`${clientId}:${clientSecret}`).toString('base64');
  const r = await fetch(tokenEndpoint, { method: 'POST', headers, body });
  const t = await r.text();
  if (!r.ok) throw new Error(`token exchange failed ${r.status}: ${t.slice(0, 300)}`);
  return JSON.parse(t);
}

/** Refresh an access token with a refresh_token grant. Returns the raw response. */
export async function refresh({ tokenEndpoint, refreshToken, clientId, clientSecret, scopes, resource }) {
  const body = new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken, client_id: clientId });
  if (scopes?.length) body.set('scope', Array.isArray(scopes) ? scopes.join(' ') : scopes);
  if (resource) body.set('resource', resource);
  const headers = { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' };
  if (clientSecret) headers.authorization = 'Basic ' + Buffer.from(`${clientId}:${clientSecret}`).toString('base64');
  const r = await fetch(tokenEndpoint, { method: 'POST', headers, body });
  const t = await r.text();
  if (!r.ok) throw new Error(`token refresh failed ${r.status}: ${t.slice(0, 300)}`);
  return JSON.parse(t);
}

/** Pull code/state (or an error) out of a pasted redirect URL, tolerating noise. */
export function parseCallback(pasted) {
  const m = String(pasted).trim().match(/https?:\/\/\S+/);
  const cand = (m ? m[0] : String(pasted).trim()).replace(/[)\]>.,]+$/, '');
  let params;
  try { params = new URL(cand).searchParams; }
  catch { const q = cand.indexOf('?'); params = new URLSearchParams(q >= 0 ? cand.slice(q + 1) : cand); }
  if (params.get('error')) return { error: params.get('error'), error_description: params.get('error_description') || undefined };
  return { code: params.get('code') || undefined, state: params.get('state') || undefined };
}

// ---- mailbox: ephemeral 127.0.0.1 listener for /callback + /healthz (DCR flow) ----
//
// Endpoints:
//   /healthz   -> nonce (tunnel liveness probe; used by verifyLive)
//   /callback  -> catches the OAuth redirect (via the tunnel), resolves waitForCode
//   /authurl   -> LONG-POLL for the auth URL (daemon mode). Held open until
//                 setAuthUrl()/setAuthError() is called, then answered. Lets a
//                 foreground caller `curl` the URL synchronously over loopback
//                 without the secret-free URL ever touching a file. Non-secret.
//   /status    -> {ready, error} snapshot (non-blocking poll alternative)

export async function startMailbox({ expectedState, timeoutMs = 11 * 60_000, port = 0 } = {}) {
  const nonce = b64url(crypto.randomBytes(16));
  let resolve, reject;
  const waitForCode = new Promise((res, rej) => { resolve = res; reject = rej; });

  // auth-url long-poll state: null until set, then { url } or { error }.
  let authState = null;
  let waiters = [];
  // Always 200 — the caller distinguishes by the `event` field. (A 5xx would make
  // `curl --retry` treat the setup error as transient and retry it for ~seconds.)
  const answerAuth = (res) => {
    const body = authState?.url
      ? { event: 'auth_url', url: authState.url }
      : { event: 'error', message: authState?.error || 'unknown error' };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  };
  const flushAuth = () => { for (const res of waiters.splice(0)) { try { answerAuth(res); } catch { /* client gone */ } } };

  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://127.0.0.1');
    if (u.pathname === '/healthz') { res.writeHead(200, { 'content-type': 'text/plain' }); res.end(nonce); return; }
    if (u.pathname === '/status') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ready: !!authState?.url, error: authState?.error || null }));
      return;
    }
    if (u.pathname === '/authurl') {
      if (authState) { answerAuth(res); return; }
      waiters.push(res);
      req.on('close', () => { waiters = waiters.filter((w) => w !== res); });
      return;
    }
    if (u.pathname === '/callback') {
      const err = u.searchParams.get('error');
      const code = u.searchParams.get('code');
      const st = u.searchParams.get('state');
      const ok = !err && code && st === expectedState;
      res.writeHead(ok ? 200 : 400, { 'content-type': 'text/html' });
      res.end(`<html><body><h3>${ok ? 'Done' : 'Error'}</h3><p>You can close this tab.</p></body></html>`);
      if (err) reject(new Error('callback error: ' + err));
      else if (st !== expectedState) reject(new Error('state mismatch on callback'));
      else if (code) resolve({ code });
      return;
    }
    res.writeHead(404); res.end();
  });
  const timer = setTimeout(() => reject(new Error('callback timeout')), timeoutMs);
  // Reject (don't crash) if the bind fails — e.g. EADDRINUSE when daemon mode's
  // fixed --port is already held by a previous/concurrent daemon. Without this
  // handler the async 'error' event is unhandled and takes down the process.
  await new Promise((res, rej) => {
    server.once('error', (e) => { clearTimeout(timer); rej(e.code === 'EADDRINUSE' ? new Error(`PORT_IN_USE: 127.0.0.1:${port} is already in use (another connect daemon?)`) : e); });
    server.listen(port, '127.0.0.1', () => { server.removeAllListeners('error'); res(); });
  });
  return {
    port: server.address().port,
    nonce,
    waitForCode: waitForCode.finally(() => clearTimeout(timer)),
    // daemon mode: publish the auth URL (or a setup error) to /authurl waiters.
    setAuthUrl: (url) => { authState = { url }; flushAuth(); },
    setAuthError: (message) => { authState = { error: String(message) }; flushAuth(); },
    close: () => {
      for (const res of waiters.splice(0)) { try { res.destroy(); } catch { /* noop */ } }
      try { server.closeAllConnections?.(); } catch { /* noop */ }
      try { server.close(); } catch { /* noop */ }
      clearTimeout(timer);
    },
  };
}

// ---- kernel keyring sink (keyutils `keyctl`) — kernel memory, not disk ----
//
// Used by the DCR daemon to hand credentials to the caller (Claude) without the
// long-lived refresh_token ever touching stdout, a file, or a log. The caller
// reads it back with `keyctl print %user:<desc>` and clears it after storing.

/** True if the `keyctl` binary is present and runnable. */
export function keyctlAvailable() {
  return !spawnSync('keyctl', ['show'], { stdio: 'ignore' }).error;
}

/**
 * True only if the keyring can ACTUALLY hold a key on `keyring` right now — a real
 * write→unlink round-trip. Unlike keyctlAvailable() (which only checks the binary
 * runs), this catches the cases that bite in practice: `add_key` blocked by a
 * container seccomp profile (Docker/Podman default), a per-uid keyring quota, or a
 * read-only/absent keyring. Run as the daemon preflight so the flow never starts —
 * and the user never approves — when the credentials could not be stored.
 */
export function keyringUsable(keyring = '@s') {
  const probe = spawnSync('keyctl', ['padd', 'user', 'connect:preflight', keyring], { input: 'probe', encoding: 'utf8' });
  if (probe.error || probe.status !== 0) return false;
  const id = String(probe.stdout).trim();
  // unlink (not revoke) the probe key so it leaves the ring immediately and frees
  // the per-uid quota — a revoked key lingers as a tombstone until GC.
  if (id) spawnSync('keyctl', ['unlink', id, keyring], { stdio: 'ignore' });
  return true;
}

/**
 * Store `payload` as a `user`-type key under `desc` in `keyring` (default the
 * session keyring `@s` — see connectdcr runDaemon: the harvester must POSSESS the
 * key to read it, which holds for the shared @s but not @u). Optionally expire it
 * after `timeoutSec`. Returns the numeric key id. Throws if keyctl is missing/fails.
 */
export function keyringStore(desc, payload, { keyring = '@s', timeoutSec } = {}) {
  const r = spawnSync('keyctl', ['padd', 'user', desc, keyring], { input: payload, encoding: 'utf8' });
  if (r.error) throw new Error('keyctl not available: ' + r.error.message);
  if (r.status !== 0) throw new Error('keyctl padd failed: ' + String(r.stderr || '').trim());
  const id = String(r.stdout).trim();
  if (timeoutSec) {
    // Best-effort, but warn if it fails — the auto-expiry guarantee depends on it.
    const t = spawnSync('keyctl', ['timeout', id, String(timeoutSec)], { encoding: 'utf8' });
    if (t.error || t.status !== 0) {
      process.stderr.write(`[connectdcr] warning: could not set expiry on key ${id}: ${String(t.stderr || t.error?.message || '').trim()}\n`);
    }
  }
  return id;
}

// ---- cloudflared quick tunnel + liveness verify (Apache-2.0 binary, external) ----

function startQuickTunnel(localPort, { bin, startupMs }) {
  return new Promise((resolve, reject) => {
    const ps = spawn(bin, ['tunnel', '--no-autoupdate', '--url', `http://localhost:${localPort}`],
      { stdio: ['ignore', 'pipe', 'pipe'] });
    let done = false;
    const re = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i;
    const onData = (d) => { const m = String(d).match(re); if (m && !done) { done = true; resolve({ url: m[0], close: () => { try { ps.kill('SIGTERM'); } catch { /* noop */ } } }); } };
    ps.stdout.on('data', onData);
    ps.stderr.on('data', onData);
    ps.on('error', (e) => { if (!done) { done = true; reject(new Error(`cloudflared spawn failed: ${e.message}`)); } });
    setTimeout(() => { if (!done) { done = true; try { ps.kill(); } catch { /* noop */ } reject(new Error('cloudflared did not print a tunnel URL in time')); } }, startupMs);
  });
}

async function verifyLive(url, nonce, { attempts, delayMs, timeoutMs }) {
  for (let i = 0; i < attempts; i++) {
    try {
      const ctl = new AbortController();
      const to = setTimeout(() => ctl.abort(), timeoutMs);
      const r = await fetch(url + '/healthz', { signal: ctl.signal });
      clearTimeout(to);
      if (r.ok && (await r.text()).includes(nonce)) return true;
    } catch { /* warming up */ }
    await new Promise((r) => setTimeout(r, delayMs));
  }
  return false;
}

/** Start a quick tunnel and confirm it round-trips the mailbox nonce; regenerate if born dead. */
export async function startVerifiedTunnel(localPort, nonce, {
  bin = 'cloudflared', attempts = 3, startupMs = 45_000,
  verifyAttempts = 10, verifyDelayMs = 2000, verifyTimeoutMs = 4000, log = () => {},
} = {}) {
  for (let a = 1; a <= attempts; a++) {
    const t = await startQuickTunnel(localPort, { bin, startupMs });
    const live = await verifyLive(t.url, nonce, { attempts: verifyAttempts, delayMs: verifyDelayMs, timeoutMs: verifyTimeoutMs });
    if (live) return t;
    t.close();
    log(`tunnel ${t.url} not live; regenerating (${a}/${attempts})`);
  }
  throw new Error(`could not get a live quick tunnel after ${attempts} attempts`);
}

/** Minimal arg parser: --key value, --flag (boolean), repeatable --extra k=v. Positionals in _. */
export function args(argv) {
  const out = { _: [], extra: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (k === 'extra') { const kv = argv[++i] || ''; const e = kv.indexOf('='); if (e > 0) out.extra[kv.slice(0, e)] = kv.slice(e + 1); }
      else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) out[k] = argv[++i];
      else out[k] = true;
    } else out._.push(a);
  }
  return out;
}
