#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# core/tz-resync.sh — keep recurring tasks anchored to the intended wall clock.
#
# schedule.sh stores every entry in SYSTEM_TIMEZONE and records the original
# intent in a trailing "UF=<cron5>@<zone>" comment tag, where <zone> is either
# an explicit IANA zone (--tz — the task stays pinned to that zone) or the
# literal sentinel `USER` (default — the task follows the CURRENT
# USER_TIMEZONE). Because the conversion happens once at scheduling time, a DST
# transition — or, for USER-tagged tasks, a USER_TIMEZONE change — leaves the
# stored system-frame fields an hour (or more) off. This job recomputes the
# system-frame fields from each entry's intent tag and rewrites any line that
# drifted, shrinking the drift window to at most one run.
#
# Only tagged #RECUR_ entries are touched. Untagged entries (pre-existing, or
# scheduled with --system-tz) are left exactly as-is. One-time #JOB_ entries are
# per-date exact and never tagged, so they are never touched. All line parsing
# goes through tz-lib's tz_parse_cron_line — the one parser for stored entries —
# so payload text that merely LOOKS like a tag can never be misread.
#
# Usage: ./tz-resync.sh            # rewrite drifted entries, reload supercronic
#        ./tz-resync.sh --dry-run  # report what would change, touch nothing
#
# Runs daily (scheduled with --no-inject --system-tz) and is also invoked by
# the update-location skill after USER_TIMEZONE changes. Safe to run
# repeatedly: a run with nothing to fix is a no-op.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# shellcheck source=/dev/null
source "$CLAUDE_HOME/core/tz-lib.sh"
if ! tz_load_zones; then
    echo "tz-resync: timezone resolution failed; nothing done." >&2
    exit 1
fi

# _resync_stream — read crontab-format lines on stdin, echo the (possibly
# rewritten) lines on stdout. Diagnostics go to stderr. Callers detect change
# by comparing output content with input — nothing is communicated through
# variables, so running inside a pipeline/subshell is safe.
_resync_stream() {
    local line zone newexpr rc f1 f2 f3 f4 f5 rest
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Only tagged recurring entries are candidates; pass everything else
        # (blank lines, comments, one-time jobs, untagged entries) through.
        if ! tz_parse_cron_line "$line" || [[ "$TZP_TYPE" != "recurring" || -z "$TZP_UF_CRON" ]]; then
            printf '%s\n' "$line"; continue
        fi
        # USER sentinel → the current USER_TIMEZONE (this is what re-anchors
        # default-zone tasks after an update-location change).
        zone=$(tz_resolve_tag_zone "$TZP_UF_ZONE")
        newexpr=$(tz_cron_convert "$zone" "$TZ_SYS" "$TZP_UF_CRON"); rc=$?
        if (( rc != 0 )); then
            printf '%s\n' "$line"; continue      # unconvertible — leave as-is
        fi
        if [[ "$newexpr" == "$TZP_EXPR" ]]; then
            printf '%s\n' "$line"                # already correct
        else
            echo "tz-resync: $TZP_ID '$TZP_EXPR' -> '$newexpr' (intent $TZP_UF_CRON @$TZP_UF_ZONE)" >&2
            read -r f1 f2 f3 f4 f5 rest <<< "$line"
            printf '%s %s\n' "$newexpr" "$rest"
        fi
    done
}

if tz_is_container; then
    CRONTAB_FILE="$CLAUDE_HOME/.crontab"
    LOCK_FILE="$CRONTAB_FILE.lock"
    [[ -f "$CRONTAB_FILE" ]] || { echo "tz-resync: no crontab; nothing to do."; exit 0; }

    # Compute the rewritten file under the lock, then, only if the content
    # changed, publish it with an in-place truncate+write (cat tmp > file) so
    # the inode is preserved — mv would change the inode and crash supercronic
    # -inotify. Change detection is by content comparison (cmp), surfaced to
    # the parent via the subshell's exit status.
    TMP="$CRONTAB_FILE.resync.$$"
    (
        flock 9
        _resync_stream < "$CRONTAB_FILE" > "$TMP"
        if ! cmp -s "$TMP" "$CRONTAB_FILE"; then
            if ! $DRY_RUN; then
                cat "$TMP" > "$CRONTAB_FILE"
            fi
            rm -f "$TMP"
            exit 0        # changed (or would change, in dry-run)
        fi
        rm -f "$TMP"
        exit 1            # unchanged
    ) 9>"$LOCK_FILE"
    changed=$?

    if (( changed == 0 )); then
        if $DRY_RUN; then
            echo "tz-resync: (dry-run) changes shown above; nothing written."
        else
            kill -USR2 "$(pgrep supercronic)" 2>/dev/null || true
            echo "tz-resync: rewrote drifted entries and reloaded supercronic."
        fi
    else
        echo "tz-resync: all recurring entries already correct."
    fi
else
    # VM: rewrite the user crontab in place. `crontab -` reinstalls atomically.
    # Change detection is by content comparison — _resync_stream runs inside a
    # command-substitution subshell, so no variable it sets could reach us here.
    command -v crontab &>/dev/null || { echo "tz-resync: no crontab command."; exit 0; }
    CURRENT=$(crontab -l 2>/dev/null) || CURRENT=""
    [[ -z "$CURRENT" ]] && { echo "tz-resync: empty crontab; nothing to do."; exit 0; }
    NEW=$(printf '%s\n' "$CURRENT" | _resync_stream)
    if [[ "$NEW" != "$CURRENT" ]]; then
        if $DRY_RUN; then
            echo "tz-resync: (dry-run) changes shown above; nothing written."
        else
            printf '%s\n' "$NEW" | crontab -
            echo "tz-resync: rewrote drifted entries in the user crontab."
        fi
    else
        echo "tz-resync: all recurring entries already correct."
    fi
fi
