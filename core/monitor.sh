#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Determine CLAUDE_HOME dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# Tolerant .env loader (issue #387): parse KEY=VALUE literally so a value with
# spaces can't run as a command or abort under `set -e`.
if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
    source "$CLAUDE_HOME/core/env-loader.sh"; load_env
else
    [[ -f "$CLAUDE_HOME/.env" ]] && source "$CLAUDE_HOME/.env" || true
fi
# Auth mode resolver (token | login) — single source of truth, side-effect free.
[[ -f "$CLAUDE_HOME/core/auth-mode.sh" ]] && source "$CLAUDE_HOME/core/auth-mode.sh"
# Interactive-dialog detection/recovery primitives (issue #448) — side-effect
# free. Call sites (is_frozen step 3, TASK 9) are gated on the functions
# actually existing so a partial deploy degrades to the pre-#448 behavior.
[[ -f "$CLAUDE_HOME/core/dialog-detect.sh" ]] && source "$CLAUDE_HOME/core/dialog-detect.sh"
export TMUX_TMPDIR=/tmp

# Put node + the nvm-installed `claude` on PATH (same as run.sh does).
# monitor.sh runs in a non-login shell that doesn't otherwise source nvm,
# so without this the claude-binary resolution below can't find `claude`
# and falls through to `bunx claude` -- which re-downloads Claude Code into
# /tmp on every invocation. With no cleanup that fills the 512MB /tmp tmpfs
# (shared with Chrome's profile/cache) and crashes the browser. See issue #68.
export HOME="${HOME:-$(dirname "$CLAUDE_HOME")}"
# $CLAUDE_HOME/.npm-global/bin holds the runtime-installed Claude Code CLI in
# container mode (CC is not redistributable, so it's pulled at first run rather
# than baked into the image). Lead the PATH with it so the resolution below finds
# `claude` here instead of falling through to `bunx claude` (the /tmp-filling
# footgun this block already guards against). Harmless on VM installs.
export PATH="$CLAUDE_HOME/.npm-global/bin:$PATH"
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true

# `claude auth status` below must never trigger an in-place self-update — an
# interrupted binary rewrite SIGBUSes every later launch (see run.sh). VM
# installs run monitor.sh outside run.sh, so set it here too.
export DISABLE_AUTOUPDATER=1

# TASK 1 TRIGGER pattern (case-insensitive substring match on the recent log).
# This is only a cheap TRIGGER: every match is corroborated by a `claude -p`
# probe (claude_probe_classify) before we notify, so it is tuned to be SENSITIVE
# (catch real limits), not precise — extra noise costs only a silent probe,
# whereas a missed real-limit string costs the whole notification. Covers the
# documented Claude limit/credit messages (code.claude.com/docs/en/errors):
# "You've hit your session/weekly/Opus limit", "Credit balance is too low",
# "Usage credits required", "Request rejected (429)", "Server is temporarily
# limiting requests", plus the generic rate/usage/retry phrasings. 529/overloaded
# is intentionally omitted (transient capacity, "not your usage limit").
PATTERN="usage limit|rate limit|message limit|out of (messages|credits)|hit your ((session|weekly|opus|usage|message|daily) )?limit|credit balance|usage credits|request rejected|too many requests|temporarily limiting|try again (in|at)"

send_tg() {
    # --data-urlencode: a literal & in the message would otherwise split into
    # extra POST fields (overriding chat_id/parse_mode) and truncate the text.
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         --data-urlencode chat_id="${TELEGRAM_CHAT_ID}" \
         --data-urlencode text="$1" \
         --data-urlencode parse_mode="Markdown" >/dev/null 2>&1
}

# How the user can restart TaskRamen. Deployments differ, and pointing every
# user at the Windows tray app left self-hosted users (the only ones this
# repository supports on its own) with instructions they cannot follow.
_restart_hint() {
    if [[ -n "${TASKRAMEN_TRAY:-}" ]]; then
        echo "open the TaskRamen system tray app and use Repair → Restart"
    else
        echo "restart TaskRamen with \`core/restart.sh\`"
    fi
}

# Whether the OpenRouter fallback is actually usable on this install. Only
# mention it when it is: an offer the user cannot act on is worse than silence.
_openrouter_available() {
    [[ -n "${OPENROUTER_API_KEY:-}" ]] || return 1
    [[ -x "$CLAUDE_HOME/core/toggle-proxy.sh" ]] || return 1
    command -v ccr >/dev/null 2>&1 || return 1
    return 0
}

# Sentence appended to a confirmed usage-limit notice, naming the remediation
# that exists on THIS install. Empty when there is nothing to suggest.
_fallback_hint() {
    if _openrouter_available; then
        printf ' You can keep working in the meantime by switching to the OpenRouter fallback: run `core/toggle-proxy.sh on` (and `core/toggle-proxy.sh off` to switch back once your usage resets).'
    fi
}

MONITOR_LOG="/tmp/monitor.log"

log_monitor() {
    (
        flock -x 200
        echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] $*" >> "$MONITOR_LOG"
    ) 200>"${MONITOR_LOG}.lock"
}

