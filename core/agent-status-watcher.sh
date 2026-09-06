#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Usage: agent-status-watcher.sh <output_file> <agent_label> [log_file]
# Monitors a background agent output file and injects a Telegram status update every 2 minutes.
# Self-terminates when the agent finishes, when the agent is GONE (stopped via
# TaskStop or cleaned up — see below), or after a frozen escalation:
# frozen warning at 6 min stale, frozen stop at 12 min stale.
#
# FROZEN ESCALATIONS REACH THE USER DIRECTLY (issue #492): the 6-min (once)
# and 12-min alerts are sent straight to Telegram via core/telegram-direct.sh
# in addition to the injected session trigger, whose text adapts to whether
# the direct send was delivered. Full rationale, delivery contract, and the
# staleness/false-alarm handling: see notify_user_direct below.
#
# STALE-ALERT PREVENTION (issue #437): an agent that was deliberately stopped
# is indistinguishable from a hung one by file growth alone — the output file
# just stops growing (or is removed by the harness), which used to escalate to
# "may be frozen"/"appears FROZEN" alerts for a task that no longer existed.
# Two GONE signals now make the watcher exit SILENTLY (no injection at all):
#   1. The output file (or its symlink) disappears — the harness removes the
#      tasks-dir entry when a task ends.
#   2. A stop flag /tmp/agent_stopped_<task_id>.flag exists — touched by the
#      PostToolUse TaskStop hook (core/hooks/task-stopped.sh); <task_id> is
#      this output file's basename without the .output suffix.
# As defence in depth, the frozen trigger texts also tell the main session to
# verify the task still exists (TaskList) and silently ignore a stale alert.
#
# LIFECYCLE: this process is nohup-detached and outlives the Claude instance
# that spawned it, but the background agent it watches dies WITH that instance.
# run.sh kills all live watchers pre-launch on every Claude (re)start so a
# survivor can't report the previous session's (now dead) agent as frozen to
# the new session. If you change this script's path/name, update the pkill
# pattern in run.sh's _kill_stale_agent_watchers.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

OUTPUT_FILE="$1"
LABEL="$2"
LOG_FILE="${3:-}"

if [ -z "$OUTPUT_FILE" ] || [ -z "$LABEL" ]; then
    echo "Usage: agent-status-watcher.sh <output_file> <agent_label> [log_file]"
    exit 1
fi

STALE_COUNT=0
START_TIME=$SECONDS
MAX_RUNTIME=1800
# Loop tick — overridable ONLY for testing;
# production always runs the 2-min default that the 6/12-min thresholds assume.
TICK_SECS="${AGENT_WATCHER_TICK_SECS:-120}"
# LAST_SIZE is initialized to the real file size just before the loop, after the
# output file is known to exist (see the snapshot below the is_agent_done helper).

# Stop flag touched by core/hooks/task-stopped.sh when the main session calls
# TaskStop. Task id = output file basename minus .output; same sanitize charset
# as the hook so both sides derive the identical flag path.
TASK_ID="$(basename "$OUTPUT_FILE")"
TASK_ID="${TASK_ID%.output}"
TASK_ID="${TASK_ID//[^a-zA-Z0-9._@-]/}"
STOP_FLAG="/tmp/agent_stopped_${TASK_ID}.flag"

# Clean up log file (and a consumed stop flag) on exit
cleanup() {
    [ -n "$LOG_FILE" ] && rm -f "$LOG_FILE"
    [ -n "$TASK_ID" ] && rm -f "$STOP_FLAG"
}
trap cleanup EXIT

# The agent is GONE (deliberately stopped or cleaned up — NOT frozen) when its
# stop flag exists or its output file has vanished. `-e` follows symlinks, so a
# dangling .output symlink whose transcript target was never created yet is NOT
# treated as gone (`-L` still sees the link itself); a removed tasks-dir entry is.
agent_gone() {
    [ -n "$TASK_ID" ] && [ -f "$STOP_FLAG" ] && return 0
    [ ! -e "$OUTPUT_FILE" ] && [ ! -L "$OUTPUT_FILE" ] && return 0
    return 1
}

