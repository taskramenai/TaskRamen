#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# start-tunnel.sh — Full browser viewer intervention setup
#
# Usage: LINK=$(bash start-tunnel.sh [target_url] [agent_id])
#
# 1. Closes all Chrome tabs except the one matching target_url (or first real tab)
# 2. Restarts the viewer server so it connects to the correct tab
# 3. Starts a fresh Cloudflare tunnel
# 4. Generates a session token (bound to agent_id so server.js can notify it on done)
# 5. Prints the one-click viewer link to stdout (all other output goes to stderr)

TARGET_URL="${1:-}"
AGENT_ID="${2:-}"

# --- Locate .env (CLAUDE_HOME, else relative to this script) ---
ENV_FILE="${CLAUDE_HOME:-$(dirname "$0")/..}/.env"

# --- Load CLOUDFLARED_BIN from .env if not already set ---
if [ -z "${CLOUDFLARED_BIN:-}" ] && [ -f "$ENV_FILE" ]; then
    # Only extract CLOUDFLARED_BIN, don't source the entire .env
    _cfbin=$(grep '^CLOUDFLARED_BIN=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    # Expand shell variables like $HOME in the path
    [ -n "$_cfbin" ] && export CLOUDFLARED_BIN="$(eval echo "$_cfbin")"
    unset _cfbin
fi

# --- Load the shared secret /start-session requires (server.js validateAdminSecret) ---
# .env values are single-quoted by write_env (install/utils.sh), and server.js
# strips those quotes on load — so strip the matching surrounding quotes here
# too, otherwise the Bearer header carries literal quotes and every request 403s.
if [ -z "${WEBHOOK_CHANNEL_SECRET:-}" ] && [ -f "$ENV_FILE" ]; then
    WEBHOOK_CHANNEL_SECRET=$(grep '^WEBHOOK_CHANNEL_SECRET=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- \
      | sed -E "s/^(['\"])(.*)\1\$/\2/")
fi
if [ -z "${WEBHOOK_CHANNEL_SECRET:-}" ]; then
  echo "ERROR: WEBHOOK_CHANNEL_SECRET not found in $ENV_FILE — cannot authenticate to /start-session." >&2
  exit 1
fi

# --- Fast-fail: verify cloudflared binary is available ---
CLOUDFLARED_CMD="${CLOUDFLARED_BIN:-cloudflared}"
if [ ! -x "$CLOUDFLARED_CMD" ] && ! command -v "$CLOUDFLARED_CMD" > /dev/null 2>&1; then
  echo "ERROR: cloudflared binary not found." >&2
  echo "  Set CLOUDFLARED_BIN to the full path (e.g. export CLOUDFLARED_BIN=\$HOME/bin/cloudflared)" >&2
  echo "  or ensure 'cloudflared' is on your PATH." >&2
  exit 1
fi

VIEWER_LOG=/tmp/viewer.log

# Kill any existing server.js and start a fresh one, detached via setsid so it
# survives if this script's parent shell is killed (e.g. a backgrounded bash
# that times out). Returns 0 once the server is listening.
restart_viewer_server() {
  pkill -f "browser-viewer/server.js" 2>/dev/null || true
  sleep 1
  setsid node "$(dirname "$0")/server.js" < /dev/null > "$VIEWER_LOG" 2>&1 &
  for i in $(seq 1 10); do
    sleep 1
    grep -q "running at" "$VIEWER_LOG" 2>/dev/null && return 0
  done
  return 1
}

# --- Step 1: Close stale tabs ---
echo "[1/4] Closing stale tabs..." >&2
TABS_JSON=$(curl -s --max-time 10 http://localhost:9222/json)

KEEP_ID=""
if [ -z "$TABS_JSON" ]; then
  echo "  CDP (9222) not reachable — skipping tab cleanup" >&2
else
# Tab list and target URL are UNTRUSTED (a visited page controls its own URL
# and title, both of which appear in the CDP tab list) — pass them to Python
# via the environment and a quoted heredoc, never by interpolating into source.
KEEP_ID=$(TABS_JSON="$TABS_JSON" TARGET_URL="$TARGET_URL" python3 << 'PYEOF'
import json, os
try:
    tabs = json.loads(os.environ.get('TABS_JSON', '') or '[]')
except json.JSONDecodeError:
    tabs = []
real = [t for t in tabs if not t.get('url','').startswith('chrome-ext') and not t.get('url','').startswith('chrome://') and t.get('type','') != 'service_worker']
target = os.environ.get('TARGET_URL', '')
if target:
    match = next((t for t in real if target in t.get('url','')), None)
    keep = match['id'] if match else (real[0]['id'] if real else None)
else:
    keep = real[0]['id'] if real else None
print(keep or '')
PYEOF
)

if [ -n "$KEEP_ID" ]; then
  echo "  Keeping: $KEEP_ID" >&2
  CLOSE_IDS=$(TABS_JSON="$TABS_JSON" KEEP_ID="$KEEP_ID" python3 << 'PYEOF'
import json, os
try:
    tabs = json.loads(os.environ.get('TABS_JSON', '') or '[]')
except json.JSONDecodeError:
    tabs = []
keep_id = os.environ.get('KEEP_ID', '')
[print(t['id']) for t in tabs if t['id'] != keep_id and not t.get('url','').startswith('chrome-ext')]
PYEOF
)
  for id in $CLOSE_IDS; do
    curl -s --max-time 5 "http://localhost:9222/json/close/$id" > /dev/null
    echo "  Closed: $id" >&2
  done
fi
fi

# --- Step 2: Restart viewer server ---
echo "[2/4] Restarting viewer server..." >&2
if restart_viewer_server; then
  echo "  Viewer OK" >&2
elif restart_viewer_server; then
  echo "  Viewer OK (after retry)" >&2
else
  # Do NOT continue: a tunnel + token against a dead port 3000 produces a
  # public URL that 502s and a link with an empty token.
  echo "ERROR: viewer server failed to start twice; aborting before tunnel. Log:" >&2
  cat "$VIEWER_LOG" >&2
  exit 1
fi

# --- Step 3: Start Cloudflare tunnel ---
echo "[3/4] Starting tunnel..." >&2
[ -f /tmp/cloudflared.pid ] && kill $(cat /tmp/cloudflared.pid) 2>/dev/null || true
rm -f /tmp/cloudflared.pid /tmp/cloudflared.log

# stdout must be redirected too: cloudflared inheriting this script's stdout
# keeps the pipe open, so LINK=$(bash start-tunnel.sh ...) blocks until
# cloudflared exits (up to the 3600s orphan backstop below) even though the
# link was already printed.
# The inner sh writes its own PID then execs, so the pid file always holds
# the live timeout/cloudflared PID — even when setsid forks (interactive
# shells), where $! would capture the short-lived setsid wrapper instead.
# timeout 3600 is an ORPHAN BACKSTOP, not the session lifetime: the server
# tears the tunnel down via killTunnel() on every session-ending path (/done,
# idle expiry, viewer disconnect), so in normal operation the process is gone
# long before the cap. The cap only reaps a cloudflared orphaned by a killed
# server. It must comfortably exceed the longest legitimate hand-off — the
# session idle window refreshes on activity, so a hard cap near the idle
# window (the old 600) cut off users mid-form at 10 minutes wall clock.
setsid sh -c 'echo $$ > /tmp/cloudflared.pid; exec timeout 3600 "$1" tunnel --url http://localhost:3000 --no-autoupdate < /dev/null > /dev/null 2>/tmp/cloudflared.log' _ "$CLOUDFLARED_CMD" &

for i in $(seq 1 30); do
  PUBLIC_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
  [ -n "$PUBLIC_URL" ] && break
  sleep 1
done

if [ -z "$PUBLIC_URL" ]; then
  echo "ERROR: tunnel URL not found" >&2
  exit 1
fi
echo "  Tunnel: $PUBLIC_URL" >&2

# --- Step 4: Generate session token (bind to agentId + pin to target tab) ---
echo "[4/4] Generating token..." >&2
# Build JSON payload with json.dumps — TARGET_URL/AGENT_ID may contain quotes
# or backslashes; never assemble JSON by string interpolation.
SESSION_PAYLOAD=$(AGENT_ID="$AGENT_ID" TARGET_URL="$TARGET_URL" python3 -c '
import json, os
payload = {"agentId": os.environ.get("AGENT_ID", "")}
if os.environ.get("TARGET_URL"):
    payload["targetUrl"] = os.environ["TARGET_URL"]
print(json.dumps(payload))')

# --max-time keeps a wedged server from hanging this script (and the agent
# shell that ran it) forever — fail fast, restart the server, retry instead
request_token() {
  curl -s --max-time 15 -X POST http://localhost:3000/start-session \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${WEBHOOK_CHANNEL_SECRET}" \
    -d "$SESSION_PAYLOAD" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null
}

TOKEN=$(request_token)
if [ -z "$TOKEN" ]; then
  echo "  Token request failed or timed out — restarting viewer server and retrying..." >&2
  # The tunnel keeps proxying to port 3000, so it survives this restart
  if restart_viewer_server; then
    TOKEN=$(request_token)
  fi
fi
if [ -z "$TOKEN" ]; then
  echo "ERROR: no token from /start-session even after a server restart. Viewer log:" >&2
  cat "$VIEWER_LOG" >&2
  exit 1
fi

echo "${PUBLIC_URL}/?token=${TOKEN}"