# Respawn the shared stealth Chromium (CDP :9222). Used by the frozen-restart
# path (issue #68) and the generic CDP health check (TASK 8, issue #305).
# Container: kill chromium + Xvfb, clean up, relaunch under Xvfb :99.
# VM: kill chromium (systemd stealth-chrome.service auto-restarts it).
respawn_browser() {
    pkill -f "start-browser.sh" 2>/dev/null || true
    pkill -f "chromium" 2>/dev/null || true
    # Wedged agent-browser CLI/daemon processes survive TaskStop and are not
    # systemd-managed — clear them whenever Chrome is respawned (issue #492;
    # same binary-name anchor as _kill_agent_browser in core/restart-lib.sh).
    pkill -f "agent-browser-linux" 2>/dev/null || true
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        pkill -f "Xvfb :99" 2>/dev/null || true
        pkill -f "matchbox-window-manager" 2>/dev/null || true
        sleep 2
        pkill -9 -f "start-browser.sh" 2>/dev/null || true
        pkill -9 -f "chromium" 2>/dev/null || true
        pkill -9 -f "agent-browser-linux" 2>/dev/null || true
        pkill -9 -f "Xvfb :99" 2>/dev/null || true
        pkill -9 -f "matchbox-window-manager" 2>/dev/null || true
        # SIGKILL'd daemons leave stale .sock/.pid files; remove them so the
        # next CLI call can't hit a "daemon may be busy" stale socket (same
        # cleanup as _kill_agent_browser in core/restart-lib.sh).
        rm -f "$HOME/.agent-browser"/*.sock "$HOME/.agent-browser"/*.pid 2>/dev/null || true
        rm -f "$CLAUDE_HOME/.chrome-profile"/SingletonLock \
              "$CLAUDE_HOME/.chrome-profile"/SingletonSocket \
              "$CLAUDE_HOME/.chrome-profile"/SingletonCookie 2>/dev/null || true
        rm -f /tmp/.X11-unix/X99 2>/dev/null || true
        xvfb-run --server-num=99 -s "-screen 0 1920x1080x24" \
            -f /tmp/.Xauthority \
            "$CLAUDE_HOME/core/start-browser.sh" &
    else
        # VM: chromium is supervised by stealth-chrome.service (Restart=always),
        # so a clean exit is enough — systemd relaunches it. But this function
        # exists to recover a HUNG Chrome, and a hung process can ignore the
        # SIGTERM above and never exit, so systemd never respawns it. Force-kill
        # the straggler after a grace period so the service can bring it back.
        sleep 2
        pkill -9 -f "chromium" 2>/dev/null || true
        pkill -9 -f "agent-browser-linux" 2>/dev/null || true
        rm -f "$HOME/.agent-browser"/*.sock "$HOME/.agent-browser"/*.pid 2>/dev/null || true
    fi
}

# Helper: find the claudebot Claude PID. Two-fold lookup so the watchdog
# survives both Linux Node rewriting /proc/<pid>/cmdline via
# process.title="claude" (cmdline match fails) and a future Claude Code
# release removing the CLAUDE_CODE_DISABLE_TERMINAL_TITLE escape hatch
# (comm match fails). Cmdline match is tried first because it is selective
# to the --channels invocation, so a stray manual `claude` running on the
# box won't get picked up.
find_claude_pid() {
    local pid
    pid=$(pgrep -f "claude.*--channels" 2>/dev/null | head -1)
    [ -z "$pid" ] && pid=$(pgrep -x claude 2>/dev/null | head -1)
    [ -n "$pid" ] && echo "$pid"
}

# Helper: after bouncing Claude (TASK 3), wait up to 60s for a fresh, live
# telegram poller to appear in bot.pid. A fixed short sleep is not enough:
# run.sh deletes bot.pid before every relaunch, and relaunch (5s) + Claude
# boot + dev-channels accept + plugin spawn routinely exceeds 25s — a one-shot
# check then reports "recovery failed" for a recovery that is merely slow.
# Pass the pre-restart poller PID ("" if none) so a lingering stale entry
# isn't mistaken for recovery. On success sets TG_RECOVERED_PID and returns 0.
tg_wait_recovered() {
    local old_pid="$1" _i new_pid
    for _i in $(seq 1 12); do
        sleep 5
        new_pid=$(cat "$HOME/.claude/channels/telegram/bot.pid" 2>/dev/null | tr -d '[:space:]')
        if [[ "$new_pid" =~ ^[0-9]+$ ]] && [ "$new_pid" != "$old_pid" ] \
           && kill -0 "$new_pid" 2>/dev/null \
           && tr '\0' ' ' < "/proc/$new_pid/cmdline" 2>/dev/null | grep -q "server\.ts"; then
            TG_RECOVERED_PID="$new_pid"
            return 0
        fi
    done
    return 1
}

# Helper: get the active session's JSONL file path
get_active_jsonl() {
    local claude_pid
    claude_pid=$(find_claude_pid)
    [ -z "$claude_pid" ] && return 1

    local session_json="$HOME/.claude/sessions/${claude_pid}.json"
    [ ! -f "$session_json" ] && return 1

    local session_id
    session_id=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['sessionId'])" "$session_json" 2>/dev/null)
    [ -z "$session_id" ] && return 1

    local project_segment
    # Claude Code stores per-project JSONL under ~/.claude/projects/<segment>/
    # where <segment> is the absolute project path with EVERY non-alphanumeric
    # character rewritten to `-` (verified in cli.js: replace(/[^a-zA-Z0-9]/g,
    # "-")) — not just slashes: a `.` or `_` in CLAUDE_HOME (e.g.
    # /home/john.doe/taskramen) becomes a dash too, and a slash-only rewrite
    # resolves a directory that never exists, silently making this freshness
    # check return failure on every call. Same for the leading dash from the
    # leading slash: /home/foo/bar becomes "-home-foo-bar" — do NOT strip it.
    # For very long paths CC additionally truncates the segment with a hash
    # suffix; not replicated here (unchanged limitation). Keep this expression
    # in sync with the transcript snapshot in core/run.sh.
    project_segment=$(echo "$CLAUDE_HOME" | sed 's|[^a-zA-Z0-9]|-|g')
    local jsonl_path="$HOME/.claude/projects/${project_segment}/${session_id}.jsonl"
    [ -f "$jsonl_path" ] && echo "$jsonl_path" && return 0
    return 1
}

# Helper: get file age in seconds
file_age_sec() {
    local filepath="$1"
    [ ! -f "$filepath" ] && echo 999999 && return
    local mtime
    mtime=$(stat -c%Y "$filepath" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    echo $(( now - mtime ))
}

# Planned-restart suppression (issue #513).
#
# core/restart-lib.sh (nightly review + on-demand restart.sh) and this monitor's
# own restart paths all stop Claude and let run.sh relaunch it, leaving a
# ~10-40s window with no claude process (run.sh's 5s relaunch sleep, orphan
# poller kill, up to 15s of getUpdates-409 draining, then Claude's own spawn).
# is_frozen()'s step 1 flags a missing process as frozen on the spot, so an
# iteration landing in that window Telegrammed the user a false "Claude appears
# frozen (check 1/5)" during a perfectly healthy nightly restart. Whoever takes
# Claude down deliberately stamps this file; step 1 stays quiet while it's
# fresh. Same cross-process suppression _restart_chrome/TASK 8 already use via
# /tmp/browser_last_respawn. Path must match core/restart-lib.sh's definition.
PLANNED_RESTART_STAMP="${PLANNED_RESTART_STAMP:-/tmp/claude_planned_restart}"
# Worst case covered: 10s SIGTERM grace + 5s SIGKILL grace + run.sh's 5s
# relaunch sleep + ~15s 409 drain + Claude's spawn — comfortably under a minute,
# so 180s leaves 3x margin on a loaded box. The cost is bounded: a restart that
# genuinely never comes back is flagged the moment the stamp goes stale, still
# far inside TASK 2's ~10-min escalation to a monitor-driven restart.
PLANNED_RESTART_GRACE="${PLANNED_RESTART_GRACE:-180}"

stamp_planned_restart() { date +%s > "$PLANNED_RESTART_STAMP" 2>/dev/null || true; }

# A missing, unreadable or old stamp is stale (file_age_sec answers 999999 when
# the file isn't there), so every failure mode of this helper degrades to exactly
# the pre-#513 behaviour. It can only ever mute the planned-restart window.
planned_restart_fresh() {
    [ "$(file_age_sec "$PLANNED_RESTART_STAMP")" -lt "$PLANNED_RESTART_GRACE" ]
}

# Helper: epoch seconds of the most recent ASSISTANT-authored transcript entry.
# Only assistant entries prove the inference loop produced output. Inbound
# user/queue entries are written to the transcript the instant a message
# arrives (before the model touches it), so file mtime is NOT a liveness
# signal — a wedged session still receiving triggers keeps the file warm.
# The most recent assistant entry is what the ignored-input freeze check
# compares against (issue #306).
#
# Scans the tail of the JSONL (assistant entries are normally near the end).
# If none is found in the window — e.g. a single huge tool_result blob at the
# end — it falls back to the file mtime, which is conservative: a large recent
# write means the session is actively producing, so we err toward "not frozen".
last_assistant_epoch() {
    local jsonl_path="$1"
    { [ -z "$jsonl_path" ] || [ ! -f "$jsonl_path" ]; } && echo 0 && return
    python3 - "$jsonl_path" <<'PYEOF'
import json, os, sys
from datetime import datetime
path = sys.argv[1]
last = 0
try:
    with open(path, 'rb') as f:
        f.seek(0, 2)
        size = f.tell()
        start = max(0, size - 262144)  # last 256KB
        f.seek(start)
        chunk = f.read().decode('utf-8', errors='replace')
    lines = [l for l in chunk.splitlines() if l.strip()]
    if start > 0 and lines:
        lines = lines[1:]  # drop a possibly-truncated first line
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get('type') != 'assistant':
            continue
        ts = d.get('timestamp')
        if not ts:
            continue
        try:
            last = int(datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp())
            break
        except Exception:
            continue
    if last == 0:
        last = int(os.path.getmtime(path))
except Exception:
    last = 0
print(last)
PYEOF
}

is_frozen() {
    FROZEN_REASON=""
    # 1. Process check: is claude process alive?
    if [ -z "$(find_claude_pid)" ]; then
        # A deliberate restart (nightly review, on-demand restart.sh, or one of
        # this monitor's own restart paths) leaves a short no-process window
        # while run.sh relaunches — that is a healthy restart in progress, not a
        # freeze, and must not reach the user as one (issue #513). Only step 1
        # consults the stamp: the later steps judge a session that IS running,
        # where a planned restart tells us nothing.
        if planned_restart_fresh; then
            log_monitor "TASK=frozen STATUS=ok DETAILS=\"step1: no process, but inside planned-restart window ($(file_age_sec "$PLANNED_RESTART_STAMP")s of ${PLANNED_RESTART_GRACE}s)\""
            return 1  # planned outage → NOT frozen
        fi
        FROZEN_REASON="Claude process not found"
        log_monitor "TASK=frozen STATUS=check DETAILS=\"step1: Claude process not found\""
        return 0  # process dead → frozen
    fi

    # 2. JSONL freshness (PRIMARY signal)
    local jsonl_path
    jsonl_path=$(get_active_jsonl)
    if [ -n "$jsonl_path" ]; then
        local jsonl_age
        jsonl_age=$(file_age_sec "$jsonl_path")
        if [ "$jsonl_age" -lt 600 ]; then
            log_monitor "TASK=frozen STATUS=ok DETAILS=\"step2: JSONL fresh (${jsonl_age}s)\""
            return 1  # JSONL fresh → NOT frozen
        fi
    fi

    # 3. Terminal intervention check: is Claude wedged on an interactive dialog?
    #
    # Rewritten for issue #448. Detection/recovery primitives live in
    # core/dialog-detect.sh (verified anchors + the generic select-widget
    # signature, careful one-press-at-a-time Escape, optional never-load-bearing
    # `claude -p` probe; the shared escape+tiebreak sequence is
    # dialog_escape_and_tiebreak so this step and TASK 9 cannot drift). This
    # step only acts when the transcript RESOLVED and is stale (step 2): an
    # unresolvable transcript (right after a claudebot relaunch, before the
    # session file exists) gives no staleness evidence, and acting then would
    # let step 3 Escape the startup channels prompt out from under run.sh's
    # auto-accept helper, or interrupt a working session whose pane merely
    # shows dialog-shaped text. TASK 9 in the main loop runs the same scan
    # every iteration for sessions whose transcript MTIME is kept artificially
    # fresh by inbound triggers (limitation (b) in step 4's notes).
    if declare -F dialog_pane_match >/dev/null 2>&1 && [ -n "$jsonl_path" ]; then
        # 3a. A fresh stuck-sentinel means an earlier cycle CONFIRMED a dialog
        # that Escape could not clear. Return frozen directly so the verdict
        # stays stable across TASK 2's 5x2min re-checks — the escape/probe
        # cooldowns would otherwise make each re-check fall through to step 4
        # and flap between frozen/recovered mid-escalation. TASK 9 clears the
        # sentinel the moment any scan sees a dialog-free pane, and monitor-
        # initiated restarts clear it via _reset_dialog_state.
        if dialog_stuck_sentinel_fresh; then
            FROZEN_REASON="stuck on interactive dialog, Escape did not clear"
            log_monitor "TASK=frozen STATUS=check DETAILS=\"step3: stuck-dialog sentinel fresh\""
            return 0
        fi

        local pane_tail d3_verdict
        pane_tail=$(dialog_capture_pane_tail)
        if [ -n "$pane_tail" ] && printf '%s\n' "$pane_tail" | dialog_pane_match; then
            if dialog_fp_match "$pane_tail"; then
                # This exact pane text was already judged dialog-shaped TEXT
                # (Escape no-op + probe POSITIVELY said not-a-dialog).
                log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: pane matches recorded false-positive text — skipping\""
            else
                d3_verdict=$(dialog_escape_and_tiebreak "$pane_tail" pattern)
                case "$d3_verdict" in
                cleared)
                    # Dialog gone from the pane. Give the unblocked model time
                    # to produce output, then judge by the transcript as before.
                    sleep 120
                    if [ "$(file_age_sec "$jsonl_path")" -lt 600 ]; then
                        log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: recovered after Escape\""
                        return 1
                    fi
                    # Dialog cleared but the transcript is still quiet: the
                    # blocking condition is resolved, yet this proves nothing
                    # about overall health — FALL THROUGH to steps 4/5 (no
                    # early "not frozen": inside TASK 2's re-check loop an
                    # early return here would abort a live escalation with a
                    # false "Claude is now responding").
                    log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: dialog cleared after Escape, transcript still quiet — deferring to steps 4/5\""
                    ;;
                stuck)
                    FROZEN_REASON="stuck on interactive dialog, Escape did not clear"
                    log_monitor "TASK=frozen STATUS=check DETAILS=\"step3: dialog survived Escape, probe confirmed stuck\""
                    return 0
                    ;;
                fp)
                    log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: Escape no-op, probe said not-a-dialog — recorded as false-positive text\""
                    ;;
                *)
                    # cooldown/ambiguous: no evidence either way — nothing
                    # recorded, retried next window; steps 4/5 still apply.
                    log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: dialog signature, no verdict ($d3_verdict) — will retry after cooldowns\""
                    ;;
                esac
            fi
        elif [ -n "$pane_tail" ] && [ -n "$CLAUDE_BIN" ] \
             && dialog_cooldown_ok "$DIALOG_PROBE_STAMP" "$DIALOG_PROBE_COOLDOWN"; then
            # 3b. Path B (issue #448): transcript stale but NO known dialog
            # signature — the exact hole the #448 exit-confirmation fell into
            # before its text was known. Ask `claude -p` whether the pane shows
            # a blocking dialog we have no regex for. Only a verbatim STUCK
            # acts; ok/ambiguous/probe-gone all fall through to steps 4/5
            # exactly as before this feature existed.
            dialog_stamp "$DIALOG_PROBE_STAMP"
            if [ "$(printf '%s\n' "$pane_tail" | dialog_probe_classify)" = "stuck" ]; then
                log_monitor "TASK=frozen STATUS=check DETAILS=\"step3: probe detected an unknown blocking dialog — attempting Escape\""
                # hash mode: no pattern ever matched, so "cleared" = pane
                # changed, confirmed by a probe (see dialog_escape_and_tiebreak).
                d3_verdict=$(dialog_escape_and_tiebreak "$pane_tail" hash)
                case "$d3_verdict" in
                cleared)
                    sleep 120
                    if [ "$(file_age_sec "$jsonl_path")" -lt 600 ]; then
                        log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: recovered after Escape (probe-detected dialog)\""
                        return 1
                    fi
                    log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: probe-detected dialog cleared, transcript still quiet — deferring to steps 4/5\""
                    ;;
                stuck)
                    FROZEN_REASON="stuck on interactive dialog (probe-detected), Escape did not clear"
                    log_monitor "TASK=frozen STATUS=check DETAILS=\"step3: probe-detected dialog survived Escape\""
                    return 0
                    ;;
                *)
                    log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: probe-detected dialog, no escape verdict ($d3_verdict)\""
                    ;;
                esac
            fi
        fi
    elif declare -F dialog_pane_match >/dev/null 2>&1; then
        log_monitor "TASK=frozen STATUS=ok DETAILS=\"step3: transcript unresolvable — skipping dialog check (no staleness evidence)\""
    fi

    # 4. Ignored-input check (SECONDARY signal, only reached when JSONL is stale)
    #
    # OLD rule (buggy, issue #306): frozen if JSONL stale AND any webhook
    # pending >600s. A forgotten `ack` left a long-since-handled trigger sitting
    # "pending" forever, which looked identical to fresh unanswered input — so a
    # perfectly healthy IDLE session got restarted.
    #
    # NEW rule: frozen if the OLDEST genuinely-unanswered input has waited
    # >FREEZE_GRACE. "Unanswered" = its delivery postdates the session's last
    # assistant-authored transcript entry (no assistant output has appeared
    # since it arrived). Why this is robust:
    #   - Inbound user/queue entries are written on arrival and prove nothing;
    #     only an assistant entry proves the inference loop produced output.
    #   - That assistant turn is the mechanical product of the model processing
    #     a prompt — unlike `ack`, it cannot be "forgotten". A handled-but-
    #     unacked trigger was delivered BEFORE the reply, so it is filtered out
    #     as "answered" and no longer trips this.
    #   - We take the OLDEST unanswered input (not the newest), so a steady
    #     drip of fresh triggers during a real hang can't keep resetting the
    #     clock and mask it — the original input keeps aging past the grace.
    # A genuinely ignored input — real hang, or a silently-unloaded channel that
    # never reaches the model — still trips it.
    #
    # ── UNHANDLED / KNOWN-LIMITATION EDGE CASES (deliberately not covered) ──
    #  a) LONG TOOL CALLS / BACKGROUND AGENTS: from the transcript alone this
    #     cannot tell a real mid-tool deadlock from a legitimate long-running
    #     tool call or a long Task/sub-agent (both look like "last assistant
    #     entry is a tool_use, nothing after"). An input delivered WHILE a
    #     healthy >FREEZE_GRACE tool runs is seen as unanswered and can
    #     mis-flag. Mitigated, not eliminated, by the 10-min grace + TASK 2's
    #     5×2min re-checks (a tool finishing within ~20 min self-clears).
    #     Closing it fully needs a process-level liveness probe (CPU / child
    #     process), intentionally omitted to keep this check simple.
    #  b) STEP-2 mtime MASKING: this step is only reached when step 2 finds the
    #     JSONL stale (>600s). IF Claude Code writes inbound channel messages to
    #     the transcript on arrival (unverified for the channel path), each
    #     incoming trigger bumps the file mtime and keeps step 2 "fresh", so a
    #     hung session under a steady drip is masked at step 2 and never reaches
    #     here. Fixing that would mean rebasing step 2 onto last_assistant_epoch
    #     too — a riskier change to the primary signal, left out of scope.
    #  c) TRANSCRIPT NOT RESOLVABLE: if get_active_jsonl() failed or the file
    #     can't be read, last_assistant_epoch returns 0 and we cannot tell
    #     answered from unanswered inputs. Rather than count every pending input
    #     as unanswered (which would reintroduce the #306 false restart), this
    #     step SKIPS the ignored-input check. Residual limitation: a real hang
    #     whose transcript also can't be resolved won't be caught HERE — it
    #     falls to step 1 (process gone) / step 5 (zombie/stopped) instead.
    #  d) DEPLOY ORDERING: the webhook server is MCP-spawned and only restarts
    #     with claudebot. Until it restarts after this change, /health omits
    #     pendingAgesSec, so oldest_unanswered=0 and this step is a safe no-op
    #     (no false positives, just no ignored-input detection) until then.
    #  Net bias: this step errs toward MISSING a hang rather than falsely
    #  restarting a healthy session; a truly dead process is still caught by
    #  step 1 (process gone) and step 5 (zombie/stopped).
    local FREEZE_GRACE=600  # an unanswered input must wait this long (10 min) to count
    local health
    health=$(curl -sf --max-time 5 http://127.0.0.1:8788/health 2>/dev/null)
    if [ $? -eq 0 ]; then
        local now last_resp oldest_unanswered
        now=$(date +%s)
        last_resp=$(last_assistant_epoch "$jsonl_path")
        # Edge case (c): last_assistant_epoch returns 0 ONLY when the transcript
        # could not be resolved/read (empty path, missing file, or read error).
        # A resolved transcript always yields a real epoch (assistant entry, or
        # the mtime fallback). With last_resp=0 we cannot tell answered from
        # unanswered inputs, so SKIP the ignored-input check entirely — counting
        # every pending input as unanswered here would reintroduce the #306
        # false restart (a forgotten-ack trigger would look unanswered). A truly
        # dead/zombie process is still caught by step 1 and step 5.
        if [ "${last_resp:-0}" -eq 0 ]; then
            log_monitor "TASK=frozen STATUS=ok DETAILS=\"step4: transcript unresolvable (last_resp=0), skipping ignored-input check\""
        else
            # Oldest pending input (in seconds) that arrived AFTER last_resp, i.e.
            # genuinely unanswered. 0 if none. Answered-but-unacked triggers
            # (delivered before last_resp) are excluded.
            oldest_unanswered=$(echo "$health" | python3 -c '
import json, sys
try:
    ages = json.load(sys.stdin).get("pendingAgesSec") or []
except Exception:
    print(0); sys.exit()
now = int(sys.argv[1]); last_resp = int(sys.argv[2])
# unanswered: received after last_resp  <=>  (now - age) > last_resp
unanswered = [a for a in ages if (now - a) > last_resp]
print(max(unanswered) if unanswered else 0)
' "$now" "${last_resp:-0}" 2>/dev/null || echo 0)
            if [ "${oldest_unanswered:-0}" -gt "$FREEZE_GRACE" ]; then
                FROZEN_REASON="input unanswered for ${oldest_unanswered}s (no assistant output since)"
                log_monitor "TASK=frozen STATUS=check DETAILS=\"step4: oldest unanswered ${oldest_unanswered}s, last_assistant=${last_resp}\""
                return 0
            fi
        fi
    fi

    # 5. JSONL stale + no webhook backlog → check process state
    local claude_pid
    claude_pid=$(find_claude_pid)
    if [ -n "$claude_pid" ]; then
        local proc_state
        proc_state=$(ps -o stat= -p "$claude_pid" 2>/dev/null | head -c1)
        if [ "$proc_state" = "Z" ] || [ "$proc_state" = "T" ]; then
            FROZEN_REASON="JSONL stale + process state: ${proc_state} (zombie/stopped)"
            log_monitor "TASK=frozen STATUS=check DETAILS=\"step5: process state ${proc_state}\""
            return 0  # Zombie or stopped → frozen
        fi
    fi

    log_monitor "TASK=frozen STATUS=ok DETAILS=\"step5: process state ${proc_state:-unknown}, not frozen\""
    return 1  # Process alive, no definitive freeze signal
}

# Empty MCP config for the rate-limit corroboration probe (TASK 1). Keeps a
# `claude -p` probe from loading the project's webhook-channel (.mcp.json) —
# which would clash on :8788 with the live webhook — or any other server.
CLAUDE_PROBE_MCP="/tmp/claude-ratelimit-probe-mcp.json"
printf '{"mcpServers":{}}' > "$CLAUDE_PROBE_MCP" 2>/dev/null || true

# TASK 1 corroboration probe (issue #345). A direct `claude -p` round-trip used
# to decide whether a TASK 1 pane match is a real limit. The pane scrape matches
# arbitrary tool output and other services' "rate limit"/"try again in" text,
# whereas usage/rate/billing limits are enforced server-side per account/key —
# so a fresh probe is the ground truth.
#
# Echoes a THREE-WAY verdict (positive confirmation, not "any failure = limit"):
#   limited   — the probe returned a SPECIFIC rate/usage/credit limit → caller
#               sends the DEFINITIVE "you have hit your usage limits" notice once.
#   healthy   — the probe served a request cleanly → the pane match was a FALSE
#               POSITIVE → caller suppresses (no message).
#   ambiguous — anything else: `claude -p` errored/blocked/changed (Anthropic has
#               signalled it may restrict -p), auth failure, network, timeout, or
#               an unrecognized response. We CANNOT confirm a limit → caller
#               sends only a SOFT "may have hit your limits, can't confirm" notice
#               (once per episode), never the definitive one. This is the key
#               guard against acting on a broken probe.
#
# Signals (verified against official docs):
#   limited  := the `system/api_retry` event's `error` enum "rate_limit"/
#               "billing_error", or its `error_status` 429/402 — these are the
#               ONLY machine-readable limit signals `claude -p` documents, and
#               they are emitted only under `--output-format stream-json
#               --verbose` (code.claude.com/docs/en/headless), which is why the
#               probe uses that mode. Plain `--output-format json` exposes just a
#               generic is_error with no limit-specific field. As a fallback we
#               also match the verbatim terminal messages
#               (code.claude.com/docs/en/errors): "hit your session/weekly/Opus
#               limit", "Credit balance is too low", "Request rejected (429)",
#               "Usage credits required". Deliberately EXCLUDES overloaded/529 and
#               "temporarily limiting requests" — the docs state those are
#               transient and "not your usage limit", so we don't claim a
#               definitive limit (they fall to `ambiguous`).
#   healthy  := any ONE of (checked in this order; each also requires no
#               is_error:true anywhere in the stream):
#               (1) exit 0 + a final `{"type":"result",...}` event — the CLI's
#                   own clean-completion receipt (stream-json emits it on
#                   success; failures exit non-zero); or
#               (2) an `assistant` event whose text is exactly "OK" (trimmed,
#                   case-insensitive) — the model actually SERVED the probe
#                   prompt, which is ground truth regardless of how the CLI
#                   process shut down. Issue #471: the CLI answered "OK", then
#                   hung before emitting the result event, so `timeout` killed
#                   it (exit 124) and the exit-0+result-only rule misread a
#                   healthy account as `ambiguous` → false "may have hit your
#                   limits" alert. Only assistant events count: the probe
#                   prompt itself contains "OK" and is echoed in the
#                   init/user events, so a whole-stream grep would always
#                   match; or
#               (3) a `rate_limit_event` whose rate_limit_info.status is
#                   "allowed" — the API's own statement that the usage window
#                   is open (also #471: that event postdates this classifier
#                   and was previously ignored). Checked AFTER the `limited`
#                   signals so a stream that somehow carries both can never
#                   suppress a real limit. overageStatus "rejected"/
#                   out_of_credits in the same event is deliberately ignored —
#                   it only means no overage credit is available, irrelevant
#                   while status is "allowed".
# Checked healthy-FIRST ((1)/(2) before `limited`) so a transient 429 that the
# probe retried and then SERVED is treated as healthy, not as a (stale) limit
# token.
#
# Auth: sourced with `set -a` in this subshell so the probe child inherits the
# SAME credentials the live Claude uses — the OAuth subscription token, or the
# API key + ANTHROPIC_BASE_URL when on the proxy. .env holds bare (un-exported)
# assignments and monitor's top-level `source` doesn't re-export, so without
# this the probe could run UNAUTHENTICATED (e.g. under systemd/VM) and every
# pane match would look like a limit. stderr is merged (2>&1) so terminal-style
# limit messages reach the classifier.
#
# Flags: --output-format stream-json --verbose (so the api_retry error/
#   error_status fields above are actually emitted — plain json omits them),
#   NO --channels (telegram plugin not loaded → no 409), empty --strict-mcp-config
#   (no webhook :8788 clash), and --tools "" (issue #478). NOT --bare: bare skips
#   OAuth/keychain reads, which would break subscription-token auth.
#
#   Tool safety (issue #478): this is a classify/probe call that needs zero
#   tools. --tools "" empties the AVAILABLE-tool set (verified: system/init
#   reports tools=[]), so there is nothing for the model to call — every
#   built-in, present or future, not an enumerated subset (an earlier
#   --disallowedTools list missed the Cron*/Task*/Workflow family). And NO
#   --dangerously-skip-permissions: bypass AUTO-APPROVES every tool, the exact
#   footgun that let a probe run a shell command. -p mode never shows an
#   interactive prompt (code.claude.com/docs/en/headless), so dropping it costs
#   nothing and leaves the -p default deny-everything as a backstop. A text-only
#   reply still exits 0, so the healthy(1) check below is unaffected.
# Parse the probe's stream-json output (on stdin) for the healthy signals (2)
# and (3) above, which greps can't extract reliably: the assistant reply text
# lives inside a nested content array (and the prompt echo elsewhere in the
# stream also contains "OK"), and rate_limit_info's key order is not fixed.
# Prints a space-separated subset of: assistant_ok rl_allowed is_error.
# Non-JSON lines (merged stderr, terminal noise) are skipped; any parse
# failure prints nothing, which downgrades the verdict toward `ambiguous` —
# never toward a false `healthy`/`limited`.
probe_stream_signals() {
    # -c (not a heredoc script on stdin): stdin must stay the piped probe
    # output for sys.stdin to read it.
    python3 -c '
import json, sys
flags = set()
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    # Per-line try/except: a malformed line, or an unexpected shape (e.g.
    # message/rate_limit_info arriving as a string rather than a dict), must
    # skip only THAT line — never abort the whole parse. A crash here would
    # print nothing and silently downgrade the verdict to `ambiguous`, i.e.
    # the exact false-alert failure this PR removes. isinstance guards before
    # every nested access make that unreachable.
    try:
        d = json.loads(line)
        if not isinstance(d, dict):
            continue
        t = d.get("type")
        if t == "assistant":
            msg = d.get("message")
            content = msg.get("content") if isinstance(msg, dict) else None
            if isinstance(content, list):
                text = "".join(b.get("text", "") for b in content
                               if isinstance(b, dict) and b.get("type") == "text"
                               and isinstance(b.get("text"), str))
                if text.strip().upper() == "OK":
                    flags.add("assistant_ok")
        elif t == "rate_limit_event":
            rli = d.get("rate_limit_info")
            if isinstance(rli, dict) and rli.get("status") == "allowed":
                flags.add("rl_allowed")
        if d.get("is_error") is True:
            flags.add("is_error")
    except Exception:
        continue
print(" ".join(sorted(flags)))
' 2>/dev/null || true
}

