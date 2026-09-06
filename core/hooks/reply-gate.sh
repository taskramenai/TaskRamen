#!/usr/bin/env bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Reply-gate hooks: nudge the main session ONCE when a turn ends with
# terminal-only text and no Telegram message actually sent (issue #432).
#
# One script, dispatched by first argument (the registering event):
#   clear   — UserPromptSubmit: reset both flags for this session's new turn
#   text    — MessageDisplay: mark "assistant text was displayed this turn"
#   replied — PostToolUse (telegram MCP reply/edit_message): mark "reply sent"
#   bash    — PostToolUse (Bash): mark "reply sent" iff the command hit the
#             Bot API sendMessage/editMessageText (the documented curl fallback)
#   stop    — Stop: if text was displayed but nothing was sent, emit
#             {"decision":"block","reason":...} — an advisory nudge, not a hard
#             gate: stop_hook_active is honored so it can never fire twice in
#             a row, and the reason itself tells Claude when NOT to comply.
#             On turns that genuinely end (no nudge, or post-nudge) it also
#             clears the flags, since turns triggered by agent-completion or
#             webhook events don't fire UserPromptSubmit.
#
# MAINTENANCE: registered in ~/.claude/settings.json by install/config.sh —
# see config_generate(), the Python block that writes data["hooks"]. If you
# rename, move, or change the args of this script, update install/config.sh.
#
# FAILS OPEN BY DESIGN: no set -e; every failure path exits 0 so a broken
# gate degrades to "does nothing", never "wedges every turn". PostToolUse
# only fires on tool SUCCESS (failures go to PostToolUseFailure), so a failed
# send never sets the replied flag — which is exactly what we want.

EVENT="${1:-}"
# Hooks always pipe JSON on stdin; guard against a bare interactive run
# (stdin = TTY) so a manual invocation doesn't hang on cat.
INPUT=""
[ -t 0 ] || INPUT=$(cat 2>/dev/null) || INPUT=""

command -v jq >/dev/null 2>&1 || exit 0
[ -n "$EVENT" ] || exit 0

# Gate only TaskRamen sessions: hooks in ~/.claude/settings.json are
# user-global, but a session in an unrelated repo has no Telegram tools —
# nudging every turn there would be pure noise. Fail open if cwd is absent.
CLAUDE_HOME="${CLAUDE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
case "$CWD" in
  "$CLAUDE_HOME"|"$CLAUDE_HOME"/*) ;;
  *) exit 0 ;;
esac

# Flags are namespaced by session_id so concurrent sessions (cron-triggered
# runs, watchers) can't satisfy or trip each other's gate.
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || SID=""
SID=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9._-')
[ -n "$SID" ] || exit 0

FLAG_DIR="${TMPDIR:-/tmp}/replygate-$(id -u)"
mkdir -p "$FLAG_DIR" 2>/dev/null || exit 0
chmod 700 "$FLAG_DIR" 2>/dev/null

TEXT_FLAG="$FLAG_DIR/$SID.text"
REPLIED_FLAG="$FLAG_DIR/$SID.replied"

case "$EVENT" in
  clear)
    rm -f "$TEXT_FLAG" "$REPLIED_FLAG" 2>/dev/null
    # housekeeping: drop flags from sessions dead for >48h
    find "$FLAG_DIR" -maxdepth 1 -type f -mmin +2880 -delete 2>/dev/null
    ;;

  text)
    touch "$TEXT_FLAG" 2>/dev/null
    ;;

  replied)
    touch "$REPLIED_FLAG" 2>/dev/null
    ;;

  bash)
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
    # Require an actual curl invocation of the Bot API, not a command that
    # merely mentions the URL (e.g. the transcript-verification grep).
    if printf '%s' "$CMD" | grep -Eq 'curl[^|;&]*api\.telegram\.org/bot[^ ]*/(sendMessage|editMessageText)'; then
      # Best-effort delivery check: if the captured response visibly carries
      # Telegram's {"ok":false,...}, the send failed — don't count it.
      RESP=$(printf '%s' "$INPUT" | jq -r 'if (.tool_response | type) == "object" then (.tool_response.stdout // "") else (.tool_response // "" | tostring) end' 2>/dev/null) || RESP=""
      case "$RESP" in
        *'"ok":false'*|*'"ok": false'*) ;;
        *) touch "$REPLIED_FLAG" 2>/dev/null ;;
      esac
    fi
    ;;

  stop)
    # Never nudge twice: if this Stop was itself caused by our nudge, pass.
    ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || ACTIVE="false"
    if [ "$ACTIVE" = "true" ]; then
      rm -f "$TEXT_FLAG" "$REPLIED_FLAG" 2>/dev/null
      exit 0
    fi
    if [ -e "$TEXT_FLAG" ] && [ ! -e "$REPLIED_FLAG" ]; then
      jq -n --arg reason \
"REPLY GATE (mechanical check): this turn displayed terminal text but no Telegram send succeeded — memory of composing a reply is not evidence it was sent. If the silence was deliberate (e.g. skipped duplicate watcher ping, a frozen-agent trigger needing no reply — stale task, or a warning the watcher already sent the user directly — nothing to resume, the restart execute turn) or Telegram is down: end the turn with NO message — no acknowledgment or meta reply to this nudge. Otherwise resend the undelivered message now via mcp__plugin_telegram_telegram__reply(text: \"<message>\") — Bot API sendMessage curl (token/chat_id from .env) only if the tool errors." \
        '{decision: "block", reason: $reason}'
    else
      # Turn is genuinely ending — clear flags here as well: not every turn
      # begins with UserPromptSubmit (agent-completion and webhook/cron
      # continuations don't fire it), and a stale replied flag carried into
      # such a turn would mask a real missed reply.
      rm -f "$TEXT_FLAG" "$REPLIED_FLAG" 2>/dev/null
    fi
    ;;
esac

exit 0
