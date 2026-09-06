#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# core/tz-lib.sh — sourceable timezone-conversion library.
#
# The scheduling scripts (schedule.sh, at-task.sh, list-tasks.sh, tz-resync.sh)
# own ALL timezone math so the LLM never has to. The storage invariant: every
# entry persisted to the crontab / `at` queue is in SYSTEM_TIMEZONE (the frame
# the scheduler interprets); conversion to/from USER_TIMEZONE happens only here,
# at the input/output boundary.
#
# Side-effect free: sourcing only defines functions. Conversion functions echo
# their result on stdout and send all diagnostics to stderr, so callers can
# safely capture output with $(...) or `read`.
#
# Two frames:
#   USER_TIMEZONE   — the user's wall clock (what they say times in).
#   SYSTEM_TIMEZONE — the scheduler frame (container: UTC; VM: host clock). The
#                     frame every stored cron/at entry is written in.
#
# GNU date does NOT fail on an unknown zone: it exits 0 and silently parses as
# UTC, which is exactly how "3am Asia/Singapore" once got scheduled as 03:00
# UTC. Every zone is therefore validated against /usr/share/zoneinfo before use.
#
# Return-code convention for the cron converters:
#   0  success (converted expression echoed)
#   1  hard error (invalid zone, unparseable time) — message on stderr
#   2  unconvertible: a "complex" expression (non-fixed minute/hour, a restricted
#      month, both DOM+DOW restricted, or a DOW/DOM that is not a single value).
#      Callers reject these and tell the user to pass --system-tz.
#
# Verify conversions manually after ANY change here (see the mechanical
# `TZ=... date -d ...` helper in CLAUDE.md "Scheduling").

# ---------------------------------------------------------------------------
# Zone resolution + validation
# ---------------------------------------------------------------------------

# tz_validate_zone <zone>
# 0 if the zone is UTC or exists in tzdata; 1 otherwise. Empty is invalid.
tz_validate_zone() {
    local z="$1"
    [[ -z "$z" ]] && return 1
    [[ "$z" == "UTC" ]] && return 0
    [[ -f "/usr/share/zoneinfo/$z" ]]
}

# _tz_clean <value>  — strip CR/LF/tab/space and surrounding quotes.
_tz_clean() {
    local v="$1"
    v="${v//[$'\r\n\t '\"\']/}"
    printf '%s' "$v"
}

# tz_is_container
# Single backend predicate shared by every scheduling script, so writers
# (schedule.sh, at-task.sh, delete-task.sh) and readers (list-tasks.sh,
# tz-resync.sh) can never disagree about which crontab a task lives in.
tz_is_container() {
    [[ "${CONTAINER:-}" == "true" || -f /.dockerenv ]]
}