claude_probe_classify() {
    [ -n "$CLAUDE_BIN" ] || { echo ambiguous; return; }
    local out ec
    out=$( { load_env_file "$CLAUDE_HOME/.env"; } 2>/dev/null \
             || { set -a; [ -f "$CLAUDE_HOME/.env" ] && . "$CLAUDE_HOME/.env" 2>/dev/null; set +a; }
           timeout 30 $CLAUDE_BIN -p "Reply with the single word: OK" \
               --output-format stream-json --verbose \
               --strict-mcp-config --mcp-config "$CLAUDE_PROBE_MCP" \
               --tools "" 2>&1 )
    ec=$?

    # healthy (1) first: a clean success (even after a transient retry) means served.
    if [ "$ec" -eq 0 ] \
       && printf '%s' "$out" | grep -q '"result"' \
       && ! printf '%s' "$out" | grep -qE '"is_error"[[:space:]]*:[[:space:]]*true'; then
        echo healthy; return
    fi

    local sig
    sig=$(printf '%s' "$out" | probe_stream_signals)

    # healthy (2): the model served the exact probe reply — ground truth even
    # when the CLI hung afterwards and timeout killed it (issue #471, exit 124).
    if [[ " $sig " == *" assistant_ok "* && " $sig " != *" is_error "* ]]; then
        echo healthy; return
    fi

    # limited: a SPECIFIC, documented rate/usage/credit signal.
    if printf '%s' "$out" | grep -qE '"error"[[:space:]]*:[[:space:]]*"(rate_limit|billing_error)"' \
       || printf '%s' "$out" | grep -qE '"error_status"[[:space:]]*:[[:space:]]*(429|402)' \
       || printf '%s' "$out" | grep -qiE "hit your (session|weekly|opus) limit|credit balance is too low|request rejected \(429\)|usage credits required"; then
        echo limited; return
    fi

    # healthy (3): the API itself reported the usage window open. Only reached
    # with no explicit limit signal present (checked above), so it can never
    # mask a real limit.
    if [[ " $sig " == *" rl_allowed "* && " $sig " != *" is_error "* ]]; then
        echo healthy; return
    fi

    echo ambiguous
}

# Debug log written by the running claudebot process (run.sh launches Claude
# with --debug-file pointing here). Default MUST match run.sh's MCP_DEBUG_LOG.
# monitor sources .env each loop but does NOT inherit run.sh's env, so derive
# the same path from CLAUDE_HOME here.
MCP_DEBUG_LOG="${MCP_DEBUG_LOG:-$CLAUDE_HOME/logs/claude-mcp-debug.log}"

# Helper (TASK 8): is the named MCP server's connection currently FAILED in the
# running session, according to Claude Code's own debug log? Returns 0 if so.
#
# WHAT THIS DETECTS (verified on a live install, see issue #348) — the lines
# Claude Code emits at [ERROR] level when a server's MCP link is broken:
#   [ERROR] MCP server "<name>" Connection failed: ...        (crash / handshake timeout)
#   [ERROR] MCP server "<name>" Failed to fetch tools: ...    (tools/list failed; this is
#                                                              the "1 setup issue: MCP" state)
# This is the signal bot.pid liveness (TASK 3) and the webhook /health probe
# (TASK 7) CANNOT see: a telegram poller / webhook HTTP server can be alive
# while Claude's MCP connection to it is dead.
#
# WHAT THIS DOES NOT DETECT (intentional — known limitation):
#   A purely SILENT mid-session disconnect of an IDLE server. Claude Code only
#   logs a drop when it next tries to USE the server, so an idle drop leaves no
#   line (verified: a probe killed mid-session produced no log entry). Covering
#   that needs the live-session self-report path (issue #348 "Option 2").
#
# FALSE-POSITIVE GUARD: Claude relays a server's stderr at [ERROR] level too,
#   e.g. [ERROR] MCP server "X" Server stderr: <anything>
# (the telegram plugin runs `bun install` and emits plenty of stderr). So we
# match ONLY the real failure verbs — never bare `[ERROR] MCP server "X"`.
#
# WHY "any error line present" == "currently failed" holds: these two channels
# are STDIO servers (telegram plugin + server:webhook-channel). Claude Code has
# NO auto-reconnect for stdio (its reconnect/backoff logic is SSE/HTTP-transport
# only), so a stdio server that fails its handshake or crashes stays failed for
# the rest of the session and never logs a later recovery. The only in-session
# recovery is a manual `/mcp reconnect` in the TUI — which doesn't happen on
# this headless, Telegram-driven deployment (nobody sits in the TUI). A tail
# window also naturally ages out a stale [ERROR] line after such a reconnect.
#
# Reads only the tail (last 4000 lines): run.sh truncates the log per launch, so
# all entries are from the current session, and the tail bound keeps this cheap
# even on a long-running session. Trade-off: an MCP failure is logged at STARTUP
# (near the TOP of the file); if the session later emits more than the tail
# window of debug output, that startup error can scroll out and TASK 8 stops
# seeing it. The window is sized generously so this only bites after very heavy
# logging; if missed detections ever show up, raise the tail count.
#
# $server is interpolated into the grep ERE verbatim, so a caller may pass a
# regex fragment (e.g. "(server:)?webhook-channel" to tolerate the config-tag
# prefix) — keep any literal name free of unescaped ERE metacharacters.
mcp_server_failed() {
    local server="$1"
    [ -s "$MCP_DEBUG_LOG" ] || return 1
    tail -n 4000 "$MCP_DEBUG_LOG" 2>/dev/null \
        | grep -qE "\[ERROR\] MCP server \"${server}\" (Connection failed|Failed to fetch tools)"
}

echo "[$(date)] Starting Claude smart watchdog..."

# Startup grace period: wait for Claude to initialize before monitoring.
# In container mode, monitor starts simultaneously with Claude — need longer grace.
# In VM mode, systemd starts monitor after claudebot, but a short grace is still prudent.
if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
    echo "[$(date)] Container mode detected — waiting 120s for Claude to initialize..."
    sleep 120
else
    echo "[$(date)] VM mode — waiting 30s for Claude to initialize..."
    sleep 30
fi
echo "[$(date)] Grace period complete, starting monitoring loop."

