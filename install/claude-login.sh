#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/claude-login.sh — Switch TaskRamen onto a REAL interactive Claude.ai
# subscription login (auth precedence #6) instead of the default headless
# CLAUDE_CODE_OAUTH_TOKEN (#5, from `claude setup-token`). Required for claude.ai
# connectors (remote MCP servers at claude.ai/customize/connectors) to load —
# they are fetched ONLY when the active auth method is the subscription login.
# See issue #356 for the full doc-verified analysis.
#
# THIN WRAPPER. The entire OAuth/tmux flow lives in ONE place — claude_auth() in
# install/claude-auth.sh, which is mode-aware. `claude_auth login` drives PLAIN
# `claude` (the interactive login TUI) instead of `claude setup-token`, captures
# the same OAuth URL, relays it over Telegram, injects the returned code,
# succeeds on ~/.claude/.credentials.json (verified via `auth status`), flips
# .env into login mode, and restarts claudebot. Sharing that machinery with the
# token path is deliberate: a separate copy would drift out of parity (the
# wrapped-URL grep, cleanup trap, and onboarding pre-seed were all parity bugs
# from the previous standalone implementation).
#
# Idempotent: if a valid interactive login already exists, claude_auth just
# (re)applies login mode. To revert to the headless token: restore the printed
# .env backup, or run install/claude-auth.sh (token mode).

set -o pipefail

# ── Resolve CLAUDE_HOME and load helpers ──────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CLAUDE_HOME:="$(dirname "$SCRIPT_DIR")"}"
export CLAUDE_HOME

# shellcheck source=/dev/null
source "$CLAUDE_HOME/install/ui.sh"
# shellcheck source=/dev/null
source "$CLAUDE_HOME/install/utils.sh"
# claude-auth.sh only DEFINES functions at file scope (no top-level execution).
# shellcheck source=/dev/null
source "$CLAUDE_HOME/install/claude-auth.sh"
# shellcheck source=/dev/null
source "$CLAUDE_HOME/core/auth-mode.sh"

source_env

# The login URL is relayed over Telegram (claude_auth's OAuth handshake), so
# Telegram creds are required. Fail fast with a clear message.
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    ui_warn "TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID missing — the login URL is relayed over Telegram. Aborting." >&2
    exit 1
fi

ui_info "Switching TaskRamen to interactive Claude.ai login (auth #6, for claude.ai connectors)." >&2
send_tg "🔐 Setting up an interactive Claude login so claude.ai connectors load. I'll send a link to approve shortly." "Markdown"

# Force interactive-login mode regardless of the configured default. claude_auth
# handles plugin-quiesce, the OAuth handshake, verification, the .env mode flip
# and the claudebot restart (including restoring the poller on failure).
claude_auth login
