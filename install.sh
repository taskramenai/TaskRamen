#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install.sh — TaskRamen.ai installer entry point
# Usage: ./install.sh [--headless]
#   --headless  Skip all terminal UI; assume deps are pre-installed (container mode)
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
CLAUDE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_HOME
export HOME="${HOME:-$(eval echo ~"$USER")}"

# ── Logging ────────────────────────────────────────────────────────────────
LOG_FILE="$CLAUDE_HOME/install.log"
export LOG_FILE
echo "[$(date '+%Y-%m-%d %H:%M:%S')] === TaskRamen.ai Installer started ===" >> "$LOG_FILE"

# ── Ensure scripts are executable ────────────────────────────────────────────
# The GitHub Contents API (used by Claude Code's GitHub MCP when pushing
# updates) commits files at mode 100644, stripping the executable bit. A
# `git pull` of such a commit then propagates the non-exec mode onto disk,
# and systemd's ExecStart for run.sh / monitor.sh fails with status=203/EXEC.
# Mirror the same recovery sweep already in entrypoint.sh so a freshly
# pulled tree is usable.
find "$CLAUDE_HOME" -name "*.sh" -type f -exec chmod +x {} + 2>/dev/null || true

# ── Load modules ─────────────────────────────────────────────────────────────
# shellcheck source=install/ui.sh
source "$CLAUDE_HOME/install/ui.sh"
# shellcheck source=install/utils.sh
source "$CLAUDE_HOME/install/utils.sh"
# shellcheck source=install/deps.sh
source "$CLAUDE_HOME/install/deps.sh"
# shellcheck source=install/telegram.sh
source "$CLAUDE_HOME/install/telegram.sh"
# shellcheck source=install/claude-auth.sh
source "$CLAUDE_HOME/install/claude-auth.sh"
# shellcheck source=install/config.sh
source "$CLAUDE_HOME/install/config.sh"
# shellcheck source=install/services.sh
source "$CLAUDE_HOME/install/services.sh"
# shellcheck source=core/auth-mode.sh
# Provides taskramen_creds_present() — the single source of truth for "is a
# usable interactive-login credential present?" (checks every credentials.json
# path AND validates the file is non-empty with a real OAuth token field).
# Used by _install_critical_ok below so the sentinel gate matches the same
# detection the login installer (claude-auth.sh) uses to confirm login success.
source "$CLAUDE_HOME/core/auth-mode.sh"
# NOTE: the old Google Workspace MCP installer stage has been removed. Google is
# now connected via the vendored claudeconnectorskillheadless flow — see
# CLAUDE.md "Connecting Services".
# shellcheck source=core/branding.sh
[ -f "$CLAUDE_HOME/core/branding.sh" ] && source "$CLAUDE_HOME/core/branding.sh"

# ── Flags ─────────────────────────────────────────────────────────────────────
HEADLESS=false
for arg in "$@"; do
    [[ "$arg" == "--headless" ]] && HEADLESS=true
done