# Resolve claude binary (before main loop)
CLAUDE_BIN="claude"
if ! command -v claude >/dev/null 2>&1; then
    if [[ -f "$HOME/.bun/bin/claude" ]]; then
        CLAUDE_BIN="$HOME/.bun/bin/claude"
    elif command -v bunx >/dev/null 2>&1; then
        CLAUDE_BIN="bunx claude"
        # Diagnostic (issue #68): the bunx fallback re-downloads Claude Code
        # into /tmp on every `$CLAUDE_BIN` invocation, which can fill the
        # 512MB /tmp tmpfs and crash Chrome / break the shell. Flag it and
        # log once here; the invocation sites below log each call. This is a
        # free-form log_monitor line -- the tray parser only matches
        # "TASK=.. STATUS=.." lines and ignores everything else, so it never
        # affects tray status. The real fix is to keep claude on PATH (#302).
        CLAUDE_USING_BUNX=1
        log_monitor "WARN bunx-fallback: 'claude' not on PATH; using 'bunx claude' -- re-downloads Claude Code into /tmp on each call and can fill /tmp (issue #68)"
    elif command -v npx >/dev/null 2>&1; then
        CLAUDE_BIN="npx @anthropic-ai/claude-code"
    else
        CLAUDE_BIN=""
    fi
fi

