#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# core/auth-mode.sh — single, sourceable source of truth for which Claude auth
# path TaskRamen runs on:
#
#   "token"  — legacy headless setup-token (CLAUDE_CODE_OAUTH_TOKEN, auth
#              precedence #5). This is the original, battle-tested path; all of
#              its code in claude-auth.sh / run.sh / monitor.sh is preserved
#              unchanged and is still selected whenever this resolver says
#              "token".
#   "login"  — interactive Claude.ai subscription login (~/.claude/.credentials.json,
#              auth precedence #6). Required for claude.ai connectors to load
#              (see issue #356). Established by install/claude-login.sh.
#
# DESIGN: this file is SIDE-EFFECT FREE — it only sets the default constant and
# defines functions. Source it from any script that needs the flag:
#
#     source "$CLAUDE_HOME/core/auth-mode.sh"
#     if [ "$(taskramen_auth_mode)" = "login" ]; then ...
#
# The flag itself is the env var TASKRAMEN_AUTH_MODE, normally stored in
# $CLAUDE_HOME/.env (written by install/claude-login.sh). When it is absent the
# project-wide default below applies.

# Project-wide default when TASKRAMEN_AUTH_MODE is unset. Currently "login" (the
# new path). Flip this one line to change the default everywhere.
: "${TASKRAMEN_AUTH_MODE_DEFAULT:=login}"

# taskramen_creds_present — true when a USABLE interactive-login credential
# exists (either the home path or the container's volume-symlinked path). The
# file must be non-empty AND carry an OAuth token field: an empty, truncated, or
# corrupt credentials.json must NOT count, otherwise it would silently flip the
# system into login mode and disable the still-working setup-token. (Does not
# verify the token is unexpired — that needs a live `auth status` call; monitor
# handles expiry in login mode.)
taskramen_creds_present() {
    local f
    for f in "$HOME/.claude/.credentials.json" "$HOME/.claude/credentials.json" \
             "${CLAUDE_HOME:-}/.claude/.credentials.json" "${CLAUDE_HOME:-}/.claude/credentials.json"; do
        [[ -s "$f" ]] || continue
        grep -qE '"accessToken"|claudeAiOauth' "$f" 2>/dev/null && return 0
    done
    return 1
}

# taskramen_auth_mode_raw — echoes the configured mode WITHOUT the credential
# safety check: an explicit TASKRAMEN_AUTH_MODE if valid, else the default.
# Use this when you want the literal configured intent.
taskramen_auth_mode_raw() {
    local m="${TASKRAMEN_AUTH_MODE:-$TASKRAMEN_AUTH_MODE_DEFAULT}"
    case "$m" in
        token|login) echo "$m" ;;
        *)           echo "$TASKRAMEN_AUTH_MODE_DEFAULT" ;;
    esac
}

# taskramen_auth_mode — echoes the EFFECTIVE mode ("login" or "token").
# Identical to taskramen_auth_mode_raw EXCEPT it will not return "login" unless
# a credentials.json actually exists. This is what makes defaulting to "login"
# safe on a token-only install: with no login creds yet, every consumer
# transparently keeps the original token behavior instead of launching Claude
# unauthenticated. install/claude-login.sh writes the creds first, so by the
# time it sets the flag this returns "login".
taskramen_auth_mode() {
    local m; m="$(taskramen_auth_mode_raw)"
    if [[ "$m" == "login" ]] && ! taskramen_creds_present; then
        echo "token"
    else
        echo "$m"
    fi
}

# taskramen_auth_mode_label — a clear, human-readable description of the EFFECTIVE
# auth path, for logs and status messages.
taskramen_auth_mode_label() {
    case "$(taskramen_auth_mode)" in
        login) echo "login — Claude.ai subscription (credentials.json, auth #6)" ;;
        *)     echo "token — headless CLAUDE_CODE_OAUTH_TOKEN (auth #5)" ;;
    esac
}
