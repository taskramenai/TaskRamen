#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# On-demand safe restart, triggered by the user over Telegram (issue #412).
#
# Usage: restart.sh [all|claude|chrome]   (default: all)
#   all    — restart Claude, wait until healthy, then restart Chrome
#   claude — restart only the Claude session
#   chrome — restart only Chrome (the part that's often problematic)
#
# This reuses the exact restart sequence the nightly review was debugged into,
# via core/restart-lib.sh — see that file and core/nightly-review.sh for the
# why-it-must-be-this-order reasoning (Chrome boot storm vs Claude's MCP
# handshake; monitor.sh respawn-race suppression; cron/stdio detachment).
#
# SELF-DETACH: the trigger path is the live Claude session running this script
# via its Bash tool. The "all"/"claude" modes stop that very session (SIGTERM
# via restart-lib's _exit_claude — see there for why not /exit), so the process
# orchestrating the restart MUST NOT be a child of Claude — it would be killed
# mid-restart when Claude exits, leaving Claude down and Chrome untouched.
# So on first entry we re-exec ourselves under setsid (new session, detached
# stdio) and return immediately; the detached copy does the real work and the
# caller (Claude) is free to exit. Guarded by RESTART_DETACHED so the re-exec
# happens exactly once.

# Determine CLAUDE_HOME dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_HOME="${CLAUDE_HOME:-$(dirname "$SCRIPT_DIR")}"
export HOME="${HOME:-$(dirname "$CLAUDE_HOME")}"

LOG="$CLAUDE_HOME/restart.log"

# Mode: all (default) | claude | chrome
MODE="${1:-all}"
case "$MODE" in
    all|claude|chrome) ;;
    *)
        echo "Usage: restart.sh [all|claude|chrome]" >&2
        exit 2
        ;;
esac

# ── Self-detach (see header) ─────────────────────────────────────────────────
if [[ "${RESTART_DETACHED:-}" != "1" ]]; then
    # Subshell around the redirect so a failing `>>"$LOG"` can't leak its error
    # to the terminal: the redirection failure is reported before a trailing
    # `2>/dev/null` would take effect, so the suppression must wrap the whole thing.
    if ( : >>"$LOG" ) 2>/dev/null; then LOGDEST="$LOG"; else LOGDEST=/dev/null; fi
    RESTART_DETACHED=1 setsid bash "$0" "$MODE" </dev/null >>"$LOGDEST" 2>&1 &
    if [[ "$LOGDEST" != "/dev/null" ]]; then
        echo "restart ($MODE) dispatched as detached pid $! -- watch progress in $LOG"
    else
        echo "restart ($MODE) dispatched as detached pid $! (logging disabled: $LOG is not writable)"
    fi
    exit 0
fi

# ── Detached worker from here on ─────────────────────────────────────────────

# Tolerant .env loader (issue #387) — needed for TELEGRAM_* in the notifier.
if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
    source "$CLAUDE_HOME/core/env-loader.sh"; load_env
else
    source "$CLAUDE_HOME/.env"
fi

export TMUX_SESSION="claudebot"

# The claudebot tmux server lives under TMUX_TMPDIR=/tmp (entrypoint.sh sets it
# before creating the session). Pin it so `tmux -L claudebot` from this detached
# worker targets the right socket regardless of inherited env — same as inject.sh
# and monitor.sh do.
export TMUX_TMPDIR=/tmp

# Shared restart helpers (single source of truth — also used by nightly-review).
source "$CLAUDE_HOME/core/restart-lib.sh"

cd "$CLAUDE_HOME"

# Plain sendMessage — deliberately NOT a nested `claude -p` with the telegram MCP
# tool: a nested claude would load the telegram plugin, whose getUpdates
# long-poll is EXCLUSIVE per bot token and conflicts with the main session's
# poller (409s). Same reasoning as nightly-review.sh's _notify.
_notify() {
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="${TELEGRAM_CHAT_ID}" \
         --data-urlencode "text=$1" >/dev/null 2>&1
}

