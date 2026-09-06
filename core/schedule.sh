#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Determine CLAUDE_HOME dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# --no-inject: schedule a raw command (a trusted internal script path) to run
# DIRECTLY from cron/supercronic, without wrapping it in inject.sh. Used for
# maintenance jobs like core/nightly-review.sh that are scripts, not prompts
# (they restart the session + Chrome and inject any review into the live session
# themselves) and so must not be delivered as a prompt through inject.sh.
# Whether to add the entry
# (e.g. avoiding duplicates) is the caller's decision, not schedule.sh's.
# Flags (any leading order):
#   --no-inject   schedule a raw command directly (no inject.sh prompt wrapper).
#   --tz <zone>   interpret the cron expression in <zone> (a valid IANA name)
#                 instead of USER_TIMEZONE. Use when the user names a different
#                 zone ("9am New York time"). The DST-resync intent tag records
#                 <zone>, so the task follows THAT zone's DST, not the user's.
#   --system-tz   the cron expression is ALREADY in SYSTEM_TIMEZONE — write it
#                 verbatim, no conversion and no DST-resync intent tag. Use this
#                 for advanced expressions tz-lib can't convert automatically.
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

if [ "$#" -ne 2 ]; then
    echo "Usage: ./schedule.sh [--no-inject] [--tz <zone>|--system-tz] '<cron_schedule>' '<task_prompt_or_command>'"
    echo "  The cron schedule is interpreted in USER_TIMEZONE by default (--tz <IANA zone>"
    echo "  to override) and converted to the scheduler frame; --system-tz writes it"
    echo "  verbatim in SYSTEM_TIMEZONE."
    echo "Example: ./schedule.sh '0 9 * * *' 'Check my unread emails and summarize them'"
    echo "Example: ./schedule.sh --tz America/New_York '0 9 * * 1' 'NY market open note'"
    echo "Example: ./schedule.sh --no-inject '0 3 * * *' '\$CLAUDE_HOME/core/nightly-review.sh'"
    exit 1
fi

if $SYSTEM_TZ_MODE && [[ -n "$INPUT_TZ" ]]; then
    echo "Error: --tz and --system-tz are mutually exclusive."
    exit 1
fi

CRON_EXPR="$1"
TASK="$2"

RECUR_ID="RECUR_$(date +%s)_${RANDOM}"

# --- Timezone conversion (core/tz-lib.sh owns all of it) -------------------
# By default the cron expression is in USER_TIMEZONE (--tz <zone> overrides);
# convert it to the scheduler frame (SYSTEM_TIMEZONE) for storage and append an
# intent tag so core/tz-resync.sh keeps the task anchored to the intended wall
# clock across DST. The tag zone is the literal sentinel `USER` for default
# (user-zone) tasks — resync resolves it to the CURRENT USER_TIMEZONE, so a
# location change re-anchors them — or the explicit --tz zone, which pins the
# task to that zone permanently. --system-tz skips conversion and tagging
# (verbatim system-frame entry); it only needs SYSTEM_TIMEZONE to be valid, so
# a corrupt USER_TIMEZONE cannot brick system-frame maintenance jobs.
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

INTENT_TAG=""          # appended after #$RECUR_ID; empty ⇒ never resynced
INPUT_ZONE="$TZ_USER"  # zone the schedule is interpreted in (may be overridden)
if $SYSTEM_TZ_MODE; then
    STORE_EXPR="$CRON_EXPR"
    INPUT_ZONE="$TZ_SYS"
