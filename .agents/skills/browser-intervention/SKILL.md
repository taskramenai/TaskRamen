---
name: browser-intervention
description: Hand live control of the automated browser to the user when a task cannot proceed without them — a bot check or captcha, a one-time passcode, card or bank details, an OAuth approval screen, or a final confirmation that charges money. Publishes a time-limited viewer link over a Cloudflare tunnel so the user can act from their phone, then resumes the automation when they are done. Use when browser automation is blocked on something only the human can or should do.
allowed-tools: Bash
---

# Browser Intervention — Hand Off to the User

## When to trigger user intervention

Trigger intervention in these situations ONLY:

1. **Captcha or bot check** — hand off; do NOT try to defeat it. A captcha is the site asking for a human, so give it one. Never attempt to solve, bypass or automate around a challenge.
2. **Financial info required** — credit card, bank details, CVV. NEVER store or handle these; always hand off to user
3. **Final confirmation involving real money** — any transaction that charges money. Always get user confirmation before submitting
4. **OTP required** — EXCEPT when using credentials for the service account (its email is in .env: SERVICE_GOOGLE_WORKSPACE_RW_EMAIL) — that account's OTP can be retrieved from Gmail
5. **OAuth / third-party login confirmation** — any screen asking the user to approve access or confirm OAuth permissions

For everything else (login with known credentials, form filling, navigation, non-money confirmations) — handle it yourself.

---

When you reach a point requiring user intervention:

## Step 1 — Generate agent key and start tunnel
```bash
AGENT_KEY=$(python3 -c "import uuid; print(uuid.uuid4().hex[:16])")
LINK=$(bash $CLAUDE_HOME/browser-viewer/start-tunnel.sh "<current_page_url>" "$AGENT_KEY")
echo "Link: $LINK"
```
Pass the current page URL so it knows which tab to keep. The URL is also forwarded to `server.js` via `/start-session` as `targetUrl` — this **pins the viewer to that specific tab** so it won't accidentally connect to a different tab even if multiple tabs are open. The AGENT_KEY is bound to the session — when user taps "Return to AI ✓", server.js calls inject.sh with this key to unblock the waiting agent.

> **Long Puppeteer flows** (any multi-step run that must not be interrupted): use `start-tunnel-bg.sh` in background BEFORE starting Puppeteer, then get the token inline after.

## Step 2 — Write intervention context
```bash
cat > /tmp/browser_intervention.json << 'EOF'
{
  "task": "short description of what you were doing",
  "message": "Please [specific instruction, e.g. solve the captcha / confirm the form / complete the login]. Tap 'Return to AI' when finished."
}
EOF
```

## Step 3 — Start tunnel and generate token
```bash
# Kill any existing tunnel
[ -f /tmp/cloudflared.pid ] && kill $(cat /tmp/cloudflared.pid) 2>/dev/null; rm -f /tmp/cloudflared.pid /tmp/cloudflared.log

# Start tunnel
PUBLIC_URL=$(bash $CLAUDE_HOME/browser-viewer/start-tunnel.sh)

# Generate token — pass targetUrl to pin viewer to the correct tab
# (--max-time so a wedged server fails fast instead of hanging the shell;
#  if it fails, restart server.js and retry once)
# /start-session requires the shared secret from .env — without it the server
# refuses to mint tokens (the endpoint is reachable through the public tunnel).
# Strip the surrounding quotes write_env adds, else the Bearer header 403s.
VIEWER_SECRET=$(grep '^WEBHOOK_CHANNEL_SECRET=' "$CLAUDE_HOME/.env" | head -1 | cut -d= -f2- | sed -E "s/^(['\"])(.*)\1\$/\2/")
TOKEN=$(curl -s --max-time 15 -X POST http://localhost:3000/start-session \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${VIEWER_SECRET}" \
  -d "{\"agentId\": \"${AGENT_KEY}\", \"targetUrl\": \"<current_page_url>\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")

LINK="${PUBLIC_URL}/?token=${TOKEN}"
echo "One-click link: $LINK"
```

