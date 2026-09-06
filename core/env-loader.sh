#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# core/env-loader.sh — tolerant .env loader. Side-effect free: only defines
# functions, so it is safe to source from anywhere.
#
# Why this exists: .env used to be read with `set -a; source .env; set +a`, i.e.
# the file was EXECUTED as shell. Any value containing a space, '$', backtick or
# an unbalanced quote then either ran as a command or, under `set -e`, aborted
# the caller. In the container that killed PID 1 at boot and crash-looped via
# --restart=unless-stopped. The canonical trigger is SERVICE_GOOGLE_WORKSPACE_RW_SCOPES,
# a space-separated OAuth scope list — space-delimited is the CORRECT OAuth form
# (RFC 6749 §3.3); the bug was storing it unquoted in a sourced file. See
# TaskRamenInstaller#118 and issue #387.
#
# load_env_file reads KEY=VALUE pairs LITERALLY — everything after the first '='
# is the value; no expansion, no command execution — and exports them (matching
# the old `set -a` behaviour). It strips one surrounding pair of matching quotes
# and a trailing CR, skips full-line comments / blanks / a leading `export `, and
# ignores lines whose key is not a valid shell identifier (so a commented-out key
# stays unset exactly as `source` would leave it). It also strips an INLINE
# `# comment` the way `source` / python-dotenv do — but only when the `#` is
# OUTSIDE quotes AND preceded by whitespace; a `#` inside quotes, or glued to
# non-whitespace with no space before it, stays in the value. So a value that must
# contain a `#` is preserved by quoting it (`KEY="a#b"`) or writing it with no
# preceding space (`KEY=a#b`) — see storingsecrets.md §1 and issue #27. It NEVER
# returns non-zero, so it can never abort a caller running under `set -e`.
#
# Invariants to preserve on ANY change here: values, keys, quoting,
# shell-special chars, and the never-abort safety promise.

# load_env_file <path>
load_env_file() {
    local _f="${1:-}" _line _key _val _rest _lead_ws
    # Require a readable regular file. The -r guard matters under `set -e`: an
    # unreadable file would make the `done < "$_f"` redirect below fail and
    # abort the caller — exactly what this loader promises never to do.
    [[ -n "$_f" && -f "$_f" && -r "$_f" ]] || return 0
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        # Trim leading whitespace.
        _line="${_line#"${_line%%[![:space:]]*}"}"
        # Skip blanks and comments.
        [[ -z "$_line" || "$_line" == '#'* ]] && continue
        # Tolerate a leading `export` prefix followed by any whitespace (one or
        # more spaces/tabs); the key ltrim below removes the remaining gap.
        [[ "$_line" == export[[:space:]]* ]] && _line="${_line#export}"
        # Must be KEY=VALUE.
        [[ "$_line" != *=* ]] && continue
        _key="${_line%%=*}"
        _val="${_line#*=}"
        # Trim leading and trailing whitespace from the key (leading handles a
        # multi-space `export   KEY=...`, where stripping `export ` above leaves
        # spaces in front of the key that the identifier regex would reject).
        _key="${_key#"${_key%%[![:space:]]*}"}"
        _key="${_key%"${_key##*[![:space:]]}"}"
        # Only accept valid shell identifiers; ignore anything else.
        [[ "$_key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # Strip a trailing CR (CRLF files).
        _val="${_val%$'\r'}"
        # Was there whitespace between `=` and the first non-space char? This is
        # what disambiguates a leading `#`: `KEY= #x` (space then '#') is a pure
        # comment ⇒ empty value, but `KEY=#x` (glued) is the literal value '#x'.
        _lead_ws=0; [[ "$_val" == [[:space:]]* ]] && _lead_ws=1
        # Trim leading whitespace so we can inspect the first real character
        # (matches how `source` ignores space after `=`).
        _val="${_val#"${_val%%[![:space:]]*}"}"
        # Parse the value, stripping an inline `# comment` exactly the way
        # `source` / python-dotenv do: a '#' is a comment delimiter ONLY when it
        # is outside quotes AND preceded by whitespace. A '#' inside quotes, or
        # glued to non-whitespace, is literal data. A '#' anywhere inside the
        # comment text (`KEY=v  # has a # in it`) is harmless — the value is
        # already fixed by the rules below before the comment is dropped.
        #
        # Two deliberate divergences from a real shell `source` (both rare and
        # OUTSIDE the storingsecrets.md convention, so harmless in practice):
        #   1. Escaped quotes inside a quoted value are NOT unescaped. `KEY="a\"b"`
        #      loads as `a\` (cut at the first inner '"'), not `a"b`. The convention
        #      never needs an escaped quote inside a value, and write_env never
        #      emits one. Quotes appearing in the trailing COMMENT are fine.
        #   2. Text glued AFTER a closing quote is dropped, not concatenated.
        #      `KEY="ab"cd` loads as `ab` (not `abcd`); `KEY="a" "b"` loads as `a`.
        #      The convention always wraps the whole value in ONE quote pair.
        if   [[ "$_val" == '"'* ]]; then
            # Double-quoted: value is the text up to the NEXT '"'; anything after
            # it (whitespace + optional comment, which may itself contain '"' or
            # '#') is dropped. No closing quote ⇒ leave the raw value untouched
            # rather than corrupt it.
            _rest="${_val#\"}"
            [[ "$_rest" == *'"'* ]] && _val="${_rest%%\"*}"
        elif [[ "$_val" == "'"* ]]; then
            # Single-quoted: symmetric — text up to the NEXT "'". Spaces / '#'
            # inside are preserved; a quote or '#' in the trailing comment is
            # dropped with it. NOTE: shell's `'\''` apostrophe-escape idiom is
            # NOT decoded (this is a literal loader, not a shell), so a value
            # written by write_env that contained a "'" does not round-trip; such
            # values effectively never occur (see write_env in install/utils.sh).
            _rest="${_val#\'}"
            [[ "$_rest" == *"'"* ]] && _val="${_rest%%\'*}"
        else
            # Unquoted. A leading '#' is a comment only if a space preceded it.
            [[ "$_val" == '#'* && "$_lead_ws" == 1 ]] && _val=""
            # Cut at the first whitespace-preceded '#' (a '#' with no space before
            # it stays in the value), then rtrim trailing whitespace.
            _val="${_val%%[[:space:]]#*}"
            _val="${_val%"${_val##*[![:space:]]}"}"
        fi
        # Export literally — $_key is a validated identifier and $_val is data,
        # so nothing in the value is expanded or executed.
        export "$_key=$_val"
    done < "$_f"
    return 0
}

# load_env — convenience: load $CLAUDE_HOME/.env if present. Never fails.
load_env() {
    load_env_file "${CLAUDE_HOME:-}/.env"
    return 0
}
