#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Nightly session maintenance + review
# Runs at 3am user-local time. The cron entry is written in SYSTEM_TIMEZONE (the
# scheduler frame); USER_TIMEZONE is the user's wall clock — both in .env.
# 1. Sends Telegram notification that nightly maintenance is starting
# 2. Injects the memory/projects review into the STILL-LIVE session via
#    core/inject.sh (so it consolidates while today's context is still loaded),
#    as a normal interactive turn instead of a nested `claude -p`, then waits a
#    fixed window for it to finish. This matters for billing: as of 2026-06-15
#    the `claude -p` headless surface draws from the separate Agent SDK credit
#    pool (API rates), whereas the long-lived interactive session draws from the
#    normal subscription. Folding the review back into the live session also
#    drops the nested-claude footguns the old review fought: a second Telegram
#    poller (409 conflict), TMPDIR pollution (#304), and orphaned MCP pipes.
# 3. Exits Claude (run.sh will restart it) and waits until the new instance
#    is verifiably healthy
# 4. Restarts Chrome (clears accumulated tabs/memory)
#
# The review runs FIRST, before the restart, because the relaunched session
# starts fresh (run.sh launches claude with no --continue) — anything the review
# doesn't persist to a memory file before /exit is lost. inject.sh is
# fire-and-forget with no completion signal, so step 2 just waits a fixed window
# (REVIEW_WAIT_SECS) rather than handshaking: a slow/hung review can't block the
# restart beyond that bound.
#
# Order matters in steps 3-4: Claude's relaunch must NOT overlap the Chromium
# boot storm. Chromium churns CPU/IO for minutes after relaunch on a small VM;
# when the two boots overlapped, the relaunched Claude's Telegram plugin could
# miss its MCP startup handshake and be marked failed with no retry — Telegram
# dead until a manual /mcp reconnect (the dev-channels prompt was delayed the
# same way; see run.sh's auto-accept helper). Neither boot depends on the
# other, so restart Claude first, verify it, then bounce Chrome.

# Determine CLAUDE_HOME dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

export HOME="${HOME:-$(dirname "$CLAUDE_HOME")}"

# When run from cron, stdout/stderr are pipes the scheduler drains to EOF
# before it considers the job finished (supercronic's runJob does wg.Wait()
# on its pipe readers BEFORE cmd.Wait(); cronie similarly reads to EOF for
# mail). Anything backgrounded here that outlives the script — the relaunched
# Chrome below (a backgrounded setsid relaunch) — inherits
# those pipes and holds them open forever, so the job never "finishes" and the
# exited wrapper is left a zombie. Supercronic's next graceful reload (USR2 or
# -inotify, i.e. ANY .crontab write: scheduling, deleting, or a one-time JOB
# firing) then blocks on that job, silently freezing ALL scheduled tasks until
# the container restarts. Re-point this script's stdio at a log file up front
# so the cron pipes EOF the moment the script exits, regardless of what
# lingers. Keep the terminal when run interactively (manual testing).
if [[ ! -t 1 ]]; then
    # $CLAUDE_HOME is the writable bind mount in normal operation, but guard
    # the redirect anyway: if the log target is ever unwritable, a failed
    # `exec >` would abort the script — fall back to /dev/null instead. Either
    # branch takes stdout off the cron pipe, which is the whole point.
    if : >"$CLAUDE_HOME/nightly-review.log" 2>/dev/null; then
        exec >"$CLAUDE_HOME/nightly-review.log" 2>&1 </dev/null
    else
        exec >/dev/null 2>&1 </dev/null
    fi
fi

# Tolerant .env loader (issue #387)
if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
    source "$CLAUDE_HOME/core/env-loader.sh"; load_env
else
    source "$CLAUDE_HOME/.env"
fi

TMUX_SESSION="claudebot"

# Shared restart helpers (_kill_chrome / _wait_chrome_ready / _restart_chrome /
# _exit_claude / _wait_claudebot_ready). Kept in core/restart-lib.sh so the
# on-demand Telegram restart (core/restart.sh, #412) reuses the exact same
# hard-won sequence. RESTART_LOG_TAG keeps this script's log strings as
# "[nightly] ..." for continuity. CLAUDE_HOME/HOME/TMUX_SESSION are set above,
# which the lib relies on.
RESTART_LOG_TAG="nightly"
source "$CLAUDE_HOME/core/restart-lib.sh"

# Step 1 — notify start. Plain sendMessage, deliberately NOT a nested
# `claude -p` with the telegram MCP tool: each nested claude loads the
# telegram plugin, whose getUpdates long-poll is EXCLUSIVE per bot token and
# conflicts with the main session's poller (409s; see install/claude-auth.sh).
cd "$CLAUDE_HOME"
_notify() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="${TELEGRAM_CHAT_ID}" \
         --data-urlencode "text=$1" >/dev/null 2>&1
}
_notify "🔄 Nightly maintenance starting -- reviewing memory & tidying up, then restarting session & browser."

