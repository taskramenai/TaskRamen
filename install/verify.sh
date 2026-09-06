#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/verify.sh — Full stack health check
# Sources: install/ui.sh, install/utils.sh
# Usage: bash install/verify.sh  OR  source install/verify.sh && verify_stack

# Resolve claude binary — prefer the globally installed claude, fall back to bunx
_claude_bin() {
    if command -v claude >/dev/null 2>&1; then
        echo "claude"
    elif [[ -f "$HOME/.bun/bin/claude" ]]; then
        echo "$HOME/.bun/bin/claude"
    elif command -v bunx >/dev/null 2>&1; then
        echo "bunx claude"
    elif [[ -f "$HOME/.bun/bin/bunx" ]]; then
        echo "$HOME/.bun/bin/bunx claude"
    else
        echo "npx @anthropic-ai/claude-code"
    fi
}

# Reduce a captured `cmd 2>&1` failure to one printable line: the last non-blank
# line (which is the actual error — npx/bun prefix theirs with resolver chatter),
# trimmed and capped. Without this a multi-line failure breaks the one-line-per-
# check layout.
_ver_err() {
    local m="$1"
    m="${m%"${m##*[![:space:]]}"}"   # drop trailing whitespace/newlines
    m="${m##*$'\n'}"                 # keep the last line
    m="${m#"${m%%[![:space:]]*}"}"   # drop leading whitespace
    [[ -z "$m" ]] && m="no output"
    printf '%.120s' "$m"
}

verify_stack() {
    local pass=0
    local fail=0

    # Helper: record pass/fail and print result
    _chk_ok() {
        pass=$(( pass + 1 ))
        ui_ok "$1"
    }
    _chk_warn() {
        fail=$(( fail + 1 ))
        ui_warn "$1"
    }

    ui_step 1 1 "Full stack verification"
    ui_blank

    # ── Binaries ────────────────────────────────────────────────────────────────
    ui_divider "Binaries"

    # node
    local node_ver
    node_ver=$(node --version 2>&1) || true
    if [[ "$node_ver" == v* ]]; then
        ui_ok "node: $node_ver ✓"
        (( pass++ )) || true
    else
        ui_warn "node: not working (got: ${node_ver:-not found})"
        (( fail++ )) || true
    fi

    # bun
    #
    # Gate on the EXIT STATUS, not on the output being non-empty: `2>&1` folds
    # stderr into the variable, so a failed command ("command not found") still
    # produces a non-empty value and used to be reported as a pass. Same pattern
    # for cloudflared, agent-browser and claude below.
    local bun_ver bun_rc
    bun_ver=$(bun --version 2>&1); bun_rc=$?
    if (( bun_rc == 0 )) && [[ -n "$bun_ver" ]]; then
        ui_ok "bun: $bun_ver ✓"
        (( pass++ )) || true
    else
        ui_warn "bun: not working ($(_ver_err "$bun_ver"))"
        (( fail++ )) || true
    fi

    # cloudflared
    local cf_ver cf_rc
    cf_ver=$(cloudflared --version 2>&1); cf_rc=$?
    if (( cf_rc == 0 )) && [[ -n "$cf_ver" ]]; then
        ui_ok "cloudflared: $cf_ver ✓"
        (( pass++ )) || true
    else
        ui_warn "cloudflared: not working ($(_ver_err "$cf_ver"))"
        (( fail++ )) || true
    fi

    # agent-browser
    local ab_bin ab_ver
    if command -v agent-browser >/dev/null 2>&1; then
        ab_bin="agent-browser"
    elif [[ -f "${CLAUDE_HOME:-}/node_modules/.bin/agent-browser" ]]; then
        ab_bin="${CLAUDE_HOME}/node_modules/.bin/agent-browser"
    fi
    if [[ -n "${ab_bin:-}" ]]; then
        local ab_rc
        ab_ver=$($ab_bin --version 2>&1); ab_rc=$?
        if (( ab_rc == 0 )) && [[ -n "$ab_ver" ]]; then
            ui_ok "agent-browser: $ab_ver ✓"
            (( pass++ )) || true
        else
            ui_warn "agent-browser: --version failed ($(_ver_err "$ab_ver"))"
            (( fail++ )) || true
        fi
    else
        ui_warn "agent-browser: not found"
        (( fail++ )) || true
    fi

    # claude binary
    local claude_bin
    claude_bin=$(_claude_bin)
    # Unquoted on purpose: _claude_bin may resolve to a two-word command
    # ("bunx claude", "npx @anthropic-ai/claude-code").
    local claude_ver claude_rc
    # shellcheck disable=SC2086
    claude_ver=$($claude_bin --version 2>&1); claude_rc=$?
    if (( claude_rc == 0 )) && [[ -n "$claude_ver" ]]; then
        ui_ok "claude: $claude_ver ✓  [$claude_bin]"
        (( pass++ )) || true
    else
        ui_warn "claude: not working [${claude_bin:-not found}] ($(_ver_err "$claude_ver"))"
        (( fail++ )) || true
    fi

    ui_blank

    # ── Services ────────────────────────────────────────────────────────────────
    ui_divider "Systemd services (--user)"

    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        ui_warn "Note: XDG_RUNTIME_DIR not set — systemctl --user may not work. Using pgrep fallback for service checks."
        ui_blank
    fi

    # stealth-chrome
    local svc_state
    svc_state=$(systemctl --user is-active stealth-chrome 2>/dev/null || echo "unknown")
    if [[ "$svc_state" == "active" ]]; then
        _chk_ok "stealth-chrome: active (systemd) ✓"
    elif pgrep -f "chrome.*remote-debugging-port=9222" >/dev/null 2>&1; then
        _chk_ok "stealth-chrome: running (process found) ✓"
    else
        _chk_warn "stealth-chrome: not running (systemd: $svc_state, no process found)"
    fi

    # claude-router
    svc_state=$(systemctl --user is-active claude-router 2>/dev/null || echo "unknown")
    if [[ "$svc_state" == "active" ]]; then
        _chk_ok "claude-router: active (systemd) ✓"
    elif pgrep -f "claude-router" >/dev/null 2>&1; then
        _chk_ok "claude-router: running (process found) ✓"
    else
        _chk_warn "claude-router: not running (systemd: $svc_state, no process found)"
    fi

    # openrouter-bridge
    svc_state=$(systemctl --user is-active openrouter-bridge 2>/dev/null || echo "unknown")
    if [[ "$svc_state" == "active" ]]; then
        _chk_ok "openrouter-bridge: active (systemd) ✓"
    elif pgrep -f "openrouter-bridge" >/dev/null 2>&1; then
        _chk_ok "openrouter-bridge: running (process found) ✓"
    else
        _chk_warn "openrouter-bridge: not running (systemd: $svc_state, no process found)"
    fi

    # claudebot
    svc_state=$(systemctl --user is-active claudebot 2>/dev/null || echo "unknown")
    if [[ "$svc_state" == "active" ]]; then
        _chk_ok "claudebot: active (systemd) ✓"
    elif pgrep -f "claude.*channels.*telegram" >/dev/null 2>&1; then
        _chk_ok "claudebot: running (process found) ✓"
    else
        _chk_warn "claudebot: not running (systemd: $svc_state, no process found)"
    fi

    # claudemonitor
    svc_state=$(systemctl --user is-active claudemonitor 2>/dev/null || echo "unknown")
    if [[ "$svc_state" == "active" ]]; then
        _chk_ok "claudemonitor: active (systemd) ✓"
    elif pgrep -f "claudemonitor" >/dev/null 2>&1; then
        _chk_ok "claudemonitor: running (process found) ✓"
    else
        _chk_warn "claudemonitor: not running (systemd: $svc_state, no process found)"
    fi

    ui_blank

    # ── Chrome/CDP ──────────────────────────────────────────────────────────────
    ui_divider "Chrome / CDP"

    # Port 9222 listening
    if ss -tlnp 2>/dev/null | grep -q ':9222'; then
        _chk_ok "Port 9222  listening"
    else
        _chk_warn "Port 9222  not listening (stealth-chrome may be down)"
    fi

    # agent-browser CDP connect
    if command -v agent-browser >/dev/null 2>&1 || [[ -f "${CLAUDE_HOME:-}/node_modules/.bin/agent-browser" ]]; then
        local ab_bin="agent-browser"
        [[ ! $(command -v agent-browser 2>/dev/null) ]] && ab_bin="${CLAUDE_HOME}/node_modules/.bin/agent-browser"

        local snap_out
        snap_out=$(timeout 15 "$ab_bin" snapshot --cdp 9222 about:blank 2>&1) || true
        if echo "$snap_out" | grep -qiE 'snapshot|root|body|html'; then
            _chk_ok "agent-browser CDP  connected and snapshot returned"
        else
            _chk_warn "agent-browser CDP  snapshot failed or returned unexpected output"
        fi
    else
        _chk_warn "agent-browser CDP  skipped (binary not found)"
    fi

    ui_blank

    # ── Claude auth ─────────────────────────────────────────────────────────────
    ui_divider "Claude authentication"

    local claude_bin
    claude_bin=$(_claude_bin)
    local auth_out
    auth_out=$($claude_bin auth status 2>&1) || true

    local logged_in
    logged_in=$(echo "$auth_out" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("loggedIn"):
        email = d.get("emailAddress") or d.get("email") or "unknown"
        print("yes:" + email)
    else:
        print("no")
except Exception:
    print("no")
' 2>/dev/null)

    if [[ "$logged_in" == yes:* ]]; then
        local email="${logged_in#yes:}"
        _chk_ok "Claude auth  logged in as $email"
    else
        _chk_warn "Claude auth  not logged in (run: claude setup-token)"
    fi

    ui_blank

    # ── Telegram connectivity ─────────────────────────────────────────────────
    ui_divider "Telegram"

    ui_info "Telegram..."
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || [[ -z "${TELEGRAM_CHAT_ID:-}" ]]; then
        ui_warn "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set — skipping Telegram check"
        (( fail++ )) || true
    else
        [ -f "$CLAUDE_HOME/core/branding.sh" ] && source "$CLAUDE_HOME/core/branding.sh"
        local tg_resp
        tg_resp=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="✅ ${PRODUCT_NAME:-TaskRamen.ai} verify: Telegram connection OK" 2>&1) || true
        if echo "$tg_resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); exit(0 if d.get("ok") else 1)' 2>/dev/null; then
            ui_ok "Telegram: message sent successfully ✓"
            (( pass++ )) || true
        else
            ui_warn "Telegram: send failed — check bot token and chat ID"
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Telegram test message failed: $tg_resp" >> "${LOG_FILE:-/dev/null}"
            (( fail++ )) || true
        fi
    fi

    ui_blank

    # ── Chromium binary ─────────────────────────────────────────────────────────
    ui_divider "Puppeteer Chromium"

    local chrome_bin
    chrome_bin=$(find "$HOME/.cache/puppeteer" -name "chrome" -type f 2>/dev/null | head -1)
    if [[ -n "$chrome_bin" ]]; then
        _chk_ok "Chromium binary  found at $chrome_bin"
    else
        _chk_warn "Chromium binary  not found under ~/.cache/puppeteer"
    fi

    ui_blank

    # ── Summary ─────────────────────────────────────────────────────────────────
    local total=$(( pass + fail ))
    if [[ $fail -eq 0 ]]; then
        ui_ok "All $pass/$total checks passed"
    else
        ui_warn "$fail check(s) failed — $pass/$total passed"
    fi
}

# ── Entry point ─────────────────────────────────────────────────────────────────
# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"
    export CLAUDE_HOME
    export HOME="${HOME:-$(dirname "$CLAUDE_HOME")}"
    export BUN_INSTALL="$HOME/.bun"
    export NVM_DIR="$HOME/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
    export PATH="$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin"
    # Tolerant .env loader (issue #387)
    if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
        source "$CLAUDE_HOME/core/env-loader.sh"; load_env
    else
        [[ -f "$CLAUDE_HOME/.env" ]] && set -a && source "$CLAUDE_HOME/.env" && set +a
    fi
    source "$SCRIPT_DIR/ui.sh"
    source "$SCRIPT_DIR/utils.sh"
    verify_stack
fi
