#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Delete a scheduled task by ID (JOB_xxx or RECUR_xxx).
# Usage: ./delete-task.sh <TASK_ID>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

if [ "$#" -ne 1 ]; then
    echo "Usage: ./delete-task.sh <TASK_ID>"
    echo "Example: ./delete-task.sh JOB_1714000000_12345"
    echo "Example: ./delete-task.sh RECUR_1714000000_12345"
    exit 1
fi

TASK_ID="$1"

# Validate the ID shape before splicing it into a grep pattern: a system-
# generated ID only ever looks like RECUR_<ts>_<rand> or JOB_<ts>_<rand>.
# Anything else is either a typo or regex-significant text — reject both.
if [[ ! "$TASK_ID" =~ ^(RECUR|JOB)_[0-9]+_[0-9]+$ ]]; then
    echo "Error: '$TASK_ID' is not a valid task ID (expected RECUR_<ts>_<n> or JOB_<ts>_<n>)."
    exit 1
fi

# Match the ID only in its trailing-comment position: '#<ID>' at end-of-line,
# optionally followed by the UF= intent tag (which never contains '#'). This is
# anchored so an ID that is a PREFIX of another (RECUR_x_1 vs RECUR_x_12), or an
# ID mentioned inside another task's prompt text (always mid-line — the real
# comment follows it), cannot be deleted by mistake.
ID_RE="#${TASK_ID}( UF=[^#]*)?\$"

# Shared backend predicate (core/tz-lib.sh) so delete reads the same crontab
# that schedule.sh/at-task.sh wrote to.
# shellcheck source=/dev/null
source "$CLAUDE_HOME/core/tz-lib.sh"

if tz_is_container; then
    # Container mode: remove from .crontab file (supercronic)
    CRONTAB_FILE="$CLAUDE_HOME/.crontab"
    LOCK_FILE="$CRONTAB_FILE.lock"

    if [ ! -f "$CRONTAB_FILE" ]; then
        echo "Error: Crontab file not found: $CRONTAB_FILE"
        exit 1
    fi

    # Validate the ID exists before deleting
    if ! grep -qE "$ID_RE" "$CRONTAB_FILE"; then
        echo "Error: Task ID '$TASK_ID' not found in $CRONTAB_FILE"
        exit 1
    fi

    # Use flock for safe concurrent access; rewrite in-place to preserve inode (supercronic -inotify)
    # "|| :" after grep ensures success even when deleting the last entry (grep -v exits 1 if no lines remain)
    # "cat tmp > file" preserves the original inode (truncate + write, no rename)
    if ! flock "$LOCK_FILE" sh -c "grep -vE \"$ID_RE\" '$CRONTAB_FILE' > '$CRONTAB_FILE.tmp' || :; cat '$CRONTAB_FILE.tmp' > '$CRONTAB_FILE'; rm -f '$CRONTAB_FILE.tmp'"; then
        echo "Error: Failed to update crontab (flock failed)"
        exit 1
    fi

    # Belt-and-suspenders: signal supercronic to reload
    kill -USR2 $(pgrep supercronic) 2>/dev/null || true

    echo "Success! Task '$TASK_ID' deleted from crontab."
else
    # VM mode: remove from system crontab
    if ! crontab -l 2>/dev/null | grep -qE "$ID_RE"; then
        echo "Error: Task ID '$TASK_ID' not found in crontab"
        exit 1
    fi

    crontab -l 2>/dev/null | grep -vE "$ID_RE" | crontab -

    echo "Success! Task '$TASK_ID' deleted from crontab."
fi