# Dialog-signature drift canary (issue #448): dialog_pane_match's anchors and
# select-widget signature were verified against one specific Claude Code
# version; a CLI update that reworks the TUI rendering makes the detector
# silently never match — indistinguishable from healthy in the logs. Log a
# one-time startup warning when versions differ so drift is observable.
# Free-form line — the tray's TASK=/STATUS= parser ignores it.
if [ -n "$CLAUDE_BIN" ] && [ -n "${DIALOG_VERIFIED_CLI_VERSION:-}" ]; then
    _dd_cli_ver=$(timeout 30 $CLAUDE_BIN --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$_dd_cli_ver" ] && [ "$_dd_cli_ver" != "$DIALOG_VERIFIED_CLI_VERSION" ]; then
        log_monitor "WARN dialog-detect: Claude Code $_dd_cli_ver != anchor-verified $DIALOG_VERIFIED_CLI_VERSION — dialog signatures in core/dialog-detect.sh may be stale; re-verify against the new TUI"
    fi
fi

# Iteration counter — used to gate expensive checks (auth status, Telegram
# getMe) so they run every ~5 min while the loop itself runs every 1 min.
# This keeps liveness checks responsive without spamming the Anthropic auth
# endpoint or the Telegram API. Initialise such that the first iteration's
# (iter == 1) triggers gated checks immediately at startup.
iter=0

# Telegram token validity, initialised OUTSIDE the loop so it persists across
# iterations. With Task 6 (the actual probe) gated to ~5 min, we rely on the
# last known value for the 4 intervening iterations. Otherwise a known-bad
# token would be treated as valid 4 minutes out of every 5, causing Task 3
# to attempt pointless plugin/Claude restarts.
tg_token_valid=true

# TASK 9 dialog-signature persistence state: consecutive iterations the pane
# showed the SAME dialog content. Outside the loop so it accumulates.
dialog_streak=0
dialog_prev_pane=""

# Reset all cross-iteration dialog state (issue #448). MUST be called whenever
# this monitor restarts claudebot: the stuck sentinel's 900s TTL outlives the
# ~600s TASK 2 escalation, so a leftover sentinel would re-flag the freshly
# restarted session as frozen; a leftover fp pane / escape stamp similarly
# belongs to the dead session's screen.
_reset_dialog_state() {
    declare -F dialog_clear_stuck_sentinel >/dev/null 2>&1 || return 0
    dialog_clear_stuck_sentinel
    dialog_fp_clear
    rm -f "$DIALOG_ESCAPE_STAMP" "$DIALOG_PROBE_STAMP" 2>/dev/null || true
    dialog_streak=0
    dialog_prev_pane=""
}

while true; do
    iter=$((iter + 1))
    # Gated checks fire on the first iteration (catches startup issues)
    # and then every 5th iteration (~5 min at sleep 60).
    do_expensive=false
    if (( iter == 1 || iter % 5 == 0 )); then
        do_expensive=true
    fi

    # Claude auth status (Task 5) is gated SEPARATELY and far more coarsely
    # than do_expensive. setup-token OAuth tokens are valid ~1 year, so the
    # only thing this poll needs to catch promptly is a *revoked* token; an
    # hourly check bounds that staleness to ~1h while cutting the Anthropic
    # auth-endpoint footprint from ~288 to ~24 calls/day/user. Fires on the
    # first iteration (startup) and then every 60th (~60 min at sleep 60).
    do_auth_check=false
    if (( iter == 1 || iter % 60 == 0 )); then
        do_auth_check=true
    fi

    # Re-source .env each iteration to pick up rotated tokens (tolerant loader)
    if declare -F load_env >/dev/null 2>&1; then
        load_env
    else
        [[ -f "$CLAUDE_HOME/.env" ]] && source "$CLAUDE_HOME/.env" || true
    fi

    # Log rotation: keep last 500 lines if file exceeds 1MB
    if [ -f "$MONITOR_LOG" ] && [ "$(stat -c%s "$MONITOR_LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        (
            flock -n 200 || exit 0
            tail -500 "$MONITOR_LOG" > "${MONITOR_LOG}.tmp" && mv "${MONITOR_LOG}.tmp" "$MONITOR_LOG"
        ) 200>"${MONITOR_LOG}.lock"
    fi

    # --- TASK 1: RATE LIMIT CHECK ---
    # Container mode: parse log file instead of journalctl
    # VM mode: use journalctl as before
    _rl_log_missing=false
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        # CLAUDEBOT_LOG is inherited from entrypoint.sh, which exports it
        # BEFORE spawning this monitor precisely so this read and the tmux
        # pipe-pane write resolve to the same file. The /tmp default is a
        # last-resort fallback only (kept in sync with the restart paths
        # below, which re-create the pipe-pane with the same expression).
        _log_file="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
        # -r as well as -f: an existing-but-unreadable file would pass -f,
        # make the tail below fail silently (stderr dropped), and land in the
        # healthy branch with an empty window — the same silent blindness the
        # skip branch exists to prevent (review catch on PR #460).
        if [[ -f "$_log_file" && -r "$_log_file" ]]; then
            # claudebot.log is the raw tmux pane (pipe-pane) — lines are NOT
            # timestamp-prefixed, so a date window is impossible here: the old
            # `awk '$0 >= cutoff'` was a meaningless lexical compare against an
            # un-timestamped line. It never bounded by time AND silently DROPPED
            # every line sorting below the cutoff string — including the
            # heavily-indented (leading-whitespace) lines the Claude TUI emits,
            # which is exactly where a rendered limit message lands. So we don't
            # time-filter at all here: the window is simply the last 500 pane
            # lines. Duplicate alerts are prevented downstream by the
            # probe-verdict cache and the per-episode notification sentinels.
            # (VM mode below uses `journalctl --since`, which IS time-filtered.)
            #
            # Strip ANSI escapes + carriage returns from the raw pane before
            # matching: otherwise control bytes can (a) split a line mid-PATTERN
            # and defeat the grep, and (b) end up in LIMIT_LINE → the Telegram
            # alert. Same sequence as the reauth flow's _monitor_strip_ansi.
            OUTPUT=$(tail -n 500 "$_log_file" 2>/dev/null \
                     | sed 's/\x1b\[[0-9;]*[mGKHFABCDJh]//g; s/\x1b\[[?][0-9]*[hl]//g; s/\r//g' || true)
            # Log readable: close any missing-log episode so a future outage
            # counts and notifies afresh.
            rm -f /tmp/ratelimit_log_missing_count
        else
            # Pane log MISSING (or unreadable) means the pipe-pane plumbing
            # is broken. The
            # capture-pane merge below still checks the LIVE screen, so
            # detection is degraded (no scrollback window), not blind — but
            # it must still be surfaced, not reported as ok (see the skip
            # branch below). Before this distinction existed, a missing file
            # produced OUTPUT="" → STATUS=ok every cycle, which is exactly
            # how a real session limit went unreported: the pipe-pane wrote
            # /var/log/claudebot.log while this read /tmp/claudebot.log.
            OUTPUT=""
            _rl_log_missing=true
        fi
        # Merge in the LIVE pane as a second source. The pipe-pane file is
        # only trustworthy while every writer agrees on its path: a diverged
        # re-pipe (e.g. a podman-exec'd restart flow resolving CLAUDEBOT_LOG
        # differently) or a dead pipe-pane leaves a PRESENT-but-STALE file
        # that the missing-file branch above cannot see. capture-pane reads
        # what tmux itself renders, so a limit banner sitting on screen —
        # exactly how the missed session-limit incident presented — is caught
        # even when the log file is stale, missing, or piped elsewhere.
        # -p without -e emits plain text (no ANSI to strip); a failed capture
        # (session not up yet) merges nothing. Every match is still
        # corroborated by the claude -p probe before anything is sent.
        _rl_pane=$(tmux -L claudebot capture-pane -p -t claudebot 2>/dev/null || true)
        [ -n "$_rl_pane" ] && OUTPUT="${OUTPUT}"$'\n'"${_rl_pane}"
    else
        OUTPUT=$(journalctl -u claudebot --since "2 min ago" --no-pager 2>/dev/null)
    fi
    LIMIT_LINE=$(echo "$OUTPUT" | grep -iE "$PATTERN" | tail -n 1 | sed "s/['\"]//g")

    # Branch order matters: a PATTERN match always wins (the capture-pane
    # merge can surface a banner even while the log file is missing — the
    # probe path must handle it, not the degraded-plumbing path).
    if $_rl_log_missing && [ -z "$LIMIT_LINE" ]; then
        # No limit seen anywhere and the pane log is missing: report degraded,
        # not ok — and do NOT clear the ratelimit sentinels (a notified episode
        # must not be forgotten just because the log vanished). STATUS=skip
        # surfaces it in the tray's session view; the tray alone is easy to
        # miss, so on exactly the 3rd consecutive missing cycle (~3 min —
        # enough to ride out a restart's re-pipe race) also tell the user via
        # Telegram once. The counter resets when the file reappears, so a
        # fresh outage notifies again. Unlike the webhook/browser fail
        # counters (which clear when their restart action fires), this one is
        # deliberately NOT cleared on notify — the alert doesn't fix the
        # plumbing, so clearing would just re-arm a duplicate.
        log_monitor "TASK=ratelimit STATUS=skip DETAILS=\"pane log missing or unreadable ($_log_file) — detection degraded to live-screen only\""
        rlm=$(cat /tmp/ratelimit_log_missing_count 2>/dev/null); [[ "$rlm" =~ ^[0-9]+$ ]] || rlm=0
        rlm=$((rlm + 1))
        echo "$rlm" > /tmp/ratelimit_log_missing_count
        if [ "$rlm" -eq 3 ]; then
            send_tg "⚠️ System message - the usage-limit watchdog can't read the Claude session log and is falling back to checking the live screen only. Usage-limit detection is degraded. To fix this, $(_restart_hint)."
        fi
    elif [ -z "$LIMIT_LINE" ]; then
        # No usage-limit indication in the recent log window. Clear all
        # rate-limit state: probe cache + cooldown and the one-shot notification
        # sentinels — so a future issue is probed fresh and notified again.
        rm -f /tmp/ratelimit_probe_verdict /tmp/ratelimit_probe_last \
              /tmp/ratelimit_ambiguous_notified /tmp/ratelimit_limited_notified
        log_monitor "TASK=ratelimit STATUS=ok"
    else
        # A limit-ish string is present. Corroborate with a direct `claude -p`
        # probe (issue #345): the pane scrape matches tool output / other
        # services' text, so only the probe's verdict decides what we tell the
        # user. Probe at most once per LIMIT_PROBE_COOLDOWN, caching the verdict,
        # so a lingering string can't spawn a probe (a real model call) per cycle.
        #
        # NOTE: this NO LONGER offers the old Telegram "reply y to switch to
        # OpenRouter" flow — the monitor only NOTIFIES; it never switches the
        # user's billing mode on its own.
        #
        # The remediation named in the notice depends on the deployment, and is
        # resolved by _fallback_hint()/_restart_hint() above rather than
        # hardcoded: packaged builds surface it in their own UI, while a
        # self-hosted install is pointed at core/toggle-proxy.sh, which is what
        # actually exists in this repository. Do not reintroduce an
        # unconditional pointer to a UI this repo does not ship.
        LIMIT_PROBE_COOLDOWN=300
        rl_plast=$(cat /tmp/ratelimit_probe_last 2>/dev/null); [[ "$rl_plast" =~ ^[0-9]+$ ]] || rl_plast=0
        rl_pnow=$(date +%s)
        if [ $((rl_pnow - rl_plast)) -lt "$LIMIT_PROBE_COOLDOWN" ] && [ -s /tmp/ratelimit_probe_verdict ]; then
            rl_verdict=$(cat /tmp/ratelimit_probe_verdict 2>/dev/null)
        else
            echo "$rl_pnow" > /tmp/ratelimit_probe_last
            rl_verdict=$(claude_probe_classify)
            printf '%s' "$rl_verdict" > /tmp/ratelimit_probe_verdict
        fi

        case "$rl_verdict" in
        healthy)
            # Account served a request → the pane match was a false positive.
            # Reset notification sentinels so a later real issue notifies fresh.
            rm -f /tmp/ratelimit_ambiguous_notified /tmp/ratelimit_limited_notified
            log_monitor "TASK=ratelimit STATUS=false_positive DETAILS=\"pane matched '$LIMIT_LINE' but claude -p probe served OK — suppressing\""
            ;;
        limited)
            # Probe definitively confirmed a rate/usage/credit limit. Notify ONCE
            # per episode — identical control flow to the soft (ambiguous) notice;
            # only the message differs. Not a permanent latch: the sentinel is
            # cleared on recovery — a healthy verdict, or the limit string
            # scrolling out of the recent log window (the `tail -n 500` pane
            # window in container mode, or journalctl's 2-min window in VM mode) —
            # so a fresh episode notifies again. A continuously-present limit
            # string is either a genuine ongoing limit (correct to stay quiet) or
            # a false-positive string the probe clears via `healthy`.
            if [ ! -f /tmp/ratelimit_limited_notified ]; then
                send_tg "You have hit your Claude usage limits. Visit claude.ai to check your usage. Claude won't respond until your usage is reset.$(_fallback_hint)"
                touch /tmp/ratelimit_limited_notified
                log_monitor "TASK=ratelimit STATUS=detected DETAILS=\"$LIMIT_LINE (confirmed by probe) — user notified\""
            else
                log_monitor "TASK=ratelimit STATUS=detected DETAILS=\"$LIMIT_LINE (confirmed) — already notified this episode\""
            fi
            ;;
        *)
            # ambiguous: claude -p errored/blocked/timed out or returned an
            # unrecognized response — we CANNOT confirm a limit. Fire the SOFT
            # notice immediately, ONCE per episode — identical control flow to the
            # hard path above; only the message differs. Skipped if the hard
            # notice already fired this episode, so a definitive "you have hit
            # your limit" is never followed by a contradictory "can't confirm".
            if [ ! -f /tmp/ratelimit_limited_notified ] && [ ! -f /tmp/ratelimit_ambiguous_notified ]; then
                send_tg "You may have hit your Claude usage limits but we can't confirm it. Visit claude.ai to check your usage. If you have hit your limits, Claude won't respond until your usage is reset. If you keep receiving this message in error, $(_restart_hint)."
                touch /tmp/ratelimit_ambiguous_notified
                log_monitor "TASK=ratelimit STATUS=unconfirmed DETAILS=\"$LIMIT_LINE — probe could not confirm; soft warning sent\""
            else
                log_monitor "TASK=ratelimit STATUS=unconfirmed DETAILS=\"$LIMIT_LINE — probe could not confirm; already notified this episode\""
            fi
            ;;
        esac
    fi

    # --- TASK 9: INTERACTIVE DIALOG SCAN (issue #448) ---
    # A wedged TUI dialog (exit confirmation, AskUserQuestion, plan approval,
    # future dialog types) freezes the model while the process looks healthy.
    # is_frozen only reaches its pane check (step 3) once the transcript MTIME
    # is stale — but inbound triggers are written to the transcript on arrival,
    # so on a busy install the mtime stays "fresh" and a wedged dialog is
    # masked from step 2/3 indefinitely (limitation (b) in step 4's notes).
    # This scan closes that hole: it runs the free deterministic pane scan
    # EVERY iteration and keys quietness to last_assistant_epoch — which
    # inbound writes cannot bump — instead of the file mtime.
    #
    # Action gates (defence against the one harmful false positive, Escape
    # interrupting real work): the signature must persist 3 consecutive
    # iterations (~3 min; real modal dialogs sit unchanged for minutes, pane
    # text mid-scroll doesn't), the session must have produced no assistant
    # output for DIALOG_QUIET_SECS, and escapes are cooldown-limited. An
    # unresolvable transcript (last_assistant_epoch=0) counts as NOT quiet —
    # no evidence, no action. NO `claude -p` on this path (the user's call:
    # a rigorous pattern + these gates justify Escape on their own, and the
    # probe must never be load-bearing); the probe only tiebreaks the
    # escape-failed case, same as step 3. Issue #510 (the generic signature
    # matching normal screens on a newer CLI) was fixed by TIGHTENING the
    # pattern itself (dialog_generic_widget_match: adjacent, consecutively
    # numbered options), NOT by gating Escape on the probe — a stuck prompt
    # never cleared because the probe was unavailable would be worse than
    # the false positive.
    #
    # MUST run before TASK 2: a cleared dialog un-wedges the session before
    # is_frozen judges it, and a dialog-free pane clears the stuck sentinel
    # step 3a relies on (see dialog-detect.sh).
    if declare -F dialog_pane_match >/dev/null 2>&1; then
        d9_pane=$(dialog_capture_pane_tail)
        if [ -z "$d9_pane" ]; then
            # No data is NOT dialog-free evidence: a failed/empty tmux capture
            # must neither reset the streak nor clear the stuck sentinel
            # (absence of signal vs signal of absence).
            log_monitor "TASK=dialog STATUS=skip DETAILS=\"pane capture empty — no evidence, state untouched\""
        elif printf '%s\n' "$d9_pane" | dialog_pane_match; then
            if dialog_stuck_sentinel_fresh; then
                # Re-log stuck EVERY cycle while confirmed — the tray keeps
                # the LAST-seen status per task from a 50-line log tail (see
                # the TASK 5 "log STATUS=expired on EVERY cycle" note); a
                # one-shot stuck line would flip it back to ok within a
                # minute. No re-escape here: frozen escalation owns it now.
                log_monitor "TASK=dialog STATUS=stuck DETAILS=\"confirmed stuck dialog — frozen escalation in progress\""
            elif dialog_fp_match "$d9_pane"; then
                log_monitor "TASK=dialog STATUS=ok DETAILS=\"pane matches recorded false-positive text — suppressed\""
            else
                # Persistence is keyed to the pane CONTENT, not just "some
                # signature matched": different dialog-shaped content resets
                # the count, so a long-suppressed fp pane can't pre-charge the
                # streak for whatever matches next (and a mid-scroll transient
                # never accumulates).
                if [ "$d9_pane" = "$dialog_prev_pane" ]; then
                    dialog_streak=$((dialog_streak + 1))
                else
                    dialog_streak=1
                fi
                dialog_prev_pane="$d9_pane"
                if [ "$dialog_streak" -lt 3 ]; then
                    log_monitor "TASK=dialog STATUS=warn DETAILS=\"dialog signature present, streak ${dialog_streak}/3\""
                else
                    # Quiet gate — computed only past the free gates above
                    # (get_active_jsonl + last_assistant_epoch spawn python3).
                    # last_assistant_epoch=0 (unresolvable transcript) counts
                    # as NOT quiet: no evidence, no action. Known limitation:
                    # its mtime FALLBACK (no assistant entry in the 256KB tail
                    # window) is bumped by inbound writes, so an extreme
                    # trigger drip can still mask a wedge — accepted, the
                    # fallback errs toward not-quiet i.e. no Escape.
                    d9_quiet=0
                    d9_jsonl=$(get_active_jsonl || true)
                    d9_last=$(last_assistant_epoch "$d9_jsonl")
                    if [[ "$d9_last" =~ ^[0-9]+$ ]] && [ "$d9_last" -gt 0 ]; then
                        d9_quiet=$(( $(date +%s) - d9_last ))
                    fi
                    if [ "$d9_quiet" -lt "$DIALOG_QUIET_SECS" ]; then
                        log_monitor "TASK=dialog STATUS=warn DETAILS=\"dialog signature persists but assistant output ${d9_quiet}s ago (0 = transcript unresolvable) — not quiet, no action\""
                    else
                        d9_verdict=$(dialog_escape_and_tiebreak "$d9_pane" pattern)
                        case "$d9_verdict" in
                        cleared)
                            dialog_streak=0
                            dialog_prev_pane=""
                            log_monitor "TASK=dialog STATUS=recovered DETAILS=\"dialog cleared after Escape\""
                            # One line to the user, rate-limited, carrying the
                            # dialog's own header — Escape DECLINES question/
                            # plan dialogs, so the user must be able to tell
                            # what was dismissed. dialog_headline anchors on
                            # the widget rather than taking the pane tail's
                            # first line, which sits 25 lines up in scrollback
                            # and quoted unrelated transcript text (issue
                            # #510). Markdown-sensitive chars stripped
                            # (send_tg posts parse_mode=Markdown).
                            if dialog_cooldown_ok "$DIALOG_TG_STAMP" 3600; then
                                dialog_stamp "$DIALOG_TG_STAMP"
                                d9_head=$(printf '%s\n' "$d9_pane" | dialog_headline | tr -d '`*_[]' | cut -c1-120)
                                send_tg "✅ System message - Claude was stuck on an interactive terminal prompt and it was dismissed automatically. The prompt began: \"${d9_head}\". If it was a question Claude asked, message it again to continue."
                            fi
                            # Give the un-wedged session a beat to produce
                            # output before TASK 2 judges the backlog that
                            # piled up DURING the wedge — otherwise step 4
                            # fires a contradictory "appears frozen" seconds
                            # after the ✅ above. Same sleep+continue pattern
                            # as the other recovery paths in this loop.
                            sleep 30
                            continue
                            ;;
                        stuck)
                            log_monitor "TASK=dialog STATUS=stuck DETAILS=\"dialog survived Escape, probe confirmed stuck — frozen escalation will handle it\""
                            ;;
                        fp)
                            log_monitor "TASK=dialog STATUS=ok DETAILS=\"Escape no-op, probe said not-a-dialog — recorded as false-positive text\""
                            ;;
                        cooldown)
                            log_monitor "TASK=dialog STATUS=warn DETAILS=\"dialog signature persists, escape cooldown active\""
                            ;;
                        *)
                            # ambiguous: Escape failed and no probe evidence.
                            # Nothing recorded — the cooldowns retry it; a
                            # REAL Escape-immune dialog keeps being attacked
                            # instead of being whitelisted forever.
                            log_monitor "TASK=dialog STATUS=warn DETAILS=\"dialog survived Escape, no probe verdict — will retry after cooldowns\""
                            ;;
                        esac
                    fi
                fi
            fi
        else
            # Dialog-free pane: reset persistence and clear the stuck sentinel
            # (whatever was wedged is gone — step 3a must not keep reporting
            # frozen off a stale sentinel).
            dialog_streak=0
            dialog_prev_pane=""
            if [ -f "$DIALOG_STUCK_SENTINEL" ]; then
                dialog_clear_stuck_sentinel
                log_monitor "TASK=dialog STATUS=recovered DETAILS=\"pane dialog-free — stuck sentinel cleared\""
            else
                log_monitor "TASK=dialog STATUS=ok"
            fi
        fi
    fi

    # --- TASK 2: FROZEN PING CHECK (5 retries, 2min apart, before restart) ---
    if is_frozen; then
        frozen_confirmed=true
        for attempt in 1 2 3 4; do
            log_monitor "TASK=frozen STATUS=warn DETAILS=\"check $attempt/5: $FROZEN_REASON — retrying\""
            send_tg "⚠️ System message - Claude appears frozen (check $attempt/5): $FROZEN_REASON — retrying in 2min"
            sleep 120
            if ! is_frozen; then
                log_monitor "TASK=frozen STATUS=recovered DETAILS=\"check $attempt/5: Claude responding\""
                send_tg "✅ System message - Claude is now responding"
                frozen_confirmed=false
                break
            fi
        done
        if $frozen_confirmed; then
            send_tg "⚠️ System message - Claude still frozen (check 5/5): $FROZEN_REASON — retrying in 2min"
            sleep 120
            if is_frozen; then
                log_monitor "TASK=frozen STATUS=restart DETAILS=\"restarting Claude. Reason: $FROZEN_REASON\""
                send_tg "🚨 System message - restarting Claude. Reason: $FROZEN_REASON"
                stamp_planned_restart   # our own restart — don't re-flag it (#513)
                respawn_browser
                # Container mode: kill tmux session + restart run.sh directly
                # VM mode: use systemctl
                if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
                    # Restart claudebot tmux session
                    tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
                    sleep 2
                    export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
                    tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
                    tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"
                else
                    sudo systemctl restart claudebot.service
                fi
                _reset_dialog_state
                sleep 15
                continue
            else
                send_tg "✅ System message - Claude is now responding"
            fi
        fi
    else
        log_monitor "TASK=frozen STATUS=ok"
    fi

    # --- TASK 6: TELEGRAM BOT TOKEN VALIDITY (gated to ~5 min) ---
    # Gated because there's no urgency to detecting a token rotation within 60s;
    # tg_token_valid persists across iterations (initialised once before the
    # loop), so Task 3 keeps honouring the last known verdict on iterations
    # where this check doesn't run.
    if $do_expensive && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
        # No `-f` on this curl: a bad token makes getMe answer HTTP 401/404
        # with an {"ok":false,"error_code":...} JSON body, and -f would discard
        # that body and exit 22 — indistinguishable from a network outage,
        # leaving the invalid branch below unreachable. The body decides
        # validity; a transport failure just yields an empty response, which
        # the parser maps to the transient branch.
        tg_response=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null) || true

        # valid     := ok:true
        # invalid   := ok:false with an auth-shaped error_code (401 revoked,
        #              404 malformed, 403 banned/deactivated bot)
        # transient := transport error, unparseable body, or any other
        #              ok:false (e.g. a 429 flood-wait) — counted, never flips
        #              the token verdict.
        tg_verdict=$(echo "$tg_response" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
if not isinstance(d, dict):
    sys.exit()
if d.get("ok") is True:
    print("valid")
elif d.get("ok") is False and d.get("error_code") in (401, 403, 404):
    print("invalid")
' 2>/dev/null)
        if [ "$tg_verdict" = "valid" ]; then
            rm -f /tmp/telegram_token_invalid /tmp/telegram_network_fail_count
            tg_token_valid=true
            log_monitor "TASK=tg_token STATUS=ok"
        elif [ "$tg_verdict" = "invalid" ]; then
            tg_token_valid=false
            # An invalid verdict proves the API was reachable — drop any
            # partial network-fail count so a later lone blip can't inherit
            # it and fire the "N consecutive checks" warning on first failure.
            rm -f /tmp/telegram_network_fail_count
            log_monitor "TASK=tg_token STATUS=invalid"
            if [ ! -f /tmp/telegram_token_invalid ]; then
                echo "[$(date)] WARNING: Telegram bot token is invalid (API returned ok=false)" >&2
                touch /tmp/telegram_token_invalid
            fi
        else
            # Transport error, unparseable body, or non-auth API error — could
            # be transient
            count=0
            [ -f /tmp/telegram_network_fail_count ] && count=$(cat /tmp/telegram_network_fail_count 2>/dev/null || echo 0)
            count=$((count + 1))
            echo "$count" > /tmp/telegram_network_fail_count
            log_monitor "TASK=tg_token STATUS=network_fail DETAILS=\"count=$count\""
            if [ "$count" -ge 3 ]; then
                echo "[$(date)] WARNING: Telegram API unreachable for $count consecutive checks" >&2
            fi
        fi
    fi

    # --- TASK 3: TELEGRAM PLUGIN HEALTH CHECK ---
    if $tg_token_valid; then
    TELEGRAM_PID_FILE="$HOME/.claude/channels/telegram/bot.pid"
    if [ -f "$TELEGRAM_PID_FILE" ]; then
        TGPID=$(cat "$TELEGRAM_PID_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ "$TGPID" =~ ^[0-9]+$ ]]; then
            # Verify PID is alive AND is the actual telegram bot (not a reused PID)
            tg_alive=false
            if kill -0 "$TGPID" 2>/dev/null; then
                if tr '\0' ' ' < "/proc/$TGPID/cmdline" 2>/dev/null | grep -q "server\.ts"; then
                    tg_alive=true
                    # A live poller is only healthy if it belongs to the CURRENT
                    # Claude. The plugin is spawned by Claude, so a healthy
                    # poller is always younger than the Claude process; one
                    # OLDER than Claude is a leftover from a previous instance,
                    # holding the exclusive getUpdates long-poll while the
                    # current session's plugin is dead or failed — and since
                    # bot.pid still names the live orphan, the aliveness check
                    # above would pass forever. Treat it as dead so the restart
                    # path below clears it (run.sh kills orphan pollers before
                    # relaunching).
                    TG_CLAUDE_PID=$(find_claude_pid)
                    if [ -n "$TG_CLAUDE_PID" ]; then
                        tg_et=$(ps -o etimes= -p "$TGPID" 2>/dev/null | tr -d ' ')
                        cl_et=$(ps -o etimes= -p "$TG_CLAUDE_PID" 2>/dev/null | tr -d ' ')
                        if [[ "$tg_et" =~ ^[0-9]+$ ]] && [[ "$cl_et" =~ ^[0-9]+$ ]] \
                           && [ "$tg_et" -gt "$cl_et" ]; then
                            log_monitor "TASK=tg_plugin STATUS=stale DETAILS=\"poller PID=$TGPID predates claude PID=$TG_CLAUDE_PID\""
                            tg_alive=false
                        fi
                    fi
                fi
            fi

            if ! $tg_alive; then
                # Plugin is dead — only act if Claude itself is still running
                log_monitor "TASK=tg_plugin STATUS=dead DETAILS=\"restarting Claude\""
                CLAUDE_PID=$(find_claude_pid)
                if [ -n "$CLAUDE_PID" ]; then
                    send_tg "⚠️ System message - Telegram plugin disconnected. Restarting Claude to reconnect..."
                    stamp_planned_restart   # our own restart — don't re-flag it (#513)
                    kill "$CLAUDE_PID" 2>/dev/null
                    _reset_dialog_state
                    # Verify recovery: poll for a fresh poller with a different PID
                    if tg_wait_recovered "$TGPID"; then
                        log_monitor "TASK=tg_plugin STATUS=recovered DETAILS=\"new PID=$TG_RECOVERED_PID\""
                        send_tg "✅ System message - Telegram plugin recovered"
                    else
                        log_monitor "TASK=tg_plugin STATUS=recovery_failed"
                        send_tg "🚨 System message - Telegram plugin recovery failed — may need manual intervention"
                    fi
                fi
            else
                log_monitor "TASK=tg_plugin STATUS=ok DETAILS=\"PID=$TGPID\""
            fi
        fi
    else
        # No PID file. Benign during maintenance flows that deliberately kill
        # the poller (claude-auth reauth, Google setup — both remove bot.pid
        # and rely on this branch standing down) and during Claude's first
        # minutes of boot. But a Claude that has been up well past boot with
        # no poller means the telegram plugin's MCP server failed at startup
        # (e.g. handshake timed out under the nightly Chrome boot storm) —
        # Claude Code never retries a failed MCP server, and the session looks
        # healthy from outside (webhook up, token valid, not frozen), so
        # nothing else recovers it. Restart Claude for a clean plugin start.
        TG_NOPID_GRACE=300       # allow slow boots before declaring failure
        TG_NOPID_COOLDOWN=1800   # don't bounce Claude forever if plugin is permanently broken
        TG_CLAUDE_PID=$(find_claude_pid)
        if [ -z "$TG_CLAUDE_PID" ] || [ -f /tmp/claude_auth_alert_sent ] \
           || [ -f /tmp/claude_reauth_in_progress ] || [ -f /tmp/google_setup.pid ]; then
            log_monitor "TASK=tg_plugin STATUS=skip DETAILS=\"no PID file (boot/maintenance)\""
        else
            cl_et=$(ps -o etimes= -p "$TG_CLAUDE_PID" 2>/dev/null | tr -d ' ')
            if ! [[ "$cl_et" =~ ^[0-9]+$ ]] || [ "$cl_et" -lt "$TG_NOPID_GRACE" ]; then
                log_monitor "TASK=tg_plugin STATUS=skip DETAILS=\"no PID file (claude up ${cl_et:-?}s)\""
            else
                nplast=$(cat /tmp/tg_plugin_last_restart 2>/dev/null)
                [[ "$nplast" =~ ^[0-9]+$ ]] || nplast=0
                npnow=$(date +%s)
                if [ $((npnow - nplast)) -lt "$TG_NOPID_COOLDOWN" ]; then
                    log_monitor "TASK=tg_plugin STATUS=down DETAILS=\"no PID file, claude up ${cl_et}s, within restart cooldown\""
                else
                    echo "$npnow" > /tmp/tg_plugin_last_restart
                    log_monitor "TASK=tg_plugin STATUS=restart DETAILS=\"claude up ${cl_et}s with no telegram poller\""
                    send_tg "⚠️ System message - Telegram plugin never started. Restarting Claude to reconnect..."
                    stamp_planned_restart   # our own restart — don't re-flag it (#513)
                    kill "$TG_CLAUDE_PID" 2>/dev/null
                    _reset_dialog_state
                    # Verify recovery: poll for a fresh poller (no previous PID)
                    if tg_wait_recovered ""; then
                        log_monitor "TASK=tg_plugin STATUS=recovered DETAILS=\"new PID=$TG_RECOVERED_PID\""
                        send_tg "✅ System message - Telegram plugin recovered"
                    else
                        log_monitor "TASK=tg_plugin STATUS=recovery_failed"
                        send_tg "🚨 System message - Telegram plugin recovery failed — may need manual intervention"
                    fi
                fi
            fi
        fi
    fi
    else
        log_monitor "TASK=tg_plugin STATUS=skip DETAILS=\"tg_token invalid\""
    fi # tg_token_valid

    # --- TASK 4: SUPERCRONIC HEALTH CHECK (container only) ---
    # Same container test as every other container-gated block in this file
    # (/.dockerenv OR CONTAINER=true). The provisioning guard matters with the
    # widened gate: in a docker container entrypoint.sh never set up (no
    # supercronic binary, no .crontab) the restart branch would otherwise
    # respawn a doomed supercronic and Telegram-ping the user every 60s
    # forever — this branch has no cooldown or notify-once sentinel.
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        if pgrep -x supercronic >/dev/null; then
            log_monitor "TASK=supercronic STATUS=ok"
        elif ! command -v supercronic >/dev/null 2>&1 || [[ ! -f "$CLAUDE_HOME/.crontab" ]]; then
            log_monitor "TASK=supercronic STATUS=skip DETAILS=\"not provisioned here (supercronic binary or .crontab missing)\""
        else
            echo "[monitor] supercronic died — restarting"
            supercronic -inotify "$CLAUDE_HOME/.crontab" &
            send_tg "⚠️ supercronic crashed and was auto-restarted"
            log_monitor "TASK=supercronic STATUS=restarted"
        fi
    fi

    # --- TASK 7: WEBHOOK CHANNEL HEALTH ---
    # The webhook channel (127.0.0.1:8788) is spawned by Claude Code as an
    # MCP dev channel (see run.sh's --dangerously-load-development-channels),
    # in BOTH container and VM mode. If it dies — e.g. EADDRINUSE when a
    # Claude restart races the previous instance's port release — while
    # Claude itself stays alive, nothing else brings it back: inject.sh loses
    # its primary delivery path (falling back to flaky tmux send-keys) and
    # the tray shows "webhook down". The only way to respawn an MCP-owned
    # server is to restart the claudebot session, so do that after a
    # sustained outage.
    #
    # Gates: only when Claude is alive (a dead Claude is the frozen task's
    # job), require WEBHOOK_DOWN_THRESHOLD consecutive failures so a normal
    # restart blip doesn't trigger us, and honour a cooldown so a
    # permanently-broken webhook (e.g. missing node_modules) can't bounce
    # Claude every few minutes forever.
    WEBHOOK_DOWN_THRESHOLD=3
    WEBHOOK_RESTART_COOLDOWN=1800  # 30 min
    if curl -sf --max-time 5 http://127.0.0.1:8788/health >/dev/null 2>&1; then
        rm -f /tmp/webhook_down_count
        log_monitor "TASK=webhook STATUS=ok"
    elif [ -z "$(find_claude_pid)" ]; then
        log_monitor "TASK=webhook STATUS=skip DETAILS=\"claude not running\""
    else
        wcount=0
        [ -f /tmp/webhook_down_count ] && wcount=$(cat /tmp/webhook_down_count 2>/dev/null || echo 0)
        wcount=$((wcount + 1))
        echo "$wcount" > /tmp/webhook_down_count
        if [ "$wcount" -lt "$WEBHOOK_DOWN_THRESHOLD" ]; then
            log_monitor "TASK=webhook STATUS=down DETAILS=\"count=$wcount/$WEBHOOK_DOWN_THRESHOLD\""
        else
            wlast=0
            [ -f /tmp/webhook_last_restart ] && wlast=$(cat /tmp/webhook_last_restart 2>/dev/null || echo 0)
            wnow=$(date +%s)
            if [ $((wnow - wlast)) -lt "$WEBHOOK_RESTART_COOLDOWN" ]; then
                log_monitor "TASK=webhook STATUS=down DETAILS=\"count=$wcount, within restart cooldown — not restarting\""
            else
                log_monitor "TASK=webhook STATUS=restart DETAILS=\"down for $wcount checks; restarting claudebot\""
                send_tg "⚠️ System message - webhook channel down for ${wcount} checks. Restarting Claude to restore scheduled-task delivery..."
                echo "$wnow" > /tmp/webhook_last_restart
                rm -f /tmp/webhook_down_count
                stamp_planned_restart   # our own restart — don't re-flag it (#513)
                # Respawn the MCP-owned webhook channel by restarting claudebot.
                # Same container/VM split as the frozen-restart path (TASK 2).
                if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
                    tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
                    sleep 2
                    export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
                    tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
                    tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"
                else
                    sudo systemctl restart claudebot.service
                fi
                _reset_dialog_state
                sleep 15
                continue
            fi
        fi
    fi

    # --- TASK 8: MCP CHANNEL CONNECTION HEALTH (debug-log based) --- (issue #348)
    # ADDITIVE to TASK 3 (telegram bot.pid) and TASK 7 (webhook /health): both
    # of those remain authoritative for their own signals. This only ADDS a
    # "dead" verdict + restart for the blind spot they share — a channel whose
    # MCP *connection* failed while its process/HTTP endpoint is still alive
    # (telegram: poller alive, MCP link dead; webhook: server.js starts its
    # HTTP listener regardless of the MCP handshake, so /health stays green).
    #
    # CATCHES (logged at [ERROR] by Claude Code — see mcp_server_failed):
    #   - startup handshake miss / timeout       (Connection failed: ... timed out)
    #   - connection closed / crash at startup    (Connection failed: ... -32000)
    #   - tools/list failure ("1 setup issue: MCP" state)  (Failed to fetch tools)
    # DOES NOT CATCH: a silent idle mid-session disconnect (Claude logs nothing
    #   until it next uses the server) — that needs the Option 2 self-report.
    #   Also unhandled: a manual /mcp reconnect mid-session (rare here, as no
    #   user sits in the TUI) would leave the stale error line matched until the
    #   next launch truncates the log.
    #
    # A failure of EITHER channel is remedied identically (restart claudebot
    # respawns all MCP channels), so one confirmed failure triggers one restart.
    # No double-restart with the other tasks:
    #   - runs AFTER TASK 7, whose restart path `continue`s (so we're skipped if
    #     it fired);
    #   - the "claude up > grace" gate means it can't fire right after ANY
    #     restart (fresh Claude is under grace; run.sh truncates the log too),
    #     which also covers TASK 3's bot.pid-dead branch (that one doesn't
    #     `continue`, but its relaunch leaves Claude under grace here);
    #   - 2-cycle confirmation + a shared cooldown prevent thrashing.
    MCP_FAIL_GRACE=300         # don't act until Claude has been up this long (boot settle)
    MCP_FAIL_CONFIRM=2         # consecutive detections required before a restart
    MCP_FAIL_COOLDOWN=1800     # min seconds between TASK-8 restarts (permanent-breakage guard)
    if [ -s "$MCP_DEBUG_LOG" ]; then
        mcp_restart_needed=false
        mcp_fail_reasons=""

        # Telegram. Skipped when the token is invalid — that's TASK 6's domain
        # and a restart won't fix a bad token (reuses tg_token_valid).
        if $tg_token_valid && mcp_server_failed "plugin:telegram:telegram"; then
            tgc=$(cat /tmp/mcp_fail_telegram_count 2>/dev/null); [[ "$tgc" =~ ^[0-9]+$ ]] || tgc=0
            tgc=$((tgc + 1)); [ "$tgc" -gt "$MCP_FAIL_CONFIRM" ] && tgc=$MCP_FAIL_CONFIRM
            echo "$tgc" > /tmp/mcp_fail_telegram_count
            # Reuse the existing tg_plugin/dead signal so the tray reddens with
            # NO tray change (StatusPoller treats tg_plugin=dead as Degraded).
            # Written after TASK 3's line this cycle, so "last wins" → dead.
            log_monitor "TASK=tg_plugin STATUS=dead DETAILS=\"MCP connection failed in session (debug log), confirm ${tgc}/${MCP_FAIL_CONFIRM}\""
            [ "$tgc" -ge "$MCP_FAIL_CONFIRM" ] && { mcp_restart_needed=true; mcp_fail_reasons="${mcp_fail_reasons} telegram"; }
        else
            rm -f /tmp/mcp_fail_telegram_count
        fi

        # Webhook. TASK 7 only proves the HTTP listener is up, NOT that Claude's
        # MCP channel to it is alive — so this is genuine extra coverage.
        # Optional "server:" prefix: a pre-handshake "Connection failed" can be
        # logged under the config tag (server:webhook-channel — the name from
        # --dangerously-load-development-channels) before the server reports its
        # own name ("webhook-channel"), so accept either spelling.
        if mcp_server_failed "(server:)?webhook-channel"; then
            whc=$(cat /tmp/mcp_fail_webhook_count 2>/dev/null); [[ "$whc" =~ ^[0-9]+$ ]] || whc=0
            whc=$((whc + 1)); [ "$whc" -gt "$MCP_FAIL_CONFIRM" ] && whc=$MCP_FAIL_CONFIRM
            echo "$whc" > /tmp/mcp_fail_webhook_count
            log_monitor "TASK=mcp_webhook STATUS=dead DETAILS=\"MCP channel connection failed in session (debug log), confirm ${whc}/${MCP_FAIL_CONFIRM}\""
            [ "$whc" -ge "$MCP_FAIL_CONFIRM" ] && { mcp_restart_needed=true; mcp_fail_reasons="${mcp_fail_reasons} webhook"; }
        else
            rm -f /tmp/mcp_fail_webhook_count
        fi

        if $mcp_restart_needed; then
            MCP_CLAUDE_PID=$(find_claude_pid)
            # Only probe etimes when we actually have a PID — `ps` with an empty
            # -p argument is a needless error (the -z check below handles the
            # no-PID case). Mirrors TASK 3's `[ -n "$TG_CLAUDE_PID" ]` guard.
            mcp_cl_up=""
            [ -n "$MCP_CLAUDE_PID" ] && mcp_cl_up=$(ps -o etimes= -p "$MCP_CLAUDE_PID" 2>/dev/null | tr -d ' ')
            mcp_last=$(cat /tmp/mcp_fail_last_restart 2>/dev/null); [[ "$mcp_last" =~ ^[0-9]+$ ]] || mcp_last=0
            mcp_now=$(date +%s)
            if [ -z "$MCP_CLAUDE_PID" ]; then
                log_monitor "TASK=mcp_channels STATUS=skip DETAILS=\"failed:${mcp_fail_reasons}, but claude not running\""
            elif ! [[ "$mcp_cl_up" =~ ^[0-9]+$ ]] || [ "$mcp_cl_up" -lt "$MCP_FAIL_GRACE" ]; then
                log_monitor "TASK=mcp_channels STATUS=skip DETAILS=\"failed:${mcp_fail_reasons}, claude up ${mcp_cl_up:-?}s < grace, deferring\""
            elif [ $((mcp_now - mcp_last)) -lt "$MCP_FAIL_COOLDOWN" ]; then
                log_monitor "TASK=mcp_channels STATUS=down DETAILS=\"failed:${mcp_fail_reasons}, within restart cooldown — not restarting\""
            else
                echo "$mcp_now" > /tmp/mcp_fail_last_restart
                rm -f /tmp/mcp_fail_telegram_count /tmp/mcp_fail_webhook_count
                log_monitor "TASK=mcp_channels STATUS=restart DETAILS=\"MCP channel(s) failed:${mcp_fail_reasons}; restarting claudebot\""
                send_tg "⚠️ System message - MCP channel(s) failed (${mcp_fail_reasons# }) — Claude can't use them. Restarting Claude to reconnect..."
                stamp_planned_restart   # our own restart — don't re-flag it (#513)
                # Respawn the MCP-owned channels by restarting claudebot.
                # Same container/VM split as TASK 2 / TASK 7.
                if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
                    tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
                    sleep 2
                    export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
                    tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
                    tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"
                else
                    sudo systemctl restart claudebot.service
                fi
                _reset_dialog_state
                sleep 15
                continue
            fi
        fi
    else
        log_monitor "TASK=mcp_channels STATUS=skip DETAILS=\"no MCP debug log yet (run.sh writes it on next launch)\""
    fi

    # --- TASK 5: CLAUDE AUTH STATUS + AUTO RE-AUTH (gated to ~hourly) ---
    # Gated via do_auth_check (~60 min) — see the gate definition at the top of
    # the loop for the rationale. Avoids spamming the Anthropic auth endpoint and
    # limits Node CLI cold-start churn (each `claude auth status` spawns the full
    # CLI). Token expiry is annual, so hourly is ample to catch a revoked token.
    #
    # WHAT THIS DETECTS:
    #   token expired / revoked / missing / corrupted server-side → loggedIn:false
    #   → reauth flow fires.
    #
    # WHAT THIS DOES NOT DETECT (intentional, do NOT "fix" without reading below):
    #   Interactive `/logout` typed in the Claude TUI. /logout wipes stored
    #   credentials at ~/.claude/credentials.json but does NOT revoke the env-var
    #   token, and the CLI's auth resolution prefers env-var over stored creds.
    #   So `auth status` keeps returning loggedIn:true from the env-var token
    #   that monitor sources from .env every iteration. The user must manually
    #   wipe the env-var token from .env (and clear sentinels) to trigger reauth.
    #
    # !!! HISTORICAL DEAD-END — DO NOT REINTRODUCE !!!
    # PR #276 tried to detect /logout by stripping the env var with
    #     env -u CLAUDE_CODE_OAUTH_TOKEN $CLAUDE_BIN auth status
    # Idea: if the env var is gone, `auth status` falls back to stored creds,
    # which /logout wipes → loggedIn:false → reauth fires. This APPEARED to
    # work in isolated testing because that test env happened to have stored
    # credentials at ~/.claude/credentials.json (from a prior interactive
    # login). But in this codebase's normal deployment (especially containers),
    # stored credentials usually do NOT exist — the .env env-var token is the
    # only credential source. With `env -u` stripping the only credential,
    # `auth status` always returns loggedIn:false, and reauth fires within
    # seconds of every monitor restart, locking the loop in a 10-min Telegram
    # poll for an OAuth code that the user does not actually need to provide.
    # Reverted in PR #278. If you ever want to detect /logout, do NOT use
    # env -u; instead use a different signal (e.g. mtime watch on
    # ~/.claude/credentials.json, or a /logout Stop hook setting a sentinel
    # under /tmp that this check can read).
    # (A frozen restart never reaches here in the same cycle — TASK 2's
    # restart path `continue`s straight to the next iteration.)
    if $do_auth_check && [ -n "$CLAUDE_BIN" ]; then
        # Diagnostic (issue #68): when on the bunx fallback this auth-status
        # check re-downloads Claude Code into /tmp. Log each such invocation
        # so /tmp growth can be correlated. Free-form line -> tray ignores it.
        if [ -n "${CLAUDE_USING_BUNX:-}" ]; then
            log_monitor "bunx-fallback: invoking 'bunx claude auth status' (re-downloads to /tmp; issue #68)"
        fi
        auth_output=$(timeout 30 $CLAUDE_BIN auth status 2>/dev/null)
        auth_exit=$?
        # `claude auth status` exits 1 when simply not logged in but still
        # emits valid JSON ({"loggedIn": false, ...}). Treat exit code as
        # advisory only — parse the JSON and use loggedIn if it's there.
        # Skip only on `timeout` (124) or unparseable output (genuinely broken).
        auth_logged_in=$(echo "$auth_output" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("loggedIn", False))
except Exception:
    pass
' 2>/dev/null)
        if [ "$auth_exit" -eq 124 ]; then
            log_monitor "TASK=auth STATUS=skip DETAILS=\"auth status timed out\""
        elif [ -z "$auth_logged_in" ]; then
            log_monitor "TASK=auth STATUS=skip DETAILS=\"auth status output not parseable (exit $auth_exit)\""
        else
        # auth_logged_in is now "True" or "False" — proceed with the existing logic.

        if [ "$auth_logged_in" = "True" ]; then
            log_monitor "TASK=auth STATUS=ok"
            rm -f /tmp/claude_auth_alert_sent /tmp/claude_reauth_in_progress
        elif command -v taskramen_auth_mode >/dev/null 2>&1 && [ "$(taskramen_auth_mode)" = "login" ]; then
            # ── Interactive-login (#6) mode — do NOT fall through to the legacy
            # setup-token reauth in the `else` below. That block drives
            # `claude setup-token` and rewrites CLAUDE_CODE_OAUTH_TOKEN back into
            # .env, which silently reverts the system to headless-token auth (#5)
            # and drops claude.ai connectors (issue #356). Re-establishing a #6
            # login needs the user to approve in a browser, so we just alert here
            # rather than auto-running setup-token.
            #
            # We emit the EXISTING "expired" status (not a new one) so the Windows
            # tray needs no changes: its auth-degraded detection and its "Repair →
            # Reauthenticate Claude" action already react to STATUS=expired, and
            # claude_auth() is now auth-mode aware — in login mode it delegates to
            # install/claude-login.sh, so that one tray action does the right thing
            # for both auth paths.
            #
            # IMPORTANT: log STATUS=expired on EVERY cycle, NOT just the first.
            # The tray reads only `tail -n 50 /tmp/monitor.log` and keeps the
            # LAST-seen status per task. While login is expired this branch emits
            # no STATUS=ok, but every healthy cycle still emits ~7-10 OTHER
            # TASK=… ok lines; a single one-shot "expired" line would scroll out
            # of the 50-line window within tens of minutes, leaving no `auth`
            # entry and silently flipping the tray back to green while the login
            # is still dead. Re-logging each cycle keeps the tail truthful. (The
            # token-mode `else` path stays fresh for free because it re-logs ok
            # every healthy cycle and a terminal ok/reauth_fail during reauth.)
            # Only the Telegram alert is throttled by the sentinel, which is
            # cleared on the next STATUS=ok (above).
            log_monitor "TASK=auth STATUS=expired DETAILS=\"interactive login (#6) expired; no setup-token fallback\""
            if [ ! -f /tmp/claude_auth_alert_sent ]; then
                send_tg "⚠️ Your Claude login appears to have expired. Re-authenticate via the tray (Repair → Reauthenticate Claude) or run install/claude-login.sh."
                touch /tmp/claude_auth_alert_sent
            fi
        else
            # Sentinel: don't retry re-auth if already attempted and user didn't respond
            if [ ! -f /tmp/claude_auth_alert_sent ]; then
                log_monitor "TASK=auth STATUS=expired DETAILS=\"starting re-auth\""
                send_tg "⚠️ Claude auth expired. Starting re-authentication..."
                touch /tmp/claude_auth_alert_sent
                touch /tmp/claude_reauth_in_progress

                # ── Stop claudebot (can't work without auth) ──
                # Stopped ONCE before the retry loop; restarted ONCE after,
                # so claudebot doesn't bounce on every retry attempt.
                echo "[$(date)] Auth expired — stopping claudebot for re-auth"
                # Deliberate stop (#513): covers a fast bail (e.g. no OAuth URL)
                # leaving Claude down when the next TASK 2 runs. On the normal
                # ≥10-min interactive path the stamp goes stale long before the
                # loop resumes, so TASK 2's safety-net recovery is not delayed.
                stamp_planned_restart
                if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
                    tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
                else
                    CLAUDE_PID=$(find_claude_pid)
                    [ -n "$CLAUDE_PID" ] && kill "$CLAUDE_PID" 2>/dev/null || true
                fi
                sleep 3

                # Strip ANSI helper (inline) — used by all attempts
                _monitor_strip_ansi() {
                    sed 's/\x1b\[[0-9;]*[mGKHFABCDJh]//g; s/\x1b\[[?][0-9]*[hl]//g; s/\x1b][0-9]*;[^\x07]*\x07//g; s/\x1b][^\\]*\\//g; s/\r//g'
                }

                # ── OAuth flow with retry ──
                # Wrap the full OAuth flow in a retry loop so a wrong/expired
                # code or transient verification failure re-prompts the user
                # immediately instead of waiting 5 min for the next gated cycle.
                # Cap at REAUTH_MAX_ATTEMPTS so a fundamentally broken auth
                # backend doesn't spin forever or spam Telegram.
                #
                # Per-attempt outcomes:
                #   success                     → break, restart claudebot
                #   no OAuth URL captured       → bail (infrastructure, not user)
                #   no code received in 10 min  → bail (user gave up)
                #   wrong code / no token       → continue (retry, fresh URL)
                #   token saved, verify failed  → continue (retry, fresh URL);
                #                                 last saved token kept in .env
                REAUTH_MAX_ATTEMPTS=5
                REAUTH_TIMEOUT=600  # 10 minutes per attempt for user response
                reauth_ok=false
                last_sk_token=""

                for attempt in $(seq 1 $REAUTH_MAX_ATTEMPTS); do
                    if [ "$attempt" -gt 1 ]; then
                        log_monitor "TASK=auth STATUS=reauth_retry DETAILS=\"starting attempt $attempt\""
                    fi

                    REAUTH_DEADLINE=$(( $(date +%s) + REAUTH_TIMEOUT ))

                    # Per-attempt unique names so sessions/files don't collide
                    auth_session="claude-reauth-$$-$attempt"
                    auth_socket="claude-reauth-$$-$attempt"
                    capture_file="/tmp/claude-reauth-capture-$$-$attempt.txt"
                    rm -f "$capture_file"

                    # Create wide tmux session for setup-token
                    tmux -L "$auth_socket" new-session -d -s "$auth_session" -x 400 -y 50 2>/dev/null || true
                    script_cmd="script -q -f \"$capture_file\" -c '$CLAUDE_BIN setup-token'"
                    tmux -L "$auth_socket" send-keys -t "$auth_session" "$script_cmd" Enter 2>/dev/null || true

                    # Poll for OAuth URL (up to 45s)
                    oauth_url=""
                    for _i in $(seq 1 45); do
                        [ $(date +%s) -ge $REAUTH_DEADLINE ] && break
                        sleep 1
                        if [[ -f "$capture_file" ]]; then
                            file_clean=$(cat "$capture_file" 2>/dev/null | _monitor_strip_ansi)
                            oauth_url=$(echo "$file_clean" | grep -o 'https://claude\.com/cai/oauth/authorize[^[:space:]]*' | head -1)
                            if [[ -z "$oauth_url" ]]; then
                                oauth_url=$(echo "$file_clean" \
                                    | tr -d '\r' \
                                    | grep -A1 'https://claude\.com/cai/oauth/authorize' \
                                    | tr -d '\n' \
                                    | grep -o 'https://claude\.com/cai/oauth/authorize[^[:space:]]*')
                            fi
                        fi
                        [ -n "$oauth_url" ] && break
                    done

                    if [ -z "$oauth_url" ]; then
                        # Infrastructure failure — retrying won't help. Bail.
                        log_monitor "TASK=auth STATUS=reauth_fail DETAILS=\"could not capture OAuth URL (attempt $attempt)\""
                        echo "[$(date)] Re-auth failed: could not capture OAuth URL"
                        send_tg "❌ Re-authentication failed — could not get OAuth URL. Will retry next cycle."
                        tmux -L "$auth_socket" kill-server 2>/dev/null || true
                        rm -f "$capture_file"
                        break
                    fi

                    # Send OAuth URL to user via Telegram (monospace for tap-to-copy)
                    # Use plain parse_mode to avoid Markdown mangling the URL
                    curl -s --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "$(python3 -c "
import json
msg = '''🔐 Re-authenticate Claude (attempt ${attempt}/${REAUTH_MAX_ATTEMPTS})

Copy and paste this link into a browser where you are logged in to Claude.ai:

$oauth_url

After approving, the page shows a code. Copy and paste it here.

(You have 10 minutes to respond.)'''
print(json.dumps({'chat_id': int('${TELEGRAM_CHAT_ID}'), 'text': msg}))
")" >/dev/null 2>&1

                    # Wait for user to reply with the code (poll Telegram directly)
                    log_monitor "TASK=auth STATUS=reauth_progress DETAILS=\"OAuth URL sent (attempt $attempt)\""
                    echo "[$(date)] Re-auth: OAuth URL sent (attempt $attempt), waiting for code..."

                    # Drain stale updates
                    drain_resp=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=1&offset=-1" 2>/dev/null)
                    poll_offset=$(echo "$drain_resp" | python3 -c '
import json,sys
d = json.load(sys.stdin)
res = d.get("result", [])
print(res[-1]["update_id"] + 1 if res else 0)
' 2>/dev/null || echo "0")

                    # Only accept the code from the configured chat: without a
                    # chat filter, ANY user (or any other group the bot is in)
                    # who messages the bot during the 10-min window has their
                    # text consumed as the OAuth code — burning the attempt,
                    # or worse, letting a stranger inject their own code.
                    # Foreign / non-text updates still advance the offset
                    # (printed with an empty code field) so a stray message
                    # can't block the queue and spin the poll on one batch.
                    # The parser emits ONE line — "offset|flag|code" with the
                    # code reduced to its first non-empty line — so a
                    # multi-line reply can't smear across the cut/regex
                    # parsing below (install/utils.sh guards its own poll the
                    # same way). flag=F records that a text reply from a
                    # DIFFERENT chat was seen and ignored, surfaced on timeout
                    # so a stale TELEGRAM_CHAT_ID isn't a silent black hole.
                    # --max-time on every curl: the deadline is only checked
                    # between polls, so an unbounded curl on a dead socket
                    # would hang the whole monitor loop indefinitely.
                    auth_code=""
                    reauth_filtered_seen=false
                    while [ $(date +%s) -lt $REAUTH_DEADLINE ]; do
                        resp=$(curl -s --max-time 40 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=30&offset=${poll_offset}" 2>/dev/null)
                        result=$(echo "$resp" | TG_CHAT_ID="${TELEGRAM_CHAT_ID}" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
if not isinstance(d, dict):
    sys.exit()
# Per-item isinstance guards (same pattern as probe_stream_signals): a
# malformed update must be SKIPPED, not crash the parse — an exception
# here would print nothing, leave the offset stalled, and re-read the
# same batch until the deadline.
want = os.environ.get("TG_CHAT_ID", "").strip()
next_off = None
code = None
skipped_foreign = False
for upd in d.get("result") or []:
    if not (isinstance(upd, dict) and isinstance(upd.get("update_id"), int)):
        continue
    next_off = upd["update_id"] + 1
    msg = upd.get("message") or upd.get("channel_post")
    if not (isinstance(msg, dict) and isinstance(msg.get("text"), str)):
        continue
    chat = msg.get("chat") if isinstance(msg.get("chat"), dict) else {}
    if str(chat.get("id")) != want:
        skipped_foreign = True
        continue
    code = msg["text"]
    break
if next_off is not None:
    lines = [l.strip() for l in (code or "").splitlines() if l.strip()]
    first = lines[0] if lines else ""
    print(str(next_off) + "|" + ("F" if skipped_foreign else "") + "|" + first)
' 2>/dev/null)
                        if [ -n "$result" ]; then
                            new_offset=$(echo "$result" | head -n 1 | cut -d'|' -f1 | tr -d ' ')
                            [[ "$new_offset" =~ ^[0-9]+$ ]] && poll_offset=$new_offset
                            [ "$(echo "$result" | head -n 1 | cut -d'|' -f2)" = "F" ] && reauth_filtered_seen=true
                            auth_code=$(echo "$result" | head -n 1 | cut -d'|' -f3- | tr -d '[:space:]')
                            if [ -n "$auth_code" ]; then
                                # Acknowledge
                                curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=1&offset=${poll_offset}" >/dev/null 2>&1
                                break
                            fi
                        fi
                    done

                    if [ -z "$auth_code" ]; then
                        # User did not respond in 10 min — assume they gave up.
                        # Don't keep prompting; bail to next gated cycle. If a
                        # text reply from a different chat was filtered out,
                        # say so — a stale TELEGRAM_CHAT_ID (e.g. a group
                        # migrated to a supergroup) would otherwise look
                        # identical to silence.
                        if $reauth_filtered_seen; then
                            log_monitor "TASK=auth STATUS=reauth_fail DETAILS=\"no code received within timeout (attempt $attempt); a reply from a DIFFERENT chat was ignored — TELEGRAM_CHAT_ID may be stale\""
                            echo "[$(date)] Re-auth failed: no code received within timeout (a reply from a different chat was ignored)"
                            send_tg "⏳ No code received within timeout. A reply from a different chat was seen and ignored — if that was you, the configured chat may be stale. Re-auth cancelled. Will retry next cycle."
                        else
                            log_monitor "TASK=auth STATUS=reauth_fail DETAILS=\"no code received within timeout (attempt $attempt)\""
                            echo "[$(date)] Re-auth failed: no code received within timeout"
                            send_tg "⏳ No code received within timeout. Re-auth cancelled. Will retry next cycle."
                        fi
                        tmux -L "$auth_socket" kill-server 2>/dev/null || true
                        rm -f "$capture_file"
                        break
                    fi

                    log_monitor "TASK=auth STATUS=reauth_progress DETAILS=\"code received, injecting (attempt $attempt)\""
                    send_tg "✅ Code received! Injecting into claude setup-token..."
                    echo "[$(date)] Re-auth: code received, injecting..."

                    # Inject code into tmux
                    tmux -L "$auth_socket" send-keys -l -t "$auth_session" "$auth_code" 2>/dev/null || true
                    tmux -L "$auth_socket" send-keys -t "$auth_session" "" Enter 2>/dev/null || true

                    # Poll capture file for sk token (up to 30s)
                    sk_token=""
                    for _poll_i in $(seq 1 30); do
                        sleep 1
                        if [[ -f "$capture_file" ]]; then
                            sk_token=$(grep -o 'sk-ant-oat01-[A-Za-z0-9_-]*' "$capture_file" 2>/dev/null | head -1)
                            if [[ -z "$sk_token" ]]; then
                                sk_token=$(cat "$capture_file" 2>/dev/null | _monitor_strip_ansi \
                                    | grep -o 'sk-ant-oat01-[A-Za-z0-9_-]*' | head -1)
                            fi
                        fi
                        [ -n "$sk_token" ] && break
                    done

                    # Clean up per-attempt tmux session
                    tmux -L "$auth_socket" kill-server 2>/dev/null || true
                    rm -f "$capture_file"

                    if [ -z "$sk_token" ]; then
                        # Wrong code, expired code, or other capture failure.
                        # Re-prompt with a fresh OAuth URL on the next iteration.
                        log_monitor "TASK=auth STATUS=reauth_retry DETAILS=\"token not captured (attempt $attempt)\""
                        echo "[$(date)] Re-auth attempt $attempt: sk token not captured — will retry"
                        if [ "$attempt" -lt "$REAUTH_MAX_ATTEMPTS" ]; then
                            send_tg "❌ That code did not produce a valid token. Sending a fresh URL..."
                        fi
                        continue
                    fi

                    # Save token to .env
                    env_file="$CLAUDE_HOME/.env"
                    if grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" "$env_file" 2>/dev/null; then
                        sed -i "s|^CLAUDE_CODE_OAUTH_TOKEN=.*|CLAUDE_CODE_OAUTH_TOKEN=${sk_token}|" "$env_file"
                    else
                        echo "CLAUDE_CODE_OAUTH_TOKEN=${sk_token}" >> "$env_file"
                    fi
                    chmod 600 "$env_file"
                    export CLAUDE_CODE_OAUTH_TOKEN="$sk_token"
                    last_sk_token="$sk_token"

                    echo "[$(date)] Re-auth: token saved, verifying..."

                    # Verify auth. NB: the env assignment must come BEFORE
                    # `timeout` — placed after it, timeout tries to exec the
                    # literal string "CLAUDE_CODE_OAUTH_TOKEN=..." and fails
                    # (127), so verification could never succeed and every
                    # re-auth looped through all attempts despite a good token.
                    # Same timeout and stderr handling as the TASK 5 call
                    # above: 30s covers a slow (e.g. bunx) CLI start, and
                    # stderr must not reach the JSON parse — any CLI chatter
                    # would fail json.load and misread a good token as bad.
                    verify_out=$(CLAUDE_CODE_OAUTH_TOKEN="$sk_token" timeout 30 $CLAUDE_BIN auth status 2>/dev/null) || true
                    verify_ok=$(echo "$verify_out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("loggedIn", False))' 2>/dev/null || echo "False")

                    if [ "$verify_ok" = "True" ]; then
                        log_monitor "TASK=auth STATUS=reauth_success DETAILS=\"token verified (attempt $attempt)\""
                        echo "[$(date)] Re-auth successful on attempt $attempt!"
                        reauth_ok=true
                        break
                    fi

                    # Token captured but Anthropic rejected it. Could be CLI bug
                    # or a real reject. Retry with a fresh attempt.
                    log_monitor "TASK=auth STATUS=reauth_retry DETAILS=\"verification failed (attempt $attempt)\""
                    echo "[$(date)] Re-auth attempt $attempt: token saved but verification failed — will retry"
                    if [ "$attempt" -lt "$REAUTH_MAX_ATTEMPTS" ]; then
                        send_tg "⚠️ Token verification failed. Sending a fresh URL..."
                    fi
                done

                # ── After loop: handle outcome and restart claudebot ──
                if $reauth_ok; then
                    rm -f /tmp/claude_auth_alert_sent /tmp/claude_reauth_in_progress
                    stamp_planned_restart   # our own restart — don't re-flag it (#513)
                    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
                        export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
                        tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
                        tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"
                    else
                        sudo systemctl restart claudebot.service
                    fi
                    send_tg "✅ Claude re-authenticated and restarted successfully!"
                elif [ -n "$last_sk_token" ]; then
                    # All attempts exhausted but at least one captured a token
                    # (verify failed every time). Restart claudebot with the
                    # last saved token as a best-effort recovery — the token
                    # might still work despite verify failure (transient
                    # backend reject, etc.). Sentinel stays so we don't
                    # re-prompt on the next gated cycle if it's actually bad.
                    log_monitor "TASK=auth STATUS=reauth_partial DETAILS=\"all $REAUTH_MAX_ATTEMPTS attempts failed verify; restarting with last token\""
                    send_tg "⚠️ Could not verify any token after $REAUTH_MAX_ATTEMPTS attempts. Restarting Claude with last token anyway — it may still work."
                    rm -f /tmp/claude_reauth_in_progress
                    stamp_planned_restart   # our own restart — don't re-flag it (#513)
                    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
                        export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
                        tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
                        tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"
                    else
                        sudo systemctl restart claudebot.service
                    fi
                else
                    # Bailed (no OAuth URL or no user response) OR every
                    # attempt failed token capture. Don't restart claudebot;
                    # the next gated cycle will reassess. Sentinel stays so
                    # we don't immediately re-prompt — user can remove
                    # /tmp/claude_auth_alert_sent to retry sooner.
                    if [ "$attempt" -ge "$REAUTH_MAX_ATTEMPTS" ]; then
                        log_monitor "TASK=auth STATUS=reauth_fail DETAILS=\"exhausted $REAUTH_MAX_ATTEMPTS attempts, no token captured\""
                        send_tg "🚨 Re-auth failed after $REAUTH_MAX_ATTEMPTS attempts (no token captured). Will retry on next gated cycle. Remove /tmp/claude_auth_alert_sent to retry sooner."
                    fi
                    rm -f /tmp/claude_reauth_in_progress
                fi
            fi
        fi
        fi
    fi

    # --- TASK 8: BROWSER CDP HEALTH CHECK (container only) ---
    # The shared stealth Chrome (CDP :9222) can die on its own (OOM / tmpfs
    # pressure) while Claude stays alive. The frozen-restart path (TASK 2) only
    # respawns it as a side effect of a full Claude restart, so a lone browser
    # crash had no recovery path (issue #305). Probe the CDP endpoint; after 2
    # consecutive failures respawn Chromium, gated by a 5-min cooldown to avoid
    # thrash while it boots.
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        if curl -sf --max-time 5 http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
            rm -f /tmp/browser_cdp_fail_count
        else
            bcount=$(cat /tmp/browser_cdp_fail_count 2>/dev/null)
            bcount=$(( ${bcount:-0} + 1 ))  # default-expand so an empty/missing file can't break arithmetic
            echo "$bcount" > /tmp/browser_cdp_fail_count
            log_monitor "TASK=browser STATUS=unreachable DETAILS=\"CDP :9222 probe failed ($bcount consecutive)\""
            if [ "$bcount" -ge 2 ]; then
                bnow=$(date +%s)
                blast=$(cat /tmp/browser_last_respawn 2>/dev/null)
                blast=${blast:-0}  # default-expand against an empty/missing file
                if [ $((bnow - blast)) -ge 300 ]; then
                    echo "$bnow" > /tmp/browser_last_respawn
                    rm -f /tmp/browser_cdp_fail_count
                    log_monitor "TASK=browser STATUS=respawn DETAILS=\"CDP :9222 down 2 checks; respawning Chromium\""
                    send_tg "🔁 System message - browser (CDP :9222) was down; respawning Chromium."
                    respawn_browser
                else
                    log_monitor "TASK=browser STATUS=cooldown DETAILS=\"respawn suppressed; last respawn $((bnow - blast))s ago\""
                fi
            fi
        fi
    fi

    # 1-min loop. Cheap checks (frozen, plugin liveness, supercronic, log scan)
    # run every iteration; expensive checks (auth status, Telegram getMe) are
    # gated by $do_expensive to fire every ~5 min. Inline sleeps in recovery
    # paths (sleep 120 in is_frozen, 5×120s in the frozen retry, REAUTH_TIMEOUT
    # in reauth) still block the loop for minutes during recovery — that is
    # intentional and unchanged.
    sleep 60
done