# Check if the agent has finished by parsing the tail of the output file as JSON.
# Exit codes:
#   0 = definitively done   (assistant turn carrying an explicit stop_reason)
#   2 = ambiguously done     (final assistant turn is text-only with no stop_reason —
#       the harness quirk from issue #304; this is ONLY trusted by the caller once the
#       output file has also stopped growing, because an interim line like
#       "Searching Amazon..." printed before the first tool call looks identical)
#   1 = still running
is_agent_done() {
    local outfile="$1"
    [ ! -f "$outfile" ] && return 1
    python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'rb') as f:
        # Read last 32KB (enough for final JSON lines + metadata)
        f.seek(0, 2)
        size = f.tell()
        if size == 0:
            sys.exit(1)
        pos = max(0, size - 32768)
        f.seek(pos)
        chunk = f.read().decode('utf-8', errors='replace')
        lines = [l.strip() for l in chunk.splitlines() if l.strip()]
        if not lines:
            sys.exit(1)
        # A settled sub-agent ends with a clean assistant text reply. The harness
        # does NOT reliably stamp stop_reason='end_turn' on that final line (it is
        # often null), so requiring 'end_turn' left completed agents looking 'not
        # done' forever, which then escalated to a false FROZEN alert (issue #304).
        # Decide from WHAT the last meaningful turn is, not just stop_reason:
        #   - assistant turn with a pending tool_use  -> still working   (exit 1)
        #   - user turn (tool_result) as the tail     -> still working   (exit 1)
        #   - assistant turn with a stop_reason       -> done            (exit 0)
        #   - assistant turn, stop_reason null + text -> ambiguous       (exit 2)
        #     (settled reply OR interim text before the first tool call — the
        #      caller resolves this using output-file growth)
        for line in reversed(lines[-20:]):
            try:
                d = json.loads(line)
            except (json.JSONDecodeError, ValueError):
                continue
            if not isinstance(d, dict):
                continue  # non-dict JSON (string/list/bool) -> skip, keep scanning
            msg = d.get('message', d)
            if not isinstance(msg, dict):
                continue
            role = msg.get('role', '')
            if role == 'user':
                sys.exit(1)  # tool_result / user turn pending -> agent still working
            if role == 'assistant':
                stop = msg.get('stop_reason')
                content = msg.get('content', [])
                blocks = content if isinstance(content, list) else []
                has_tool_use = any(
                    isinstance(b, dict) and b.get('type') == 'tool_use' for b in blocks)
                has_text = any(
                    isinstance(b, dict) and b.get('type') == 'text' and b.get('text', '').strip()
                    for b in blocks) or (isinstance(content, str) and content.strip())
                if has_tool_use:
                    sys.exit(1)              # pending tool call -> still working
                if stop is not None:
                    sys.exit(0)              # any settled turn: end_turn/max_tokens/stop_sequence/refusal
                if has_text:
                    sys.exit(2)              # text-only tail, no stop_reason -> ambiguous (caller checks file growth)
                sys.exit(1)
            # other line types (system/init/etc.) -> keep scanning backward
    sys.exit(1)
except Exception:
    sys.exit(1)
except BaseException:
    raise
" "$outfile"
}

# Wait up to 30s for the output file to appear (agent may not have written anything yet)
WAIT=0
while [ ! -f "$OUTPUT_FILE" ] && [ "$WAIT" -lt 30 ]; do
    sleep 1
    WAIT=$((WAIT + 1))
done

# Emit the "agent completed" trigger. The main session usually relays the
# agent's result itself the moment the task returns, so this trigger lands
# AFTER the user already has the answer (issue #451) — it must instruct a
# conditional send, not an unconditional "say it's done", or every successful
# agent produces a duplicate completion ping.
emit_done() {
    local msg="[SYSTEM CRON TRIGGER]: Background agent \"$LABEL\" has completed. If its results have not yet been sent to the user, decide whether to send them via Telegram. If they were already sent (this turn or earlier), do nothing and end the turn silently — no duplicate 'task done' ping, and no meta message about the skipped ping."
    "$CLAUDE_HOME/core/inject.sh" "$msg" --no-telegram
}

