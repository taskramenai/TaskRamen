#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Shared restart helpers — the single source of truth for the (fiddly, hard-won)
# sequence that bounces the long-lived Claude session and/or Chrome.
#
# Sourced by:
#   - core/nightly-review.sh  (unattended 3am maintenance: review -> restart)
#   - core/restart.sh         (on-demand restart triggered over Telegram, #412)
#
# This file ONLY defines functions and a couple of defaulted vars — it runs
# nothing at source time, so a `source` is side-effect free. Callers must have
# CLAUDE_HOME and HOME exported before sourcing; both caller scripts derive them
# from their own location up top.
#
# Why a shared lib instead of duplicating: the Chrome restart path carries a lot
# of non-obvious correctness constraints (cron-pipe detachment, monitor.sh
# respawn-race suppression, systemd-vs-manual relaunch, profile/Xvfb lock
# cleanup, MCP-handshake ordering vs the Chromium boot storm). Keeping one copy
# means an on-demand restart inherits exactly the behaviour the nightly path was
# debugged into, and a future fix lands in both at once.

# Log tag for this lib's diagnostics. nightly-review sets RESTART_LOG_TAG=nightly
# before sourcing so its log strings stay "[nightly] ..."; restart.sh leaves the
# default. Pure cosmetics — does not affect control flow.
RESTART_LOG_TAG="${RESTART_LOG_TAG:-restart}"

# tmux session name the long-lived Claude runs in (run.sh launches it as
# "claudebot"). Overridable for tests; defaulted so the lib is self-sufficient.
TMUX_SESSION="${TMUX_SESSION:-claudebot}"

# Planned-restart stamp (issue #513). _exit_claude below deliberately kills
# Claude and lets run.sh relaunch it, which leaves a ~10-40s window with NO
# claude process (run.sh's 5s relaunch sleep, then orphan-poller kill + up to
# 15s of getUpdates-409 draining before it launches). monitor.sh's is_frozen()
# step 1 treats a missing process as frozen immediately — no retry, no notion
# of a planned outage — so a monitor iteration landing in that window Telegrams
# a false "Claude appears frozen" in the middle of an entirely healthy restart.
# Stamping this file lets monitor.sh recognise the outage as planned and stay
# quiet for a bounded grace: the same cross-process suppression _restart_chrome
# already does for TASK 8 via /tmp/browser_last_respawn. monitor.sh READS this
# path — the two definitions must stay in sync.
PLANNED_RESTART_STAMP="${PLANNED_RESTART_STAMP:-/tmp/claude_planned_restart}"

_rl_log() { echo "[$RESTART_LOG_TAG] $*"; }

# ── Chrome ───────────────────────────────────────────────────────────────────

_kill_chrome() {
    pkill -f "start-browser.sh" 2>/dev/null || true
    pkill -f "chromium" 2>/dev/null || true
    pkill -f "Xvfb :99" 2>/dev/null || true
    pkill -f "matchbox-window-manager" 2>/dev/null || true
    sleep 2
    # Force-kill stragglers that ignored SIGTERM
    pkill -9 -f "start-browser.sh" 2>/dev/null || true
    pkill -9 -f "chromium" 2>/dev/null || true
    pkill -9 -f "Xvfb :99" 2>/dev/null || true
    pkill -9 -f "matchbox-window-manager" 2>/dev/null || true
    # Clean stale Chrome profile locks (same as start-browser.sh)
    rm -f "$CLAUDE_HOME/.chrome-profile"/SingletonLock \
          "$CLAUDE_HOME/.chrome-profile"/SingletonSocket \
          "$CLAUDE_HOME/.chrome-profile"/SingletonCookie 2>/dev/null || true
    # Remove stale Xvfb socket so xvfb-run --server-num=99 can reclaim display :99
    rm -f /tmp/.X11-unix/X99 2>/dev/null || true
}