# Chrome restart helpers (_kill_chrome / _wait_chrome_ready / _restart_chrome)
# are provided by core/restart-lib.sh, sourced above. Invoked in Step 4 below,
# AFTER the Claude bounce.

# Step 2 — hand the memory/projects review to the STILL-LIVE session BEFORE the
# restart, so it consolidates while today's context is still loaded (the
# relaunched session below starts fresh — run.sh launches claude with no
# --continue — so anything not written to a memory file before /exit is lost).
# Delivered via inject.sh (webhook :8788, tmux fallback) as a normal interactive
# turn — NOT a nested `claude -p` — so it draws from the subscription rather than
# the Agent SDK credit pool (effective 2026-06-15), and avoids the second-poller
# / TMPDIR / orphaned-MCP problems the old nested call had. $CLAUDE_HOME / $HOME
# are expanded HERE (by this script) so the session receives real absolute paths,
# exactly as the old `claude -p` heredoc did. --no-telegram suppresses inject.sh's
# generic "Scheduled Task Fired" notice: we already sent a start message above,
# and the session sends the completion one when it finishes.
#
# The prompt is ONE logical line: the `\`-continuations below are stripped by the
# shell, so the string handed to inject.sh contains no literal newlines. This
# keeps inject.sh's tmux-send-keys fallback safe — a literal newline there would
# register as Enter and submit the prompt mid-sentence.
"$CLAUDE_HOME/core/inject.sh" "Claude task: Nightly session review -- do this yourself in THIS session, do NOT delegate it to a background agent: only this session holds today's conversation context, and a sub-agent would start blank and miss everything discussed today that isn't already saved to a file. \
Use only file tools (Read, Write, Edit, Glob, Grep) for the review -- no browser, web, or other network tools; the one permitted non-file action is the final Telegram completion message in the last step below. \
1. FIRST, from your own memory of today's conversation in this session, write any important new facts, decisions, preferences, or task outcomes to the memory folder ($HOME/.claude/projects/taskramen/memory/). This is the step a sub-agent could not do -- capture it before the nightly restart wipes this session's context. \
2. Read $CLAUDE_HOME/CLAUDE.md and $HOME/.claude/projects/taskramen/memory/MEMORY.md. \
3. Check if any memory files need updating based on what happened today (check recent file modification times in the memory folder). \
4. If there are any obviously stale or outdated memory entries (e.g. wrong email, wrong preferences), update them. \
5. Review project files and skills: scan $CLAUDE_HOME/projects/ and $CLAUDE_HOME/skills/ for any CLAUDE.md files that look stale or incomplete. If a project subfolder is missing a CLAUDE.md, create a minimal one. Check if skill files need updates. \
6. Update projects index: read $CLAUDE_HOME/projects/README.md (create it if missing, per CLAUDE.md 'Project Structure') and update the Active Projects / Completed / Archived lists to reflect the current project subfolders. For each project folder, include a one-line description based on its CLAUDE.md or contents. \
Keep memory entries concise. Only save non-obvious things not already in CLAUDE.md. \
When finished, send the user a Telegram message: '✅ Nightly review complete -- memory updated, projects tidied.'" --no-telegram

# Wait a fixed window for the live session to finish consolidating into memory
# BEFORE we exit and wipe its context. inject.sh is fire-and-forget (no completion
# signal back to this script), so we wait rather than handshake: a slow or hung
# review can't block the restart beyond this bound. This in-script sleep does NOT
# hold the cron pipe open — stdio was redirected to a log file up top, and only
# BACKGROUNDED survivors wedge the pipe (see the top note). The original pre-inject
# design already ran a multi-minute `claude -p` review here, so the overall timing
# profile is unchanged. Override REVIEW_WAIT_SECS from .env (sourced above) to
# tune without editing this version-controlled script.
REVIEW_WAIT_SECS="${REVIEW_WAIT_SECS:-600}"   # 10 minutes
sleep "$REVIEW_WAIT_SECS"

# Step 3 — stop Claude (run.sh while-loop will restart it in 5s), then wait
# until the relaunched instance is verifiably healthy before touching Chrome.
# _exit_claude / _wait_claudebot_ready come from core/restart-lib.sh (sourced
# above). On a wait timeout we still proceed to restart Chrome.
# _exit_claude verifies the kill; on failure skip the health wait — it would
# only greenlight the never-restarted old instance (see restart-lib.sh for
# why kill instead of /exit — issue #448) — and tell the user: on this path
# run.sh never relaunches, so no "Claude started" ever arrives and the log
# file is the only other place the failure would be visible.
if _exit_claude; then
    _wait_claudebot_ready || echo "[nightly] proceeding to restart Chrome anyway"
else
    echo "[nightly] ERROR: Claude session could not be stopped; proceeding to restart Chrome anyway"
    _notify "⚠️ Nightly maintenance: the Claude session could not be stopped, so Claude was NOT restarted. Chrome will still be restarted."
fi

# Step 4 — restart Chrome (clears accumulated tabs/memory for a fresh session)
_restart_chrome