## Step 4 — Screenshot + Send Telegram message
```bash
npx agent-browser --cdp 9222 screenshot /tmp/intervention_screenshot.png
```

Then use mcp__plugin_telegram_telegram__reply:
- chat_id: (see .env: TELEGRAM_CHAT_ID)
- files: ["/tmp/intervention_screenshot.png"]
- text: "🔴 [ONE LINE: why intervention is needed, e.g. 'OTP required to finish signing in' or 'Card details needed to complete this payment']\n\nTap to open browser (expires after 10 min idle):\n${LINK}\n\nTap 'Return to AI ✓' when finished."

Keep the explanation to one succinct sentence — what you were doing and why you need the user.

## Step 5 — Wait for agent-specific signal (done or closed)
**Exactly one signal always fires**, so this wait cannot hang on a session that quietly died:

- `done` — the user tapped "Return to AI ✓" (`POST /done`).
- `closed` — every other ending: the last viewer disconnected and did not come back within the reconnect grace period (`VIEWER_DISCONNECT_GRACE_MS`, 15s), the session went idle past `VIEWER_SESSION_IDLE_MS` (default 10 min), or the server restarted and found the session expired.

Either way the session ends: token invalidated, tunnel torn down, so a new link needs a new `/start-session`. Main session touches the matching flag file.

> The idle window is **not** a hard cap on the intervention — it resets on every authenticated request, and the viewer page polls `/status` every 5s while open. A user working through OTP → card → confirmation keeps their own session alive; it only expires once they actually go away.
```bash
while [ ! -f /tmp/intervention_done_${AGENT_KEY}.flag ] && [ ! -f /tmp/intervention_closed_${AGENT_KEY}.flag ]; do sleep 5; done
SIGNAL=$( [ -f /tmp/intervention_done_${AGENT_KEY}.flag ] && echo "done" || echo "closed" )
rm -f /tmp/intervention_done_${AGENT_KEY}.flag /tmp/intervention_closed_${AGENT_KEY}.flag
# Use SIGNAL + screenshot to assess what happened and proceed accordingly
```

## Step 6 — Clean up
```bash
rm -f /tmp/browser_intervention.json
```
Tunnel and token are already killed by server.js when done is received. Then continue the automation.

---

## Main Claude session responsibility
Extract the key from the injected message and touch the correct flag:

`Browser intervention done [agentId: <key>]` → `touch /tmp/intervention_done_<key>.flag`
`Browser viewer closed [agentId: <key>]` → `touch /tmp/intervention_closed_<key>.flag`

This unblocks the waiting agent, which then checks the SIGNAL value and acts accordingly.

## Note
The viewer listens on 127.0.0.1:3000. The normal access path is the Cloudflare
tunnel link minted above, which carries a `?token=` that every request and the
input WebSocket are checked against.

For direct local access instead, forward the port —
`ssh -L 3000:localhost:3000 <user>@<server_ip>` — and open
http://localhost:3000. Note that a token is still required: the server is
fail-closed, so with no active session token every request is denied. Set
`VIEWER_ALLOW_NO_TOKEN=1` in the server's environment to lift that, and only if
the SSH tunnel is genuinely the sole way to reach it. The link grants full
mouse/keyboard control of a browser holding the user's logged-in sessions.

---

## Implementation Notes

### Target Pinning
When `/start-session` receives `targetId` or `targetUrl`, the viewer is pinned to that specific CDP target (tab). This prevents the viewer from connecting to the wrong tab when multiple tabs are open. The pin is cleared when the session ends (token invalidation or `/done`).

- `targetId` — exact CDP target ID (highest priority match)
- `targetUrl` — URL substring match (used when exact ID is not known)
- If neither is provided, falls back to the first non-chrome tab (original behavior)

`start-tunnel.sh` automatically forwards its `target_url` argument to `/start-session` as `targetUrl`.

