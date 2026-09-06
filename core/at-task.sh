#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Schedule a one-time task.
# Usage: ./at-task.sh [--no-inject] [--tz <zone>|--system-tz] '<YYYY-MM-DD HH:MM>' '<task prompt>'
# By DEFAULT the time is interpreted in USER_TIMEZONE (the user's wall clock) and
# converted to SYSTEM_TIMEZONE — the frame the scheduler interprets entries in
# (container: UTC; VM: the host's /etc/localtime) — by core/tz-lib.sh. The stored
# entry is always SYSTEM_TIMEZONE (the storage frame — see core/tz-lib.sh). Claude
# passes the time exactly as the user said it; no manual conversion.
# In container mode: writes a self-deleting cron line to $CLAUDE_HOME/.crontab (supercronic).
# In VM mode: uses the `at` command.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# Flags (any leading order):
#   --no-inject   schedule a raw command (trusted internal script path) DIRECTLY,
#                 without the inject.sh prompt wrapper. Symmetric with schedule.sh.
#   --system-tz   the input time is ALREADY in SYSTEM_TIMEZONE — no conversion.
#                 Used by internal --no-inject callers and for raw scheduler-frame
#                 input.
#   --tz <zone>   interpret the input in <zone> instead of USER_TIMEZONE.
NO_INJECT=false
SYSTEM_TZ_MODE=false
INPUT_TZ=""
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --no-inject) NO_INJECT=true; shift ;;
        --system-tz) SYSTEM_TZ_MODE=true; shift ;;
        --tz)
            # A missing value must error, not loop: `shift 2` with $#==1 fails
            # WITHOUT shifting, which would spin this loop forever.
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                echo "Error: --tz requires a timezone value (e.g. --tz America/New_York)."
                exit 1
            fi
            INPUT_TZ="$2"; shift 2 ;;
        --tz=*)      INPUT_TZ="${1#--tz=}"; shift ;;
        --)          shift; break ;;
        *)           echo "Error: unknown flag '$1'"; exit 1 ;;
    esac
done

if $SYSTEM_TZ_MODE && [[ -n "$INPUT_TZ" ]]; then
    echo "Error: --tz and --system-tz are mutually exclusive."
    exit 1
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: ./at-task.sh [--no-inject] [--tz <zone>|--system-tz] '<YYYY-MM-DD HH:MM>' '<task_prompt_or_command>'"
    echo "  Time is interpreted in USER_TIMEZONE by default (--tz to override, --system-tz for raw scheduler-frame input)."
    echo "Example: ./at-task.sh '2026-04-10 09:00' 'Check flight prices for HKG'"
    echo "Example: ./at-task.sh --no-inject --system-tz '2026-04-10 01:00' '\$CLAUDE_HOME/core/nightly-review.sh'"
    exit 1
fi

INPUT_TIME="$1"
TASK="$2"

# tz-lib owns zone resolution/validation and all conversion. It fails loudly on
# an unresolvable zone (GNU date silently parses unknown zones as UTC, which
# would schedule the task at the wrong absolute time). --system-tz paths only
# need SYSTEM_TIMEZONE, so a corrupt USER_TIMEZONE cannot brick them.
# shellcheck source=/dev/null
source "$CLAUDE_HOME/core/tz-lib.sh"
if $SYSTEM_TZ_MODE; then
    TZ_LOAD_MODE="system-only"
else
    TZ_LOAD_MODE=""
fi
if ! tz_load_zones $TZ_LOAD_MODE; then
    echo "Error: timezone resolution failed — fix SYSTEM_TIMEZONE/USER_TIMEZONE in $CLAUDE_HOME/.env or install tzdata."
    exit 1
fi
SYSTEM_TIMEZONE="$TZ_SYS"

# Convert the input time into SYSTEM_TIMEZONE (the storage frame) unless it is
# already system-frame. INPUT_ZONE is remembered for the user-facing echo.
if $SYSTEM_TZ_MODE; then
    INPUT_ZONE="$TZ_SYS"
