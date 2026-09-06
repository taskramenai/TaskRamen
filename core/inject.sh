#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Usage: inject.sh <message> [--no-telegram]
#   --no-telegram: skip Telegram notification (use for internal signals like browser done/closed)

# Determine CLAUDE_HOME dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# Load environment variables for the Telegram token (tolerant loader — issue #387)
if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
    source "$CLAUDE_HOME/core/env-loader.sh"; load_env
else
    source "$CLAUDE_HOME/.env"
fi

# Ensure tmux uses the correct socket directory for systemd compatibility
export TMUX_TMPDIR=/tmp

MESSAGE="$1"
NO_TELEGRAM=false
if [ "${2}" = "--no-telegram" ]; then
  NO_TELEGRAM=true
fi

# SAFETY: $MESSAGE may contain arbitrary user text (%, $, `, ", ', \, etc).
# It arrives here as a single positional argument, so shell quoting is already
# resolved by the caller. The rules below MUST be observed when adding code:
#   - NEVER pass $MESSAGE to printf as a format string (printf "$MESSAGE").
#     A literal % in the message would be interpreted as a format spec and
#     either consume following args or print garbage. Always use:
#         printf '%s' "$MESSAGE"   (or echo, with the usual caveats)
#   - NEVER eval or sh -c "$MESSAGE" — single-quote wrapping in cron only
#     neutralises expansion at cron-fire time, not in nested re-evaluation.
#   - When passing to curl as form fields, ALWAYS use --data-urlencode for
#     untrusted values. Plain `-d text="$MSG"` sends the value as a literal
#     POST body, so a `&` in $MSG splits into a new field — an injection
#     vector that could override chat_id, parse_mode, etc.
#   - When passing as JSON, always run through `jq -Rs .` (as below) to
#     escape control chars, quotes, and backslashes.

# 1. Send direct Telegram fallback notification IMMEDIATELY (unless suppressed)
# Each field uses --data-urlencode so that a `&` (or any reserved char) in
# $MESSAGE cannot inject additional POST parameters into the Telegram API call.
if [ "$NO_TELEGRAM" = false ]; then
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=🔔 *Scheduled Task Fired:*\n\`$MESSAGE\`" \
    --data-urlencode "parse_mode=Markdown" >/dev/null 2>&1 &
fi

# 2. Prefix the message so Claude knows this is an automated trigger
PROMPT="[SYSTEM CRON TRIGGER]: $MESSAGE"

# 3. Try webhook channel first, fall back to tmux.
# `jq -Rs '{text: .}'` builds the entire JSON object inside jq, so we don't
# splice any user text into a shell-quoted JSON template. `printf '%s'` (not
# printf "$PROMPT") avoids interpreting % in $PROMPT as a format specifier.
if curl -sf -X POST "http://127.0.0.1:8788/message" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${WEBHOOK_CHANNEL_SECRET}" \
    --data-binary "$(printf '%s' "$PROMPT" | jq -cRs '{text: .}')" \
    --max-time 5 >/dev/null 2>&1; then
  : # Webhook delivery succeeded
else
  # Fallback to tmux send-keys (legacy, unreliable). tmux send-keys treats
  # its argument as literal keystrokes — no shell re-evaluation — so any
  # special chars in $PROMPT are safe here.
  /usr/bin/tmux -L claudebot send-keys -t claudebot "$PROMPT" C-m
fi