### Architecture
- `server.js` — Node.js HTTP + WebSocket server. Connects to Chrome via CDP WebSocket (`localhost:9222`), starts `Page.startScreencast`, relays JPEG frames to all connected browser clients. Forwards mouse/keyboard/scroll events back to Chrome via `Input.*` CDP commands.
- `index.html` — Canvas-based frontend. Renders screencast frames, captures user input, sends over WebSocket to server.
- Chrome must be running with `--remote-debugging-port=9222 --remote-debugging-address=127.0.0.1` (see `core/start-browser.sh`). CDP is loopback-only: nothing should ever expose port 9222 beyond the host — the DevTools protocol is unauthenticated and grants full browser control.
- `ws` is a declared dependency in the root `package.json` and is loaded with a bare `require('ws')`, resolved from `$CLAUDE_HOME/node_modules`.

### Mobile/Desktop Adaptation
Hardcoded to **iPhone 14 profile** (390×844, DPR 3, iOS 16.6 Safari UA). Applied at server startup via CDP:
- `Emulation.setDeviceMetricsOverride` — 390×844, deviceScaleFactor 3, mobile: true
- `Emulation.setUserAgentOverride` — iOS 16.6 Safari UA
- `Emulation.setTouchEmulationEnabled` — touch on, maxTouchPoints 5

No client-side device detection. Canvas is scaled to fit the viewer container using `fitCanvas()` (JS, not CSS), called via `ResizeObserver` on canvas-wrap.

### Known Bugs Fixed
- **Double character input**: `keyDown` CDP event has a `text` field that also inserts characters. Fixed by sending `text: ''` on keyDown and using a separate `char` event for character insertion.
- **UA not applied on reload**: `Page.reload` serves cached content ignoring new UA. Fixed by using `Page.navigate` instead.
- **Canvas not filling screen height**: After resize, `canvas.style.width = px` pinned canvas to exact pixel size. Fixed by setting `width: 100%; height: auto` so it scales proportionally to the container.
- **Chrome DevTools blank at localhost:9222**: Chrome 112+ removed DevTools UI from root. Use `chrome://inspect` or direct WebSocket URLs instead.
- **WebSocket Origin rejected**: Chrome 111+ validates the Origin header on CDP WebSocket connections. This only affects clients that send an Origin header (i.e. web pages connecting directly to CDP) — server.js, agent-browser, and Puppeteer send none, so no `--remote-allow-origins` flag is needed. Do NOT re-add `--remote-allow-origins=*`: it lets any web page visited in the browser connect to its own CDP endpoint and take over the session.

### Mobile Touch Handling

Canvas touch events are translated to CDP input events. On `touchstart`: reset
`gestureType = null`. On `touchmove`: lock direction after the first 5px of
movement — `absDy >= absDx` sends `touchMove` + `mouseWheel` (scroll),
`absDx > absDy` sends `touchMove` only (drag, no `mouseWheel`; sending wheel
events during a horizontal drag scrolls the page underneath the gesture). On
`touchend` with no significant movement (tap): send explicit
`mousePressed` + `mouseReleased`.

Findings worth keeping:
- `touch-action: none` CSS on the canvas is required — `e.preventDefault()`
  alone is insufficient on iOS
- `ResizeObserver` on canvas-wrap (not `window.resize`) is needed because the
  iOS URL bar showing/hiding doesn't fire `resize`
- `Input.dispatchTouchEvent` does NOT auto-scroll — send `mouseWheel` for scroll
- `Input.dispatchTouchEvent` does NOT synthesize clicks — send an explicit mouse
  click for taps

### Restarting the Server
```bash
pkill -f "browser-viewer/server.js"
sleep 2
setsid node $CLAUDE_HOME/browser-viewer/server.js < /dev/null > /tmp/viewer.log 2>&1 &
```
`setsid` detaches the server into its own session so it survives if the shell that started it is killed (e.g. a backgrounded bash that times out).