# ── Main ───────────────────────────────────────────────────────────────────────
main() {
    if [[ "$HEADLESS" == "false" ]]; then
        _phase_welcome
        _phase_deps
        _phase_telegram
    else
        # Container / headless mode: deps are pre-baked, skip terminal UI
        ui_info "Headless mode — all setup via Telegram."
        ui_info "Send any message to your bot to begin."
        # In headless mode the token is expected via environment variables
        # TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set, or we poll for them.
        if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
            ui_error "TELEGRAM_BOT_TOKEN not set. Please pass it via environment variable."
            exit 1
        fi
        if [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
            ui_info "TELEGRAM_CHAT_ID not set — polling for first message..."
            TELEGRAM_CHAT_ID=$(tg_poll_chat_id)
        fi
        export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
        write_env "TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN"
        write_env "TELEGRAM_CHAT_ID"   "$TELEGRAM_CHAT_ID"
    fi

    _phase_claude_auth

    # IMPORTANT: nothing below may abort the installer before _phase_done writes
    # the .install-complete sentinel. install.sh runs under `set -euo pipefail`
    # and the sentinel is the LAST thing written. If a config/optional step
    # returns non-zero under `set -e`, main dies BEFORE the sentinel — then on
    # the next container restart entrypoint.sh sees it missing, re-launches the
    # INTERACTIVE wizard with no TTY, and deadlocks: no "starting up Claude"
    # ping, tray stuck at "starting". This is the recurring "works on first run,
    # dead after restart" failure. PR #364 fixed one instance (the dead
    # optional_google call), but ANY environment-dependent failure in these
    # phases reproduces it (e.g. an unguarded command in config_generate /
    # tg_sync_plugin_config).
    #
    # So run them best-effort with `set -e` disabled for the duration. We do NOT
    # wrap them in `(set -e; phase)` subshells: config_generate's steps are
    # largely independent and individually guarded, so we want it to RUN TO
    # COMPLETION past a non-critical hiccup (e.g. the hooks/trust python) rather
    # than abort at the first failure and skip the later, independent
    # telegram-plugin / webhook / access-sync steps — which would leave a LESS
    # functional install. A subshell would also discard any shell state a phase
    # sets in this process. Completion is decided by _phase_done via
    # _install_critical_ok, not by whether every step here succeeded.
    set +e
    _phase_config_and_services || ui_warn "Setup step (config/services) reported an error — continuing."
    set -e

    _phase_done
}

# ── Phase 1: Welcome + banner ────────────────────────────────────────────────────────
_phase_welcome() {
    clear
    ui_banner "  ✦  ${PRODUCT_NAME:-TaskRamen.ai} — Personal AI Setup  ✦" ""
    ui_info "Welcome to TaskRamen! We are a quick and easy to use AI agent"
    ui_info "that gets things done. You can use TaskRamen to make and edit"
    ui_info "presentation and excel files, schedule reminders and tasks,"
    ui_info "build websites, analyze data and more."
    ui_blank
    ui_info "To use TaskRamen, you will need:"
    ui_bullet "A Claude Pro or Max account"
    ui_bullet "A Telegram account (your main channel for talking to the agent)"
    ui_bullet "To keep this machine turned on and running"
}

# ── Phase 2: Dependencies ───────────────────────────────────────────────────────────────────
_phase_deps() {
    deps_check_and_install
    deps_update_shell_profile
}

# ── Phase 3: Telegram setup (last terminal interaction) ───────────────────────
_phase_telegram() {
    telegram_setup

    # Print hand-off message and switch terminal to passive log
    ui_step 3 3 "Finishing up in Telegram"
    ui_info "Check Telegram — the next step is waiting there."
    ui_info "This window will keep running in the background."
    ui_info "You can minimize it."
    ui_blank
    ui_info "(Logging continues below)"
    ui_divider ""
}

# ── Phase 4: Claude activation ─────────────────────────────────────────────────────────
_phase_claude_auth() {
    claude_auth
}

# ── Phase 5: Config + services ─────────────────────────────────────────────────────────
_phase_config_and_services() {
    config_generate
    services_enable_start

    # Health check: in container mode, skip — entrypoint.sh starts services AFTER
    # install.sh completes and runs its own health check once they're up.
    if ! _is_container_mode; then
        sleep 8
        if ! services_health_check; then
            send_tg "⚠️ One or more services didn't start correctly. Check \`sudo systemctl status claudebot.service\` in your terminal." "Markdown"
        fi
    fi
}

# Functional-completeness gate for the .install-complete sentinel.
# Mirrors entrypoint.sh's _check_install_critical: the install is "functional"
# once Telegram (bot token + chat id) and Claude auth are present — auth being
# either a token in .env OR a usable interactive-login credential. The regexes
# require an uncommented, NON-EMPTY value (`^KEY=.`), so a present-but-blank or
# commented key can't mark a broken install complete.
#
# Claude-auth detection uses taskramen_creds_present() (core/auth-mode.sh) rather
# than a bare `-f` test on one path. That helper is the SAME function the login
# installer (claude-auth.sh) polls to confirm a login succeeded, so it is exactly
# right for the new interactive-login (auth #6) mode: it checks every
# credentials.json path variant AND requires the file be non-empty with a real
# OAuth token field ("accessToken"/claudeAiOauth). A truncated or empty creds
# file therefore can NOT mark a broken login install complete (the old `-f`
# check would have). Only ever called from an `if` test, so `set -e` is
# suppressed for its `return 1`s.
_install_critical_ok() {
    local env_file="$CLAUDE_HOME/.env"
    [[ -f "$env_file" ]] || return 1
    grep -qE "^TELEGRAM_BOT_TOKEN=." "$env_file" 2>/dev/null || return 1
    grep -qE "^TELEGRAM_CHAT_ID=."   "$env_file" 2>/dev/null || return 1
    # Login mode comments CLAUDE_CODE_OAUTH_TOKEN out of .env and relies on the
    # interactive-login credentials file instead, so accept either an uncommented
    # token OR a usable login credential.
    if ! grep -qE "^CLAUDE_CODE_OAUTH_TOKEN=." "$env_file" 2>/dev/null \
        && ! taskramen_creds_present; then
        return 1
    fi
    return 0
}

# ── Phase 6: Done ────────────────────────────────────────────────────────────────────────
_phase_done() {
    local product="${PRODUCT_NAME:-TaskRamen.ai}"

    # NOTE: The "ready / what would you like to do first?" Telegram message is
    # intentionally NOT sent here. At this point install.sh has finished, but
    # Claude itself has not yet launched (claudebot/run.sh starts it afterwards),
    # so a "ready" ping here is premature and misleading. The welcome message is
    # now sent once Claude is genuinely up — see core/run.sh _announce_startup,
    # which already verifies channels + the Telegram poller before announcing
    # "Claude started". (Welcome-on-first-start: planned, see install plan.)

    # Write the completion sentinel — but ONLY if the install is functionally
    # complete (Telegram + Claude sign-in present). Writing it unconditionally
    # would mark a half-finished install "done" and skip the resume-wizard;
    # withholding it when the core IS present is what wedged restarts (see the
    # note in main()). This decouples completion from non-critical step failures.
    if _install_critical_ok; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')" > "$CLAUDE_HOME/.install-complete"
    else
        ui_warn "Core setup is incomplete (Telegram + Claude sign-in) — not marking install complete; setup will resume on next launch."
    fi

    ui_blank
    ui_divider ""
    ui_ok "${product} is installed and running."
    ui_blank
    ui_info "Your assistant is live in Telegram."
    ui_blank
    ui_info "Run this to activate shell shortcuts in your current terminal:"
    echo ""
    echo "    source ~/.bashrc"
    echo ""
}

main "$@"