# Direct user-facing Telegram send, bypassing the session's message loop
# (issue #492): a stuck tool call in the watched agent can block the ENTIRE
# session — inbound queue and injected triggers included — so frozen alerts
# routed only through inject.sh sat undelivered for the exact duration of the
# hang they were reporting. Escalation warnings therefore go to the user
# straight from this out-of-band process. Returns telegram-direct.sh's exit
# code (0 = API-confirmed delivery), so each escalation site can tell the
# session whether the user was actually warned: on success the injected
# trigger forbids a duplicate session-side warning; on failure it instructs
# the session to relay the warning itself (the pre-#492 path). Runs in the
# foreground deliberately — the delivery status IS the branch condition — and
# stderr is left attached so telegram-direct.sh's failure diagnostics (and a
# missing-script exec error) land in this watcher's log.
# Direct sends bypass the session's TaskList staleness gate (issue #437), so
# a task that ended in a way agent_gone() can't see may still ping the user —
# e.g. the post-restart orphan-watcher race documented in run.sh. The injected
# triggers compensate: when the session's TaskList check shows the task gone
# AFTER a delivered warning, it sends a one-line false-alarm correction.
notify_user_direct() {
    "$CLAUDE_HOME/core/telegram-direct.sh" "$1"
}

# Snapshot the starting size so the FIRST post-sleep growth delta is meaningful.
# (With LAST_SIZE=0 the first interval always looked like growth, delaying stale
# detection by one cycle.) Use `wc -c < file` rather than stat: the redirection
# follows the symlink to the real transcript and counts the target's bytes (a
# bare stat on the symlink returns the ~133-byte path length, causing false
# alerts), and it stays portable across GNU and BSD/macOS coreutils.
LAST_SIZE=$( { wc -c < "$OUTPUT_FILE"; } 2>/dev/null || echo 0)

# Counts active (output-producing) ticks. Used to fire a status update only on
# odd ticks, so pings land at ~2 min (first), then every ~4 min after.
status_tick=0

