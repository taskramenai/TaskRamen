#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Usage: telegram-direct.sh <message>
#
# Sends a user-facing message straight to the Telegram Bot API, bypassing the
# Claude session entirely. For out-of-band processes (e.g. the agent status
# watcher) that must reach the user even when the session's message loop is
# blocked — a stuck tool call in a background agent can stall the whole
# session, including inject.sh trigger delivery (issue #492).
#
# Sends PLAIN TEXT (no parse_mode): messages embed arbitrary agent labels, and
# a Markdown parse failure would make the Bot API reject the send silently.
#
# Exit code = delivery status, so callers can fall back to another channel:
#   0 — Telegram's API confirmed delivery ("ok":true in the response)
#   1 — NOT delivered (missing message/credentials, curl failure/timeout, or
#       an "ok":false API rejection). A one-line diagnostic goes to stderr so
#       the calling process's log shows why the last-resort channel dropped a
#       message. Never crashes the caller beyond the exit code — callers
#       should branch on it (`if telegram-direct.sh "msg"; then ...`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# Load the bot token (tolerant loader — issue #387)
if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
    source "$CLAUDE_HOME/core/env-loader.sh"; load_env
elif [[ -f "$CLAUDE_HOME/.env" ]]; then
    source "$CLAUDE_HOME/.env"
fi

MESSAGE="${1:-}"
if [ -z "$MESSAGE" ]; then
    echo "telegram-direct: no message given — nothing sent" >&2
    exit 1
fi
if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
    echo "telegram-direct: TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID missing — not sent" >&2
    exit 1
fi

# --data-urlencode on every field: $MESSAGE is arbitrary text, so a literal `&`
# must not be able to inject extra POST parameters (same rule as inject.sh).
RESPONSE=$(curl -s --max-time 10 -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${MESSAGE}" 2>/dev/null)

# The Bot API answers 200 with {"ok":false,...} on rejections (bad chat_id,
# revoked token, 429 flood-wait), so an ok-check — not just curl success — is
# what distinguishes delivered from dropped (same check as reply-gate.sh).
case "$RESPONSE" in
    *'"ok":true'*|*'"ok": true'*)
        exit 0
        ;;
    '')
        echo "telegram-direct: curl failed or timed out — not delivered" >&2
        exit 1
        ;;
    *)
        echo "telegram-direct: API rejected send: ${RESPONSE:0:200}" >&2
        exit 1
        ;;
esac