else
    INPUT_ZONE="${INPUT_TZ:-$TZ_USER}"
    if ! tz_validate_zone "$INPUT_ZONE"; then
        echo "Error: invalid timezone '$INPUT_ZONE'."
        exit 1
    fi
    CONVERTED=$(tz_datetime_convert "$INPUT_ZONE" "$TZ_SYS" "$INPUT_TIME") || {
        echo "Error: could not parse datetime '$INPUT_TIME'. Use format: YYYY-MM-DD HH:MM (in ${INPUT_ZONE})"
        exit 1
    }
    INPUT_TIME="$CONVERTED"
fi

# Build the command payload that gets spliced into the cron/at line.
# - PAYLOAD_CRON: supercronic-bound (container) — % must be \%-escaped.
# - PAYLOAD_AT:   `at`-bound (VM) — no % quirk; \% would arrive literal.
if $NO_INJECT; then
    # Raw command mode: run the command directly, no inject.sh wrapper, no
    # prompt sanitisation/quoting (it is a trusted internal command, not user
    # text). Collapse newlines so the line stays single-line. Same payload for
    # both backends — a bare command has no % to escape.
    CMD="${TASK//$'\n'/ }"
    CMD="${CMD//$'\r'/ }"
    PAYLOAD_CRON="$CMD"
    PAYLOAD_AT="$CMD"
else
    # --- Sanitise $TASK before embedding in a cron/at command line ---
    # Container path feeds supercronic, which has cron's % = newline-to-stdin
    # behaviour and splits on real \n. VM path feeds `at`, which has no %
    # quirk but still passes the line to /bin/sh. Both paths suffer shell
    # expansion of $ ` \ " inside double-quoted wrappers.
    # Strategy: strip newlines, wrap in single quotes (neutralises shell
    # expansion; embedded ' becomes '\''), then for the cron-bound variant
    # escape % as \% so supercronic strips the backslash and the shell sees
    # a literal %. Order: newlines -> quote-wrap -> %-escape.
    # IMPORTANT: use $QUOTED_TASK on the `at` path — \% inside single quotes
    # is literal \%, which would corrupt the prompt. Only $CRON_TASK gets
    # the % escape, only on the supercronic path.
    SANITISED_TASK="${TASK//$'\n'/ }"
    SANITISED_TASK="${SANITISED_TASK//$'\r'/ }"
    QUOTED_TASK="'${SANITISED_TASK//\'/\'\\\'\'}'"
    CRON_TASK="${QUOTED_TASK//%/\\%}"
    PAYLOAD_CRON="$CLAUDE_HOME/core/inject.sh $CRON_TASK --no-telegram"
    PAYLOAD_AT="$CLAUDE_HOME/core/inject.sh $QUOTED_TASK --no-telegram"
fi