# Kill agent-browser daemon/CLI processes (binary name: agent-browser-linux-*).
# Chrome's death already invalidates every browser session, but a WEDGED
# CLI/daemon — issue #492: a retry loop stuck against a dead socket, which
# survives TaskStop (stopping an agent does not kill its spawned processes) —
# is cleared by NO other cleanup path and would outlive the very Chrome
# restart users are told fixes a stuck browser. Anchored on the binary name,
# not "agent-browser", so a grep/editor whose argv merely mentions
# agent-browser is never killed (residual: argv carrying the FULL binary
# name — a debugger on the binary, or an `npm install -g agent-browser`
# overlapping a restart — still matches; accepted as rare). Fresh CLI calls respawn the daemon on
# demand, so killing it while Chrome is being bounced (every browser session
# dies with Chrome regardless) costs nothing beyond a fast, retryable error
# in any in-flight call. ORDERING: call this only when the old Chrome is
# already dead or dying (after _kill_chrome, or after the systemd unit
# bounce) — killed earlier, a daemon respawned by an in-flight CLI retry
# would attach to the doomed old Chrome and recreate the #492 wedge.
_kill_agent_browser() {
    pkill -f "agent-browser-linux" 2>/dev/null || true
    sleep 1
    pkill -9 -f "agent-browser-linux" 2>/dev/null || true
    # SIGKILL leaves per-session .sock/.pid files behind, and dead-pid
    # detection on the next CLI call is not documented agent-browser
    # behavior — remove them so a fresh CLI can never trip over a stale
    # socket (whose "daemon may be busy" error agents are told to treat
    # as a permanent wedge).
    rm -f "$HOME/.agent-browser"/*.sock "$HOME/.agent-browser"/*.pid 2>/dev/null || true
}

_wait_chrome_ready() {
    local _i
    # Wait for Xvfb display socket (up to 10s)
    for _i in $(seq 1 10); do
        if [[ -e /tmp/.X11-unix/X99 ]]; then
            _rl_log "Xvfb display :99 ready"
            break
        fi
        sleep 1
    done
    # Wait for CDP to be ready (up to 15s)
    for _i in $(seq 1 15); do
        if curl -sf http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
            _rl_log "Chrome CDP ready on port 9222"
            return 0
        fi
        sleep 1
    done
    _rl_log "Warning: Chrome did not become ready within 15s"
    return 1
}

_restart_chrome() {
    _rl_log "Restarting Chrome..."
    # Stamp monitor.sh's respawn cooldown so its TASK 8 CDP health check does
    # not also try to respawn Chrome during the brief window we have it killed
    # (it suppresses a respawn for 300s after this timestamp). Avoids two
    # restarts racing for display :99 / CDP :9222.
    date +%s > /tmp/browser_last_respawn 2>/dev/null || true
    if [[ "${CONTAINER:-}" == "true" ]] || [[ -f /.dockerenv ]]; then
        # Container: kill entire process tree, then relaunch
        _kill_chrome
        _kill_agent_browser
        export DISPLAY=:99
        # setsid + full stdio detach: Chrome outlives the caller, so it must NOT
        # inherit the caller's stdio (an inherited stdout pipe wedges a cron job
        # / wedges the Bash tool that triggered an on-demand restart) nor sit in
        # the caller's process group where a group signal would take it down.
        setsid xvfb-run --server-num=99 -s "-screen 0 1920x1080x24" \
            -f /tmp/.Xauthority \
            "$CLAUDE_HOME/core/start-browser.sh" \
            </dev/null >/dev/null 2>&1 &
        _wait_chrome_ready
    elif systemctl cat stealth-chrome.service >/dev/null 2>&1; then
        # VM with the stealth-chrome systemd unit installed. That unit has
        # Restart=always, so the clean restart path is to bounce the unit and
        # let systemd relaunch it. Do NOT also kill+relaunch Chrome manually —
        # that races systemd's auto-restart, leaving two Chromes fighting over
        # CDP :9222 and the profile SingletonLock.
        #
        # sudo -n (non-interactive) so this never blocks on a password prompt;
        # it relies on the passwordless sudoers rule for stealth-chrome restart
        # added by install/deps.sh. Falls back to a user unit if present. If
        # neither restart succeeds Chrome is simply left running (no race).
        if sudo -n systemctl restart stealth-chrome.service 2>/dev/null \
            || systemctl --user restart stealth-chrome.service 2>/dev/null; then
            # systemd only manages Chrome — agent-browser processes are NOT
            # part of the unit, so wedged ones must still be killed manually.
            # AFTER the bounce (per _kill_agent_browser's ordering note: killed
            # before it, a daemon respawned by a CLI retry could attach to the
            # old Chrome in its final seconds and hold a dead socket with
            # nothing left to clear it), and ONLY when the bounce succeeded —
            # when neither systemctl call works, Chrome is deliberately left
            # running, and killing agent-browser then would abort healthy
            # in-flight calls against a live browser.
            _kill_agent_browser
        fi
        _wait_chrome_ready
    else
        # VM without the systemd unit (manual/dev setup): kill + relaunch directly.
        _kill_chrome
        _kill_agent_browser
        export DISPLAY=:99
        # Same stdio detach as the container path.
        setsid xvfb-run --server-num=99 -s "-screen 0 1920x1080x24" \
            -f "$HOME/.Xauthority" \
            "$CLAUDE_HOME/core/start-browser.sh" \
            </dev/null >/dev/null 2>&1 &
        _wait_chrome_ready
    fi
}

# ── Claude session ───────────────────────────────────────────────────────────

# Grace windows (seconds) for _exit_claude below. Overridable for tests.
RESTART_EXIT_GRACE="${RESTART_EXIT_GRACE:-10}"  # SIGTERM → process gone
RESTART_KILL_GRACE="${RESTART_KILL_GRACE:-5}"   # SIGKILL → process gone

# Locate the long-lived Claude TUI process(es), newline-separated, for
# _exit_claude to kill. Overridden in tests.
#
# Anchors are the same as monitor.sh's find_claude_pid (run.sh exports
# CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 precisely so the full argv stays
# visible to pgrep -f), but with two deliberate differences — this helper
# feeds a KILL, monitor.sh's feeds health checks, so wrong-target costs
# differ and the implementations must too:
#   - ALL matches are returned, not `head -1`: when run.sh falls back to
#     CLAUDE_BIN="bunx claude" / "npx @anthropic-ai/claude-code", the wrapper
#     AND the real claude child both match, pgrep lists the earlier-forked
#     wrapper first, and npx does not forward signals — killing only the
#     first pid would kill the wrapper, orphan the real claude, and let
#     run.sh relaunch a SECOND claude alongside it (poller 409s, two TUIs).
#   - Matches are kept only if the claudebot pane's pid is among their
#     ancestors, so a bystander that merely looks like claude — monitor.sh's
#     headless `claude -p` rate-limit probe (comm "claude"), a dev's manual
#     SSH session — can never be targeted. Every launch path runs run.sh as
#     the pane command (entrypoint.sh, install/services.sh, claudebot.service),
#     so the managed claude is always inside the pane's tree. If the pane
#     cannot be resolved (tmux gone), only the argv-anchored matches are
#     trusted — never the bare comm matches, which is where bystanders live.
_find_claude_pids() {
    local matches pane_pids p pp
    matches=$({ pgrep -f "claude.*--channels" 2>/dev/null; pgrep -x claude 2>/dev/null; } | sort -un)
    [ -z "$matches" ] && return 0
    pane_pids=" $(tmux -L claudebot list-panes -s -t "${TMUX_SESSION}" -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ') "
    if [ "$pane_pids" = "  " ]; then
        pgrep -f "claude.*--channels" 2>/dev/null
        return 0
    fi
    for p in $matches; do
        pp=$p
        while [[ "$pp" =~ ^[0-9]+$ ]] && [ "$pp" -gt 1 ]; do
            if [[ "$pane_pids" == *" $pp "* ]]; then
                echo "$p"
                break
            fi
            pp=$(ps -o ppid= -p "$pp" 2>/dev/null | tr -d ' ')
        done
    done
}

# Wait up to $2 seconds for every pid in $1 (whitespace-separated) to
# disappear; returns 0 as soon as all are gone.
_wait_pids_gone() {
    local pids="$1" timeout="$2" waited=0 p alive
    while :; do
        alive=""
        for p in $pids; do
            kill -0 "$p" 2>/dev/null && alive="$alive $p"
        done
        [ -z "$alive" ] && return 0
        (( waited >= timeout )) && return 1
        sleep 1
        waited=$(( waited + 1 ))
    done
}

# Stop the live Claude session; run.sh's while-loop relaunches it ~5s later.
#
# This kills the process directly instead of typing /exit into the TUI
# (issue #448). Newer Claude Code versions interpose an interactive
# confirmation dialog on /exit when background Task agents are running
# ("a background agent is still running — exiting will stop it, proceed?"),
# and there is NO flag, env var, or settings key to suppress it — verified
# against the official docs (settings, env-vars, CLI reference, headless)
# and cli.js: --dangerously-skip-permissions covers only permission prompts,
# and the sole related switch, CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1, would
# disable background agents entirely (a non-starter — the whole system runs
# on them). A dialog nobody can answer parked the session forever: Claude
# never exited, run.sh never relaunched (so no "starting up"/"Claude
# started" messages) — yet _wait_claudebot_ready then validated the
# STILL-ALIVE old instance's webhook/poller as "relaunched and healthy" and
# restart.sh announced "Restart complete" for a restart that never happened.
#
# A direct kill is safe by construction here, and is the same mechanism
# monitor.sh's TASK 3 has always used to bounce Claude:
#   - run.sh's supervisor loop treats ANY exit — clean or killed — identically:
#     relaunch after 5s, preceded by the full cleanup a graceful exit needs
#     anyway (orphan telegram poller kill, getUpdates-409 wait, stale agent
#     watchers), since even a clean /exit leaves those orphans behind.
#   - The transcript JSONL is appended incrementally during the session, not
#     flushed at exit, and background Task agents die with the process either
#     way — so /exit saves nothing user-visible that a kill loses.
# SIGTERM first (lets the process exit cleanly), SIGKILL if it lingers.
#
# Returns 0 once the process is gone (or none was found — Claude already
# down, run.sh will (re)launch it); 1 only if it survived SIGKILL — callers
# must then NOT trust _wait_claudebot_ready, which would greenlight the
# never-restarted session.
#
# Deliberately NO tmux /exit fallback on the no-pid path: typed keystrokes
# either reach a live TUI (where the #448 dialog can wedge them) or sit in
# the pty buffer during run.sh's relaunch gap and get delivered into the
# NEXT session's fresh TUI — both strictly worse than doing nothing.
_exit_claude() {
    local pids
    # Mark the outage as planned BEFORE the kill, so a monitor.sh iteration that
    # lands anywhere between here and run.sh's relaunch already sees the stamp
    # (see PLANNED_RESTART_STAMP above — issue #513). Stamped on the no-pid path
    # too: Claude is already down and run.sh is mid-relaunch, which is exactly
    # the window this covers. Never fatal — a stamp we couldn't write just means
    # the pre-#513 behaviour.
    date +%s > "$PLANNED_RESTART_STAMP" 2>/dev/null || true
    pids=$(_find_claude_pids)
    if [ -z "$pids" ]; then
        _rl_log "no Claude process found — nothing to stop (run.sh relaunches on its own)"
        return 0
    fi
    # shellcheck disable=SC2086  # pids is a deliberate word-split list
    _rl_log "Stopping Claude (pid(s)$(echo " $pids" | tr '\n' ' ')) with SIGTERM"
    kill $pids 2>/dev/null || true
    _wait_pids_gone "$pids" "$RESTART_EXIT_GRACE" && return 0
    _rl_log "Claude survived SIGTERM — escalating to SIGKILL"
    kill -9 $pids 2>/dev/null || true
    _wait_pids_gone "$pids" "$RESTART_KILL_GRACE" && return 0
    _rl_log "Warning: Claude survived SIGKILL — the session was NOT restarted"
    return 1
}

_wait_claudebot_ready() {
    # Healthy = webhook :8788 answering (channels loaded — see run.sh's
    # auto-accept helper) AND a live Telegram poller whose bot.pid belongs to
    # the NEW instance. The old instance's webhook/poller can survive ~7s into
    # the shutdown (and run.sh clears bot.pid before relaunching), so wait out
    # that grace first rather than trusting an early positive.
    local pid_file="$HOME/.claude/channels/telegram/bot.pid"
    sleep 15
    local start=$SECONDS
    while [ $(( SECONDS - start )) -lt 240 ]; do
        if curl -sf --max-time 2 http://127.0.0.1:8788/health >/dev/null 2>&1; then
            local pid
            pid=$(cat "$pid_file" 2>/dev/null | tr -d '[:space:]')
            if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null \
               && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "server\.ts"; then
                _rl_log "Claude relaunched and healthy (webhook up, telegram poller PID $pid)"
                return 0
            fi
        fi
        sleep 2
    done
    _rl_log "Warning: relaunched Claude not verifiably healthy after 240s"
    return 1
}