echo "[restart] === restart ($MODE) started $(date) ==="

case "$MODE" in
    chrome)
        _notify "🔄 Restarting Chrome now..."
        # _restart_chrome ends with _wait_chrome_ready, so its exit status IS the
        # readiness result — no need to wait twice.
        if _restart_chrome; then
            _notify "✅ Chrome restarted -- browser is back up."
        else
            _notify "⚠️ Chrome restart finished but CDP did not come up within the wait window. The monitor will keep trying; you can retry if browser tasks fail."
        fi
        ;;

    claude)
        # No Telegram completion message from THIS script for the claude bounce:
        # this script is about to be torn down when Claude exits (it's detached,
        # so it survives — but the user's confidence signal is run.sh's own
        # "✅ Claude started" announcement, which fires once the relaunched
        # session's Telegram poller is verified alive). We still post a start
        # message and log the health result.
        _notify "🔄 Restarting Claude now -- you'll get a \"Claude started\" message once it's back (~30-60s)."
        # _exit_claude verifies the kill; on failure skip the health wait —
        # it would only greenlight the never-restarted old instance (see
        # restart-lib.sh for why kill instead of /exit — issue #448).
        if _exit_claude; then
            if _wait_claudebot_ready; then
                echo "[restart] Claude relaunched and healthy"
            else
                echo "[restart] Warning: relaunched Claude not verifiably healthy in time"
            fi
        else
            echo "[restart] ERROR: Claude session could not be stopped; restart did not happen"
            _notify "⚠️ Restart failed: the running Claude session could not be stopped, so nothing was restarted. Please try again."
        fi
        ;;

    all)
        _notify "🔄 Restarting Claude and Chrome now -- you'll get a \"Claude started\" message when the session is back, then a Chrome confirmation."
        # Order matters: restart Claude and let it become healthy BEFORE bouncing
        # Chrome, so the Chromium boot storm doesn't overlap Claude's MCP
        # handshake (the failure mode documented in nightly-review.sh).
        # Track Claude's outcome so the final notice tells the truth for all
        # three cases: healthy | unhealthy (relaunched but never verified) |
        # stop_failed (old session could not be killed — NOTHING restarted;
        # the health wait is skipped because it would only greenlight the
        # never-restarted old instance, the false-"Restart complete" of #448).
        # (plain var, not `local` — this case runs at script top level, not in a function)
        claude_status=healthy
        if _exit_claude; then
            _wait_claudebot_ready || { claude_status=unhealthy; echo "[restart] proceeding to restart Chrome anyway"; }
        else
            claude_status=stop_failed
            echo "[restart] ERROR: Claude session could not be stopped; skipping health wait, proceeding to Chrome"
        fi
        # _restart_chrome's exit status is its internal _wait_chrome_ready result.
        if _restart_chrome; then
            case "$claude_status" in
                healthy)     _notify "✅ Restart complete -- Claude and Chrome are back up." ;;
                unhealthy)   _notify "⚠️ Chrome is back up, but Claude did not report healthy within the wait window. The monitor will keep trying." ;;
                stop_failed) _notify "⚠️ Chrome was restarted, but the Claude session could not be stopped, so Claude was NOT restarted. Please try again." ;;
            esac
        else
            case "$claude_status" in
                healthy)     _notify "⚠️ Claude is back; Chrome restart finished but CDP did not come up within the wait window. The monitor will keep trying." ;;
                unhealthy)   _notify "⚠️ Neither Claude nor Chrome reported healthy within the wait window. The monitor will keep trying." ;;
                stop_failed) _notify "⚠️ Restart failed: the Claude session could not be stopped and Chrome did not come back up. Please try again." ;;
            esac
        fi
        ;;
esac

echo "[restart] === restart ($MODE) finished $(date) ==="