# Validate and extract components from the input (interpreted in SYSTEM_TIMEZONE)
SCHED_TIME=$(TZ="$SYSTEM_TIMEZONE" date -d "$INPUT_TIME" "+%Y-%m-%d %H:%M" 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$SCHED_TIME" ]; then
    echo "Error: Could not parse datetime '$INPUT_TIME'. Use format: YYYY-MM-DD HH:MM (in SYSTEM_TIMEZONE)"
    exit 1
fi

# Extract minute, hour, day, month (in SYSTEM_TIMEZONE) for the cron expression
SCHED_MIN=$(TZ="$SYSTEM_TIMEZONE" date -d "$INPUT_TIME" "+%-M" 2>/dev/null)
SCHED_HOUR=$(TZ="$SYSTEM_TIMEZONE" date -d "$INPUT_TIME" "+%-H" 2>/dev/null)
SCHED_DAY=$(TZ="$SYSTEM_TIMEZONE" date -d "$INPUT_TIME" "+%-d" 2>/dev/null)
SCHED_MON=$(TZ="$SYSTEM_TIMEZONE" date -d "$INPUT_TIME" "+%-m" 2>/dev/null)

# User-facing time: the stored system-frame instant rendered back in the input
# zone, with a weekday anchor. This is the line Claude quotes to the user.
DISPLAY_TIME=$(tz_datetime_convert "$SYSTEM_TIMEZONE" "$INPUT_ZONE" "$SCHED_TIME" "+%a %Y-%m-%d %H:%M" 2>/dev/null)
[[ -z "$DISPLAY_TIME" ]] && DISPLAY_TIME="$SCHED_TIME"

if tz_is_container; then
    # Container mode: write self-deleting cron line to .crontab (supercronic)
    CRONTAB_FILE="$CLAUDE_HOME/.crontab"
    touch "$CRONTAB_FILE" 2>/dev/null || true

    JOB_ID="JOB_$(date +%s)_${RANDOM}"
    CRON_EXPR="$SCHED_MIN $SCHED_HOUR $SCHED_DAY $SCHED_MON *"
    LOCK_FILE="$CRONTAB_FILE.lock"
    # Self-deleting cron line: grep -vE removes this job, rewrites in-place to preserve inode.
    # In-place rewrite avoids supercronic -inotify crash (mv changes inode → fsnotify Remove → fatal).
    # "|| :" after grep handles the edge case where this is the last entry (grep -v exits 1 if no lines remain).
    # kill -USR2 as belt-and-suspenders fallback for reload.
    # $PAYLOAD_CRON is either the inject.sh wrapper (single-quote-wrapped,
    # %-escaped) or, with --no-inject, the raw command (see above).
    # $JOB_ID is system-generated (JOB_<ts>_<rand>) — no special chars, safe to splice.
    # The self-delete pattern '#<ID>$' is EOL-anchored so it can only ever match
    # this entry's own trailing comment — never a prefix-sharing ID or an ID
    # mentioned mid-line inside another task's prompt text.
    CRON_LINE="$CRON_EXPR $PAYLOAD_CRON && flock $LOCK_FILE sh -c \"grep -vE '#$JOB_ID\$' $CRONTAB_FILE > $CRONTAB_FILE.tmp || :; cat $CRONTAB_FILE.tmp > $CRONTAB_FILE; rm -f $CRONTAB_FILE.tmp\" && kill -USR2 \$(pgrep supercronic) 2>/dev/null #$JOB_ID"

    printf '%s\n' "$CRON_LINE" | flock "$LOCK_FILE" tee -a "$CRONTAB_FILE" >/dev/null
    kill -USR2 $(pgrep supercronic) 2>/dev/null || true

    echo "Success! One-time task scheduled."
    echo "  Scheduled: $DISPLAY_TIME $INPUT_ZONE"
    echo "  (stored $SYSTEM_TIMEZONE: $SCHED_TIME)"
    echo "  Job ID: $JOB_ID"
    echo "  Cancel: $CLAUDE_HOME/core/delete-task.sh $JOB_ID"
else
    # VM mode: use system 'at' command
    if ! command -v at &>/dev/null; then
        echo "Error: 'at' is not installed. Run: sudo apt-get install -y at"
        exit 1
    fi

    AT_TIME=$(TZ="$SYSTEM_TIMEZONE" date -d "$INPUT_TIME" "+%H:%M %Y-%m-%d" 2>/dev/null)
    # $PAYLOAD_AT is either the inject.sh wrapper (using $QUOTED_TASK, no %
    # escape — `at` has no cron % quirk) or, with --no-inject, the raw command.
    # Parse the time under SYSTEM_TIMEZONE so `at` resolves the correct absolute
    # instant regardless of the host clock.
    JOB_OUTPUT=$(echo "$PAYLOAD_AT" | TZ="$SYSTEM_TIMEZONE" at $AT_TIME 2>&1)
    JOB_ID=$(echo "$JOB_OUTPUT" | grep -oP 'job \K[0-9]+')

    echo "Success! One-time task scheduled."
    echo "  Scheduled: $DISPLAY_TIME $INPUT_ZONE"
    echo "  (stored $SYSTEM_TIMEZONE: $SCHED_TIME)"
    echo "  Job ID: $JOB_ID (cancel with: atrm $JOB_ID)"
fi