else
    # Resolve + validate the input zone (fail loudly — GNU date would otherwise
    # silently treat an unknown zone as UTC and schedule the wrong instant).
    INPUT_ZONE="${INPUT_TZ:-$TZ_USER}"
    if ! tz_validate_zone "$INPUT_ZONE"; then
        echo "Error: invalid timezone '$INPUT_ZONE' — pass a valid IANA zone name (e.g. America/New_York, Asia/Singapore)."
        exit 1
    fi
    STORE_EXPR=$(tz_cron_convert "$INPUT_ZONE" "$TZ_SYS" "$CRON_EXPR"); TZ_RC=$?
    if (( TZ_RC == 2 )) && [[ "$INPUT_ZONE" == "$TZ_SYS" ]]; then
        # Identity frame: a complex expression needs no conversion — store it
        # verbatim. No intent tag (resync can't recompute complex shapes).
        STORE_EXPR="$CRON_EXPR"
        TZ_RC=0
    elif (( TZ_RC == 2 )); then
        echo "Error: cron schedule '$CRON_EXPR' is too complex to convert automatically."
        echo "  Automatic conversion supports a fixed minute and hour (e.g. '0 9 * * *',"
        echo "  '30 8 * * 1', '0 9 15 * *'). For anything else, pass a schedule already in"
        echo "  SYSTEM_TIMEZONE ($TZ_SYS) with --system-tz."
        exit 1
    elif (( TZ_RC != 0 )); then
        echo "Error: could not convert cron schedule '$CRON_EXPR' from $INPUT_ZONE to $TZ_SYS."
        exit 1
    else
        # Tag with the intent zone: explicit --tz pins to that zone; default
        # records the USER sentinel so the task follows the user's wall clock
        # (including when USER_TIMEZONE was assumed/unset — once the user sets
        # a real zone, the next resync re-anchors the task to it).
        if [[ -n "$INPUT_TZ" ]]; then
            INTENT_TAG=" UF=${CRON_EXPR}@${INPUT_TZ}"
        else
            INTENT_TAG=" UF=${CRON_EXPR}@USER"
        fi
    fi
fi

if $NO_INJECT; then
    # Raw command mode: run the command directly, no inject.sh wrapper and no
    # prompt sanitisation/quoting (it is a trusted internal command, not user
    # text). Collapse any newlines so the cron entry stays single-line.
    CMD="${TASK//$'\n'/ }"
    CMD="${CMD//$'\r'/ }"
    CRON_LINE="$STORE_EXPR $CMD #$RECUR_ID$INTENT_TAG"
else
    # --- Sanitise $TASK for safe embedding in a cron line read by supercronic ---
    # At fire time the line is parsed by TWO layers: (1) supercronic, which treats
    # unescaped % as newline-to-stdin and a literal \n as an entry separator;
    # (2) /bin/sh, which expands $VAR, `cmd`, $(cmd) and treats \ " as syntax.
    # Strategy: replace newlines with spaces (cron entries are single-line),
    # wrap the task in single quotes (kills all shell expansion in one move,
    # with '\'' for embedded apostrophes), then escape % as \% so supercronic
    # strips the backslash and the shell sees a literal % inside the quotes.
    # Order is load-bearing: newlines -> quote-wrap -> %-escape.
    SANITISED_TASK="${TASK//$'\n'/ }"
    SANITISED_TASK="${SANITISED_TASK//$'\r'/ }"
    QUOTED_TASK="'${SANITISED_TASK//\'/\'\\\'\'}'"
    CRON_TASK="${QUOTED_TASK//%/\\%}"

    # $CRON_TASK already includes its own single-quote wrapping — do NOT add quotes around it.
    CRON_LINE="$STORE_EXPR $CLAUDE_HOME/core/inject.sh $CRON_TASK --no-telegram #$RECUR_ID$INTENT_TAG"
fi

if tz_is_container; then
    # Container mode: write directly to .crontab file (supercronic)
    CRONTAB_FILE="$CLAUDE_HOME/.crontab"
    LOCK_FILE="$CRONTAB_FILE.lock"
    touch "$CRONTAB_FILE" 2>/dev/null || true
    printf '%s\n' "$CRON_LINE" | flock "$LOCK_FILE" tee -a "$CRONTAB_FILE" >/dev/null
    kill -USR2 $(pgrep supercronic) 2>/dev/null || true
else
    # VM mode: use system crontab. The cron daemon (cronie/Vixie) interprets
    # these entries in the host's local timezone, i.e. SYSTEM_TIMEZONE (the
    # scheduler frame — see install/deps.sh _detect_system_timezone), which is
    # exactly the frame $STORE_EXPR is written in. No CRON_TZ override, so the
    # user's other crontab entries are left untouched.
    (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
fi

# Confirm in the input zone — the line Claude quotes back to the user. The
# zone label always names the frame the expression was INTERPRETED in (even
# when the conversion happened to be an identity, e.g. London winter vs UTC).
echo "Success! Recurring task scheduled."
echo "  Schedule: $(tz_cron_describe "$CRON_EXPR") $INPUT_ZONE"
[[ "$STORE_EXPR" != "$CRON_EXPR" ]] && echo "  (stored $TZ_SYS: $STORE_EXPR)"
echo "  Task ID: $RECUR_ID"
