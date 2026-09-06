#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# core/list-tasks.sh — list scheduled tasks in the USER's timezone.
#
# The crontab / `at` queue store every entry in SYSTEM_TIMEZONE (the scheduler
# frame). This is the ONLY sanctioned way to show tasks to the user: it converts
# each schedule back to the user's zone (from the entry's UF= intent tag when
# present, else via core/tz-lib.sh) and prints the task prompt/command VERBATIM,
# so the reschedule flow can copy it straight into a new schedule.sh/at-task.sh
# call. Never show raw `cat .crontab` output to the user — it is in system time.
#
# All line parsing goes through tz-lib's tz_parse_cron_line — the one parser
# for stored entries — so payload text containing look-alike markers (' UF=',
# '#RECUR_1_2', ' && flock ') can never corrupt the listing.
#
# Usage: ./list-tasks.sh
# Container mode reads $CLAUDE_HOME/.crontab; VM mode reads `crontab -l` (+ `at`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# shellcheck source=/dev/null
source "$CLAUDE_HOME/core/tz-lib.sh"
tz_load_zones || {
    echo "Warning: timezone resolution failed; showing schedules in raw system frame." >&2
    TZ_USER="${TZ_SYS:-UTC}"; TZ_SYS="${TZ_SYS:-UTC}"; TZ_USER_ASSUMED=1
}

# _emit_task <cron_line>
# Print a task block for one TaskRamen-managed crontab line; silently ignore
# anything tz_parse_cron_line rejects.
_emit_task() {
    local line="$1"
    tz_parse_cron_line "$line" || return 0

    # Verbatim task text: unwrap the inject.sh prompt — reverse schedule.sh's
    # sanitisation exactly (single-quote wrapping, '\'' apostrophe escape, and
    # the \% supercronic escape) so the text can be copied straight back into a
    # schedule.sh/at-task.sh call. Raw --no-inject commands print as-is.
    local task
    if [[ "$TZP_PAYLOAD" == *"/inject.sh "* ]]; then
        task="${TZP_PAYLOAD#*/inject.sh }"
        task="${task% --no-telegram}"
        task="${task#\'}"; task="${task%\'}"
        task="${task//\'\\\'\'/\'}"
        task="${task//\\%/%}"
    else
        task="$TZP_PAYLOAD"
    fi

    local nf
    nf=$(tz_next_fire "$TZP_EXPR" "$TZ_USER")
    echo "[$TZP_ID]  $TZP_TYPE"
    if [[ "$TZP_TYPE" == "one-time" ]]; then
        # A one-time job's single fire instant IS the schedule — the raw cron
        # fields (e.g. "0 0 25 12 *") would only confuse. Show the datetime.
        if [[ -n "$nf" ]]; then
            echo "  When     : $nf $TZ_USER"
        else
            echo "  When     : $TZP_EXPR (system time — $TZ_SYS)"
        fi
    else
        # Recurring: describe the schedule in the user's frame — from the UF=
        # intent tag when present (USER sentinel → current USER_TIMEZONE),
        # else reverse-convert the stored expression.
        local sched_line
        if [[ -n "$TZP_UF_CRON" ]]; then
            sched_line="$(tz_cron_describe "$TZP_UF_CRON") $(tz_resolve_tag_zone "$TZP_UF_ZONE")"
        else
            local userexpr rc
            userexpr=$(tz_cron_s2u "$TZP_EXPR"); rc=$?
            if (( rc == 0 )); then
                sched_line="$(tz_cron_describe "$userexpr") $TZ_USER"
            else
                sched_line="$TZP_EXPR (system time — $TZ_SYS; not auto-convertible)"
            fi
        fi
        echo "  Schedule : $sched_line"
        [[ -n "$nf" ]] && echo "  Next fire: $nf $TZ_USER"
    fi
    echo "  Task     : $task"
    echo "  Cancel   : \$CLAUDE_HOME/core/delete-task.sh $TZP_ID"
    echo
}

# ---------------------------------------------------------------------------
# Gather lines and emit.
# ---------------------------------------------------------------------------
found=0
emit_stream() {
    local l
    while IFS= read -r l || [[ -n "$l" ]]; do
        [[ -z "$l" || "$l" == \#* ]] && continue
        if tz_parse_cron_line "$l"; then
            _emit_task "$l"
            found=1
        fi
    done
}

if tz_is_container; then
    CRONTAB_FILE="$CLAUDE_HOME/.crontab"
    if [[ -f "$CRONTAB_FILE" ]]; then
        emit_stream < "$CRONTAB_FILE"
    fi
else
    # VM: recurring/self-deleting jobs live in the user crontab. Process
    # substitution (not a pipe) keeps emit_stream in THIS shell so `found`
    # survives — `crontab -l | emit_stream` would set it in a subshell.
    emit_stream < <(crontab -l 2>/dev/null)
    # One-time `at` jobs (VM only). Best-effort: show queue time + payload via
    # `at -c`. `at` stores absolute times already in SYSTEM_TIMEZONE.
    if command -v at &>/dev/null; then
        while read -r jobid rest; do
            [[ -z "$jobid" ]] && continue
            local_cmd=$(at -c "$jobid" 2>/dev/null | grep -F "inject.sh" | tail -1)
            [[ -z "$local_cmd" ]] && continue
            found=1
            echo "[at#$jobid]  one-time (at queue)"
            echo "  When (sys): $rest"
            echo "  Cancel    : atrm $jobid"
            echo
        done < <(atq 2>/dev/null)
    fi
fi

if (( found == 0 )); then
    echo "No scheduled tasks."
fi