while true; do
    # Gone agent (stopped/cleaned up) → exit SILENTLY. Injecting anything here
    # produces the stale frozen alerts of issue #437; silence is correct — the
    # main session already knows, it stopped the task itself.
    if agent_gone; then
        echo "$(date): agent \"$LABEL\" gone (stopped or cleaned up) — exiting silently"
        break
    fi

    # Fast path: a definitively-settled agent (explicit stop_reason) is done
    # immediately, even on this first check before any sleep. An ambiguous
    # text-only tail (exit 2) is NOT trusted here — an agent that prints an
    # interim line like "Searching Amazon..." before its first tool call is
    # indistinguishable from a finished reply until the file stops growing,
    # so we fall through and let the growth check below decide. Trusting it
    # here made the watcher exit on iteration 1 and never send status updates.
    is_agent_done "$OUTPUT_FILE"; DONE_RC=$?
    if [ "$DONE_RC" -eq 0 ]; then
        emit_done
        break
    fi

    sleep "$TICK_SECS"

    # Re-check for a gone agent straight after the sleep — a TaskStop during
    # the interval must not be misread below as "file stopped growing" (stale).
    if agent_gone; then
        echo "$(date): agent \"$LABEL\" gone (stopped or cleaned up) — exiting silently"
        break
    fi

    # Absolute runtime cap — exit after MAX_RUNTIME seconds
    ELAPSED_SEC=$((SECONDS - START_TIME))
    if [ "$ELAPSED_SEC" -ge "$MAX_RUNTIME" ]; then
        TIMEOUT_MSG="[SYSTEM CRON TRIGGER]: Agent \"$LABEL\" watcher exiting — reached ${MAX_RUNTIME}s runtime cap."
        "$CLAUDE_HOME/core/inject.sh" "$TIMEOUT_MSG" --no-telegram
        break
    fi

    # Measure output growth over the interval we just slept through.
    # (wc -c < file: portable, follows the symlink — see the snapshot note above.)
    CURRENT_SIZE=$( { wc -c < "$OUTPUT_FILE"; } 2>/dev/null || echo 0)
    SIZE_DELTA=$((CURRENT_SIZE - LAST_SIZE))
    LAST_SIZE=$CURRENT_SIZE
    STALE=0
    [ "$SIZE_DELTA" -lt 100 ] && STALE=1

    # Re-check completion now that we know whether the file is still growing.
    is_agent_done "$OUTPUT_FILE"; DONE_RC=$?
    if [ "$DONE_RC" -eq 0 ]; then
        emit_done
        break
    fi
    # Ambiguous text-only tail is only trusted once the file has stopped growing.
    # A static file rules out the interim-text-before-tool-call case and leaves
    # only the genuine harness-quirk completion (issue #304).
    if [ "$DONE_RC" -eq 2 ] && [ "$STALE" -eq 1 ]; then
        emit_done
        break
    fi

    # Stale file detection (agent crashed/hung — distinct from a clean finish).
    if [ "$STALE" -eq 1 ]; then
        STALE_COUNT=$((STALE_COUNT + 1))
        STALE_MINUTES=$((STALE_COUNT * 2))

        if [ "$STALE_COUNT" -ge 6 ]; then
            # 12+ min stale — direct-warn the user, then inject the final
            # frozen trigger (staleness guard baked in, issue #437) and exit.
            # Trigger text depends on whether the direct send was delivered —
            # see notify_user_direct.
            if notify_user_direct "⛔ Agent \"$LABEL\" appears frozen — no activity for ${STALE_MINUTES} min. Asking the session to stop it now — you'll get a stop confirmation, or a correction if it had actually finished. If nothing arrives, the session itself is likely blocked by the stuck call and will catch up once it clears."; then
                FREEZE_MSG="[SYSTEM CRON TRIGGER]: Agent \"$LABEL\" appears FROZEN — output file has not grown for ${STALE_MINUTES} minutes. The watcher has ALREADY notified the user directly — do NOT repeat the frozen warning. FIRST verify the task still exists: check TaskList for this agent (quick main-session check, exempt from the background-agent rule). If it is not listed or already stopped/completed, the direct alert was a FALSE ALARM — send a one-line Telegram correction telling the user to ignore it (the agent had already finished or been stopped; mention its result was/will be delivered normally). Only if the task IS still running: (1) stop it with TaskStop, (2) send a Telegram message confirming the agent was stopped and offering to restart the task. Note: TaskStop does not kill the agent's spawned subprocesses — if it was stuck on a browser call and browser tasks keep failing afterwards, offer a Claude restart — the CLAUDE.md 'Restarting Claude' flow, distinct from restarting the task; it also clears wedged browser processes."
            else
                FREEZE_MSG="[SYSTEM CRON TRIGGER]: Agent \"$LABEL\" appears FROZEN — output file has not grown for ${STALE_MINUTES} minutes. The watcher could NOT reach the user directly (Telegram send failed — see watcher log). FIRST verify the task still exists: check TaskList for this agent (quick main-session check, exempt from the background-agent rule). If it is not listed or already stopped/completed, this alert is STALE — ignore it silently: no Telegram message, no action, end the turn (silence is the designed outcome). Only if the task IS still running: (1) send a Telegram message to the user saying the agent appears frozen and you are stopping it, (2) stop it with TaskStop, (3) offer to restart the task. Note: TaskStop does not kill the agent's spawned subprocesses — if it was stuck on a browser call and browser tasks keep failing afterwards, offer a Claude restart — the CLAUDE.md 'Restarting Claude' flow, distinct from restarting the task; it also clears wedged browser processes."
            fi
            "$CLAUDE_HOME/core/inject.sh" "$FREEZE_MSG" --no-telegram
            break
        elif [ "$STALE_COUNT" -eq 3 ]; then
            # Exactly 6 min stale — direct-warn the user ONCE (no repeats at
            # 8/10 min; the 12-min escalation is the next ping), inject a
            # trigger whose text depends on delivery, and keep watching.
            if notify_user_direct "⚠️ Agent frozen warning: $LABEL has had no activity for ${STALE_MINUTES} min — may be stuck. Will be stopped if there is no activity in the next $((12 - STALE_MINUTES)) min."; then
                WARN_MSG="[SYSTEM CRON TRIGGER]: Agent \"$LABEL\" may be frozen — output file has not grown for ${STALE_MINUTES} minute(s). The watcher has ALREADY warned the user directly — do NOT send another Telegram warning. FIRST verify the task still exists: check TaskList for this agent (quick main-session check, exempt from the background-agent rule). If it is not listed or already stopped/completed, the direct warning was a FALSE ALARM — send a one-line Telegram correction telling the user to ignore it (the agent had already finished or been stopped). If it IS still running, keep watching — no action needed this turn; end the turn silently (designed silence, reply-gate exempt)."
            else
                WARN_MSG="[SYSTEM CRON TRIGGER]: Agent \"$LABEL\" may be frozen — output file has not grown for ${STALE_MINUTES} minute(s). The watcher could NOT reach the user directly (Telegram send failed — see watcher log). FIRST verify the task still exists: check TaskList for this agent (quick main-session check, exempt from the background-agent rule). If it is not listed or already stopped/completed, this warning is STALE — ignore it silently: no Telegram message, no action, end the turn. Only if the task IS still running, send a brief Telegram warning to the user in this format: Agent frozen warning: $LABEL has had no activity for ${STALE_MINUTES} min — may be stuck. Will stop if no activity in next $((12 - STALE_MINUTES)) min."
            fi
            "$CLAUDE_HOME/core/inject.sh" "$WARN_MSG" --no-telegram
        fi
    else
        STALE_COUNT=0
    fi

    # Send status triggers only when the agent is actively producing output, and
    # only every 2nd active tick: first ping at ~2 min, then every ~4 min after.
    # The loop tick stays 2 min so freeze detection keeps its 6/12-min thresholds;
    # this just halves how often a status check is injected into the main session
    # (each injection is a full main-session turn → tokens). status_tick counts
    # active ticks; odd ticks (1,3,5 → 2,6,10 min) fire.
    #
    # Written with plain if-blocks (no bare `&&` statement, no standalone `(( ))`
    # arithmetic command) so a "skip this tick" result never surfaces as a
    # non-zero exit status that could abort the loop under `set -e`. The only
    # arithmetic is inside `$(( ))` expansions within `[ ]` tests in `if`
    # conditions, which `set -e` does not act on.
    send_status=false
    if [ "$STALE_COUNT" -eq 0 ]; then
        status_tick=$((status_tick + 1))
        if [ "$((status_tick % 2))" -eq 1 ]; then
            send_status=true
        fi
    fi
    if [ "$send_status" = true ]; then
        # Extract last 3 actions from output file (tool names + brief input)
        RECENT=$(python3 - "$OUTPUT_FILE" <<'PYEOF'
import json, sys

output_file = sys.argv[1]
try:
    with open(output_file) as f:
        lines = f.readlines()
    actions = []
    for line in lines[-40:]:
        try:
            d = json.loads(line.strip())
            content = d.get('message', {}).get('content', [])
            for c in content:
                if c.get('type') == 'tool_use':
                    name = c.get('name', '')
                    inp = c.get('input', {})
                    if name == 'Bash':
                        cmd = inp.get('command', '')[:70]
                        actions.append(f'Bash({cmd})')
                    elif name == 'WebSearch':
                        q = inp.get('query', inp.get('q', ''))[:50]
                        actions.append(f'WebSearch({q})')
                    elif 'agent-browser' in name.lower() or 'puppeteer' in name.lower():
                        actions.append(f'{name}')
                    else:
                        actions.append(name)
        except:
            continue
    recent = actions[-3:] if actions else ['working']
    print(' → '.join(recent))
except Exception as e:
    print('working')
PYEOF
)

        ELAPSED=$(( (SECONDS - START_TIME) / 60 ))
        INJECT_MSG="[SYSTEM CRON TRIGGER]: Agent status check — background agent \"$LABEL\" has been running for ${ELAPSED} min. Recent actions: $RECENT. Send a brief Telegram status update in this exact format (no other output): Status of $LABEL: [plain English summary of what it's doing right now]"

        "$CLAUDE_HOME/core/inject.sh" "$INJECT_MSG" --no-telegram
    fi
done
