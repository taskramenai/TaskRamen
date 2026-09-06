#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# start-tunnel-bg.sh — Prepare tunnel without token (safe to background)
#
# Intended use: background this BEFORE a long Puppeteer run so tunnel is ready
# by the time the script finishes. Token generation is done separately inline.
#
# Usage:
#   bash start-tunnel-bg.sh [target_url] &
#   ... run Puppeteer here ...
#   PUBLIC_URL=$(cat /tmp/tunnel_public_url.txt)
#   VIEWER_SECRET=$(grep '^WEBHOOK_CHANNEL_SECRET=' "$CLAUDE_HOME/.env" | head -1 | cut -d= -f2- | sed -E "s/^(['\"])(.*)\1\$/\2/")
#   TOKEN=$(curl -s --max-time 15 -X POST http://localhost:3000/start-session \
#     -H "Content-Type: application/json" \
#     -H "Authorization: Bearer ${VIEWER_SECRET}" \
#     -d "{\"agentId\": \"${AGENT_KEY}\", \"targetUrl\": \"<current_page_url>\"}" \
#     | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
#   LINK="${PUBLIC_URL}/?token=${TOKEN}"
#
# The targetUrl field pins the viewer to the tab matching that URL.
# Without it, viewer connects to the first non-chrome tab (may be wrong tab).

TARGET_URL="${1:-}"

# --- Load CLOUDFLARED_BIN from .env if not already set ---
if [ -z "${CLOUDFLARED_BIN:-}" ] && [ -f "${CLAUDE_HOME:-.}/.env" ]; then
    _cfbin=$(grep '^CLOUDFLARED_BIN=' "${CLAUDE_HOME:-.}/.env" 2>/dev/null | head -1 | cut -d= -f2-)
    # Expand shell variables like $HOME in the path
    [ -n "$_cfbin" ] && export CLOUDFLARED_BIN="$(eval echo "$_cfbin")"
    unset _cfbin
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

rm -f /tmp/tunnel_public_url.txt

# --- Step 0: Wait for CDP to be reachable ---
echo "[0/3] Waiting for CDP on port 9222..." >&2
CDP_READY=0
for i in $(seq 1 10); do
  if curl -s --max-time 5 http://localhost:9222/json > /dev/null 2>&1; then
    CDP_READY=1
    break
  fi
  echo "  CDP not ready, retrying ($i/10)..." >&2
  sleep 1
done
if [ "$CDP_READY" -ne 1 ]; then
  echo "ERROR: CDP on port 9222 not reachable after 10 retries — is Chrome running?" >&2
  exit 1
fi

# --- Step 1: Close stale tabs ---
echo "[1/3] Closing stale tabs..." >&2
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
echo "[2/3] Restarting viewer server..." >&2
if restart_viewer_server; then
  echo "  Viewer OK" >&2
elif restart_viewer_server; then
  echo "  Viewer OK (after retry)" >&2
else
  echo "ERROR: Viewer server failed to start twice. Log:" >&2
  cat "$VIEWER_LOG" >&2
  exit 1
fi

# --- Step 3: Start Cloudflare tunnel ---
echo "[3/3] Starting tunnel..." >&2
[ -f /tmp/cloudflared.pid ] && kill $(cat /tmp/cloudflared.pid) 2>/dev/null || true
rm -f /tmp/cloudflared.pid /tmp/cloudflared.log

# stdout redirected so a caller capturing this script's output is never
# blocked by cloudflared holding the inherited stdout pipe open.
# The inner sh writes its own PID then execs, so the pid file always holds
# the live timeout/cloudflared PID — even when setsid forks (interactive
# shells), where $! would capture the short-lived setsid wrapper instead.
# timeout 3600 is an ORPHAN BACKSTOP, not the session lifetime — see the
# matching comment in start-tunnel.sh; keep the two values in step.
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

echo "  Tunnel ready: $PUBLIC_URL" >&2
echo "$PUBLIC_URL" > /tmp/tunnel_public_url.txt