# tz_load_zones [system-only]
# Resolve + validate both zones into the globals TZ_USER and TZ_SYS. Unset vars
# are filled from $CLAUDE_HOME/.env via core/env-loader.sh (the tolerant loader
# — quoted values, inline comments, and `export` prefixes all parse correctly;
# scripts invoked from cron/at may not have sourced .env). Sets
# TZ_USER_ASSUMED=1 when USER_TIMEZONE was unset (falls back to the system
# frame, with a warning). Returns 1 on an unresolvable/invalid zone (hard fail —
# never silently proceed to a UTC default that schedules the wrong instant).
#
# Pass "system-only" for code paths that never use the user zone (--system-tz):
# TZ_USER is set to TZ_SYS without validating USER_TIMEZONE, so a corrupt
# USER_TIMEZONE in .env cannot brick system-frame maintenance jobs.
tz_load_zones() {
    local mode="${1:-}"
    if [[ -z "${SYSTEM_TIMEZONE:-}" || ( -z "${USER_TIMEZONE:-}" && -z "${VM_TIMEZONE:-}" ) ]]; then
        if [[ -n "${CLAUDE_HOME:-}" && -r "$CLAUDE_HOME/core/env-loader.sh" ]]; then
            # shellcheck source=/dev/null
            source "$CLAUDE_HOME/core/env-loader.sh"
            load_env
        fi
    fi

    TZ_SYS=$(_tz_clean "${SYSTEM_TIMEZONE:-}")
    TZ_SYS="${TZ_SYS:-UTC}"
    if ! tz_validate_zone "$TZ_SYS"; then
        echo "tz-lib: SYSTEM_TIMEZONE '$TZ_SYS' is not a valid IANA zone (or tzdata is missing). Fix \$CLAUDE_HOME/.env or install tzdata." >&2
        return 1
    fi

    if [[ "$mode" == "system-only" ]]; then
        TZ_USER="$TZ_SYS"
        TZ_USER_ASSUMED=1
        return 0
    fi

    TZ_USER=$(_tz_clean "${USER_TIMEZONE:-${VM_TIMEZONE:-}}")
    TZ_USER_ASSUMED=0
    if [[ -z "$TZ_USER" ]]; then
        TZ_USER="$TZ_SYS"
        TZ_USER_ASSUMED=1
        echo "tz-lib: USER_TIMEZONE is unset — assuming times are in SYSTEM_TIMEZONE ('$TZ_SYS'). Set your location (update-location skill) for correct conversion." >&2
        return 0
    fi
    if ! tz_validate_zone "$TZ_USER"; then
        echo "tz-lib: USER_TIMEZONE '$TZ_USER' is not a valid IANA zone (or tzdata is missing). Fix \$CLAUDE_HOME/.env or install tzdata." >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Datetime conversion (one-time tasks) — per-date, so DST-exact.
# ---------------------------------------------------------------------------

# tz_datetime_convert <from_zone> <to_zone> "<YYYY-MM-DD HH:MM>" [<date_fmt>]
# Echo the same instant expressed in <to_zone>, formatted with <date_fmt>
# (default "+%Y-%m-%d %H:%M"). Returns 1 on invalid zone or unparseable input.
tz_datetime_convert() {
    local from="$1" to="$2" input="$3" fmt="${4:-+%Y-%m-%d %H:%M}" out
    if ! tz_validate_zone "$from"; then
        echo "tz-lib: invalid source zone '$from'" >&2; return 1
    fi
    if ! tz_validate_zone "$to"; then
        echo "tz-lib: invalid target zone '$to'" >&2; return 1
    fi
    # One-step conversion: parse INPUT as wall-clock in <from>, render in <to>.
    out=$(TZ="$to" date -d "TZ=\"$from\" $input" "$fmt" 2>/dev/null) || out=""
    if [[ -z "$out" ]]; then
        echo "tz-lib: could not parse datetime '$input'" >&2; return 1
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Cron-expression conversion (recurring tasks) — fixed minute+hour only.
# ---------------------------------------------------------------------------

# _tz_is_uint <str> — true if a bare non-negative integer (no +, no leading junk).
_tz_is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# tz_cron_convert <from_zone> <to_zone> "<min> <hour> <dom> <mon> <dow>"
# Echo the converted 5-field cron expression (in <to_zone>). Handles the day
# rollover a timezone shift can cause:
#   - daily  (dom=* dow=*)        : only min/hour change.
#   - weekly (dom=*, dow=<int>)   : min/hour + day-of-week shift.
#   - monthly(dom=<int>, dow=*)   : min/hour + day-of-month shift (rejected if it
#                                    would cross a month boundary: DOM<1 or >28).
# Returns 2 (unconvertible) for anything else — see the header's code table.
tz_cron_convert() {
    local from="$1" to="$2" expr="$3"
    if ! tz_validate_zone "$from" || ! tz_validate_zone "$to"; then
        echo "tz-lib: invalid zone in cron conversion ('$from' -> '$to')" >&2
        return 1
    fi

    # Split with `read` (not array expansion) so the '*' fields never trigger
    # pathname globbing. Reject anything that is not exactly 5 whitespace fields.
    local min hour dom mon dow extra
    read -r min hour dom mon dow extra <<< "$expr"
    if [[ -z "$dow" || -n "$extra" ]]; then
        echo "tz-lib: cron expression must have exactly 5 fields, got '${expr}'" >&2
        return 2
    fi

    # Minute + hour must be single fixed integers — the only reliably
    # convertible shape (a set of times can split across a midnight boundary).
    # 10# guards against octal misparse of leading-zero fields ('08', '09').
    if ! _tz_is_uint "$min" || (( 10#$min > 59 )); then return 2; fi
    if ! _tz_is_uint "$hour" || (( 10#$hour > 23 )); then return 2; fi
    min=$((10#$min)); hour=$((10#$hour))
    # Month restriction not supported (boundary math is unsafe); require '*'.
    [[ "$mon" == "*" ]] || return 2

    local dom_star=0 dow_star=0
    [[ "$dom" == "*" ]] && dom_star=1
    [[ "$dow" == "*" ]] && dow_star=1
    # Both restricted → cron ORs them; converting is ambiguous. Reject.
    if (( dom_star == 0 && dow_star == 0 )); then return 2; fi

    # Normalise / validate the single restricted day field.
    local want_dow=""
    if (( dow_star == 0 )); then
        _tz_is_uint "$dow" || return 2
        dow=$((10#$dow))
        (( dow > 7 )) && return 2
        (( dow == 7 )) && dow=0          # cron: 0 and 7 are both Sunday
        want_dow="$dow"
    fi
    if (( dom_star == 0 )); then
        _tz_is_uint "$dom" || return 2
        dom=$((10#$dom))
        (( dom < 1 || dom > 31 )) && return 2
    fi

    # Pick a reference calendar date in <from>:
    #   weekly  → the next date whose weekday matches want_dow (direct modular
    #             offset from today — the reference must be NEAR now so the
    #             zone's current DST offset applies).
    #   else    → today (offset is what matters, not the specific day).
    local ref today_from today_w
    today_from=$(TZ="$from" date "+%Y-%m-%d" 2>/dev/null) || today_from=""
    [[ -z "$today_from" ]] && { echo "tz-lib: date failed for zone '$from'" >&2; return 1; }
    if (( dow_star == 0 )); then
        today_w=$(TZ="$from" date "+%w" 2>/dev/null)
        ref=$(date -d "$today_from +$(( (want_dow - today_w + 7) % 7 )) day" "+%Y-%m-%d" 2>/dev/null)
        [[ -z "$ref" ]] && { echo "tz-lib: could not compute reference weekday" >&2; return 1; }
    else
        ref="$today_from"
    fi

    # Convert the instant (ref @ hour:min in <from>) into <to>.
    local hhmm epoch new_min new_hour from_ymd to_ymd
    hhmm=$(printf '%02d:%02d' "$hour" "$min")
    epoch=$(TZ="$from" date -d "$ref $hhmm" "+%s" 2>/dev/null) || epoch=""
    [[ -z "$epoch" ]] && { echo "tz-lib: could not build epoch for '$ref $hhmm' in '$from'" >&2; return 1; }
    new_min=$(TZ="$to" date -d "@$epoch" "+%-M" 2>/dev/null)
    new_hour=$(TZ="$to" date -d "@$epoch" "+%-H" 2>/dev/null)
    from_ymd="$ref"
    to_ymd=$(TZ="$to" date -d "@$epoch" "+%Y-%m-%d" 2>/dev/null)

    # Day delta ∈ {-1,0,+1} (offset < 24h). Compare pure dates in UTC to avoid
    # any tz effect on the bare-date parse.
    local d_from d_to delta
    d_from=$(date -u -d "$from_ymd" "+%s" 2>/dev/null)
    d_to=$(date -u -d "$to_ymd" "+%s" 2>/dev/null)
    delta=$(( (d_to - d_from) / 86400 ))

    local out_dom="$dom" out_dow="$dow"
    if (( dow_star == 0 )); then
        # The converted instant's weekday in <to> is the answer directly.
        out_dow=$(TZ="$to" date -d "@$epoch" "+%w" 2>/dev/null)
        out_dom="*"
    elif (( dom_star == 0 )); then
        local nd=$(( dom + delta ))
        # Refuse month-boundary rollover: DOM 0 / >28 can't be expressed safely
        # across variable-length months.
        if (( nd < 1 || nd > 28 )); then return 2; fi
        out_dom="$nd"
        out_dow="*"
    fi

    printf '%s %s %s %s %s\n' "$new_min" "$new_hour" "$out_dom" "*" "$out_dow"
}

# Convenience wrappers over the globals set by tz_load_zones. Call tz_load_zones
# (and check its status) first.
tz_cron_u2s() { tz_cron_convert "$TZ_USER" "$TZ_SYS" "$1"; }
tz_cron_s2u() { tz_cron_convert "$TZ_SYS" "$TZ_USER" "$1"; }
tz_dt_u2s()   { tz_datetime_convert "$TZ_USER" "$TZ_SYS" "$1"; }
tz_dt_s2u()   { tz_datetime_convert "$TZ_SYS" "$TZ_USER" "$1"; }

# ---------------------------------------------------------------------------
# Display helper
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stored-entry parsing — the ONE parser for TaskRamen-managed crontab lines.
# ---------------------------------------------------------------------------
# A managed line always ENDS with its comment: `#<RECUR|JOB>_<ts>_<rand>`,
# optionally followed by the intent tag ` UF=<cron5>@<zone>` (written only by
# schedule.sh). The task payload PRECEDES the comment and is arbitrary user
# text — it may contain strings like ' UF=', '#RECUR_1_2', or ' && flock ',
# so nothing here may match those substrings anywhere but at end-of-line.

# tz_parse_cron_line <line>
# Parse one crontab line into globals (return 1 if not a managed entry):
#   TZP_TYPE     "recurring" | "one-time"
#   TZP_ID       RECUR_<ts>_<rand> | JOB_<ts>_<rand>
#   TZP_EXPR     the 5 leading cron fields (whitespace-normalised)
#   TZP_PAYLOAD  the command portion, trailing comment stripped; for one-time
#                entries the ` && flock …` self-delete tail is stripped too
#                (last-occurrence match — the genuine tail always follows the
#                payload, so payload text containing ' && flock ' survives)
#   TZP_UF_CRON  intent-tag cron expression ('' when absent or corrupt)
#   TZP_UF_ZONE  intent-tag zone: an IANA name, or the literal sentinel `USER`
#                meaning "the CURRENT USER_TIMEZONE, whatever it now is"
tz_parse_cron_line() {
    local line="$1"
    TZP_TYPE=""; TZP_ID=""; TZP_EXPR=""; TZP_PAYLOAD=""; TZP_UF_CRON=""; TZP_UF_ZONE=""
    # End-anchored comment match. The UF tag's charset is strict ([0-9* ] cron
    # fields, [A-Za-z0-9_/+-] zone), so a look-alike token inside the payload
    # cannot satisfy the match through to $ (payload text after it — quotes,
    # spaces, the real comment's '#' — breaks the charset).
    if [[ ! "$line" =~ \#((RECUR|JOB)_[0-9]+_[0-9]+)(\ UF=([0-9* ]+)@([A-Za-z0-9_/+-]+))?[[:space:]]*$ ]]; then
        return 1
    fi
    TZP_ID="${BASH_REMATCH[1]}"
    [[ "$TZP_ID" == RECUR_* ]] && TZP_TYPE="recurring" || TZP_TYPE="one-time"

    # Validate the tag before trusting it: exactly 5 cron fields and a real
    # zone (or the USER sentinel). A corrupt tag degrades to "untagged".
    local ufcron="${BASH_REMATCH[4]:-}" ufzone="${BASH_REMATCH[5]:-}"
    if [[ -n "$ufcron" && -n "$ufzone" ]]; then
        local a b c d e extra
        read -r a b c d e extra <<< "$ufcron"
        if [[ -n "$e" && -z "$extra" ]] && { [[ "$ufzone" == "USER" ]] || tz_validate_zone "$ufzone"; }; then
            TZP_UF_CRON="$a $b $c $d $e"
            TZP_UF_ZONE="$ufzone"
        fi
    fi

    # Split: 5 cron fields, then the payload up to the trailing comment.
    local f1 f2 f3 f4 f5 rest
    read -r f1 f2 f3 f4 f5 rest <<< "$line"
    [[ -z "$f5" ]] && return 1
    TZP_EXPR="$f1 $f2 $f3 $f4 $f5"
    rest="${rest%"${BASH_REMATCH[0]}"}"        # strip the matched comment
    if [[ "$TZP_TYPE" == "one-time" ]]; then
        # Strip the self-delete tail at its LAST occurrence — it always comes
        # after the payload (at-task.sh appends it), so a payload containing
        # ' && flock ' is untouched.
        rest="${rest% && flock *}"
    fi
    # Trim trailing whitespace.
    TZP_PAYLOAD="${rest%"${rest##*[![:space:]]}"}"
    return 0
}

# tz_resolve_tag_zone <tag_zone>
# Map the intent-tag zone to a concrete zone: the USER sentinel resolves to the
# CURRENT $TZ_USER (call tz_load_zones first), anything else passes through.
# This is what makes a USER_TIMEZONE change re-anchor default-zone tasks while
# explicit --tz tasks stay pinned to the zone the user named.
tz_resolve_tag_zone() {
    if [[ "$1" == "USER" ]]; then printf '%s' "$TZ_USER"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------------------
# Next-fire computation — closed-form, no day-by-day scanning.
# ---------------------------------------------------------------------------

# tz_next_fire <system_frame_cron5> <display_zone>
# Echo the next fire instant of a stored (SYSTEM_TIMEZONE-frame) entry as
# "%a %Y-%m-%d %H:%M" in <display_zone>. Supports the shapes the stack writes
# (fixed min+hour; dom/mon/dow each '*' or a single integer) plus the cron
# dom-OR-dow rule when both are restricted. Echoes nothing (rc 0) for shapes
# it cannot compute — callers simply omit the "Next fire" line.
tz_next_fire() {
    local expr="$1" dzone="$2"
    local min hour dom mon dow extra
    read -r min hour dom mon dow extra <<< "$expr"
    [[ -z "$dow" || -n "$extra" ]] && return 0
    _tz_is_uint "$min" && _tz_is_uint "$hour" || return 0
    local nmin=$((10#$min)) nhour=$((10#$hour))
    [[ "$dom" == "*" ]] || _tz_is_uint "$dom" || return 0
    [[ "$mon" == "*" ]] || _tz_is_uint "$mon" || return 0
    [[ "$dow" == "*" ]] || _tz_is_uint "$dow" || return 0

    local now hhmm best=""
    now=$(date +%s)
    hhmm=$(printf '%02d:%02d' "$nhour" "$nmin")

    # Candidate 1 — day-of-week rule (dow restricted): next matching weekday,
    # stepping by whole weeks; honour a month restriction by stepping further
    # (bounded: 54 weeks covers every month).
    local epoch cand today_ymd today_w off i
    if [[ "$dow" != "*" ]]; then
        local ndow=$((10#$dow)); (( ndow == 7 )) && ndow=0
        today_ymd=$(TZ="$TZ_SYS" date "+%Y-%m-%d") || return 0
        today_w=$(TZ="$TZ_SYS" date "+%w")
        off=$(( (ndow - today_w + 7) % 7 ))
        for i in $(seq 0 54); do
            cand=$(date -d "$today_ymd +$(( off + i*7 )) day" "+%Y-%m-%d") || break
            [[ "$mon" != "*" && $((10#$mon)) -ne $((10#$(date -d "$cand" +%m))) ]] && continue
            epoch=$(TZ="$TZ_SYS" date -d "$cand $hhmm" "+%s" 2>/dev/null) || continue
            if (( epoch > now )); then best="$epoch"; break; fi
        done
    fi

    # Candidate 2 — day-of-month rule (dom restricted, or plain daily): try
    # this month then step months (61 = past the longest Feb-29 gap).
    if [[ "$dom" != "*" || "$dow" == "*" ]]; then
        local ndom ym m epoch2=""
        if [[ "$dom" == "*" ]]; then
            # Daily (with optional month restriction handled below via dom=today).
            epoch2=$(TZ="$TZ_SYS" date -d "today $hhmm" "+%s" 2>/dev/null)
            if [[ -n "$epoch2" ]] && (( epoch2 <= now )); then
                epoch2=$(TZ="$TZ_SYS" date -d "tomorrow $hhmm" "+%s" 2>/dev/null)
            fi
            # Month-restricted daily: step days until the month matches (≤366).
            if [[ "$mon" != "*" && -n "$epoch2" ]]; then
                for i in $(seq 0 366); do
                    cand=$(TZ="$TZ_SYS" date -d "@$((epoch2 + i*86400))" "+%Y-%m-%d") || break
                    if [[ $((10#$mon)) -eq $((10#$(date -d "$cand" +%m))) ]]; then
                        epoch2=$(TZ="$TZ_SYS" date -d "$cand $hhmm" "+%s" 2>/dev/null)
                        break
                    fi
                    [[ $i == 366 ]] && epoch2=""
                done
            fi
        else
            ndom=$((10#$dom))
            for m in $(seq 0 61); do
                ym=$(date -d "$(TZ="$TZ_SYS" date +%Y-%m-15) +$m month" "+%Y-%m") || break
                [[ "$mon" != "*" && $((10#$mon)) -ne $((10#${ym#*-})) ]] && continue
                # date -d fails on impossible dates (Feb 30) — skip that month.
                epoch2=$(TZ="$TZ_SYS" date -d "$ym-$(printf '%02d' "$ndom") $hhmm" "+%s" 2>/dev/null) || { epoch2=""; continue; }
                # Guard normalisation (some date builds roll 2026-02-30 over).
                [[ "$(TZ="$TZ_SYS" date -d "@$epoch2" +%-d)" == "$ndom" ]] || { epoch2=""; continue; }
                (( epoch2 > now )) && break
                epoch2=""
            done
        fi
        if [[ -n "$epoch2" ]] && (( epoch2 > now )); then
            # cron ORs dom and dow when both are restricted → earlier one wins.
            if [[ -z "$best" ]] || (( epoch2 < best )); then best="$epoch2"; fi
        fi
    fi

    [[ -z "$best" ]] && return 0
    TZ="$dzone" date -d "@$best" "+%a %Y-%m-%d %H:%M"
}

# tz_cron_describe "<min> <hour> <dom> <mon> <dow>"
# Best-effort plain-English phrase for the common shapes; echoes the raw
# expression otherwise. Time-only, zone-agnostic (caller appends the zone).
tz_cron_describe() {
    local min hour dom mon dow extra
    read -r min hour dom mon dow extra <<< "$1"
    [[ -z "$dow" || -n "$extra" ]] && { printf '%s' "$1"; return; }
    if ! _tz_is_uint "$min" || ! _tz_is_uint "$hour"; then printf '%s' "$1"; return; fi
    # 10# strips leading zeros — printf %02d would otherwise choke on '08'/'09'
    # (invalid octal), and arithmetic would misparse them.
    local hhmm; hhmm=$(printf '%02d:%02d' "$((10#$hour))" "$((10#$min))")
    if [[ "$mon" == "*" && "$dom" == "*" && "$dow" == "*" ]]; then
        printf 'daily %s' "$hhmm"; return
    fi
    if [[ "$mon" == "*" && "$dom" == "*" ]] && _tz_is_uint "$dow" && (( 10#$dow <= 7 )); then
        local names=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday Sunday)
        printf 'weekly %s %s' "${names[$((10#$dow))]}" "$hhmm"; return
    fi
    if [[ "$mon" == "*" && "$dow" == "*" ]] && _tz_is_uint "$dom"; then
        printf 'monthly day %s %s' "$((10#$dom))" "$hhmm"; return
    fi
    printf '%s' "$1"
}
