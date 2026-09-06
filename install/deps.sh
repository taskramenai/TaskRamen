#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/deps.sh — Auto-install all dependencies (no prompting)
# Sources: install/ui.sh, install/utils.sh
# Requires: CLAUDE_HOME set

# Branding (PRODUCT_NAME, APP_SLUG) -- guarded source so values resolve whenever
# CLAUDE_HOME is known, regardless of caller / source order.
[ -n "${CLAUDE_HOME:-}" ] && [ -f "$CLAUDE_HOME/core/branding.sh" ] && source "$CLAUDE_HOME/core/branding.sh"

# Migrate a legacy VM_TIMEZONE entry to USER_TIMEZONE in .env (one-time,
# idempotent). VM_TIMEZONE was renamed to USER_TIMEZONE to make clear it is the
# user's wall-clock zone (a geolocation guess), distinct from SYSTEM_TIMEZONE
# (the zone the scheduler interprets cron/at entries in). Runs before detection
# so existing installs upgrade cleanly instead of silently re-detecting.
_migrate_timezone_env() {
    local env_file="$CLAUDE_HOME/.env"
    [[ -f "$env_file" ]] || return 0
    if grep -q '^VM_TIMEZONE=' "$env_file" && ! grep -q '^USER_TIMEZONE=' "$env_file"; then
        sed -i 's/^VM_TIMEZONE=/USER_TIMEZONE=/' "$env_file"
        [[ -z "${USER_TIMEZONE:-}" && -n "${VM_TIMEZONE:-}" ]] && export USER_TIMEZONE="$VM_TIMEZONE"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Migrated VM_TIMEZONE -> USER_TIMEZONE in .env" >> "$LOG_FILE"
    fi
}

# Detect the timezone the *scheduler* interprets cron/at entries in, and persist
# it as SYSTEM_TIMEZONE. This is the canonical frame both core/schedule.sh and
# core/at-task.sh write their entries in:
#   - container: supercronic runs under the image's TZ=UTC      -> UTC
#   - VM:        cronie/atd interpret in the host's /etc/localtime
# The scheduling scripts themselves (via core/tz-lib.sh) convert the user's
# stated time (USER_TIMEZONE) to SYSTEM_TIMEZONE at scheduling time and back
# for display — Claude passes times through verbatim and never converts.
_detect_system_timezone() {
    local sys_tz=""
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        sys_tz="${TZ:-UTC}"
    else
        sys_tz=$(timedatectl show -p Timezone --value 2>/dev/null) || sys_tz=""
        [[ -z "$sys_tz" ]] && sys_tz=$(readlink -f /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p')
        # Non-systemd hosts may ship /etc/localtime as a plain copied file
        # (no symlink to resolve); Debian-family keeps the zone name in
        # /etc/timezone — use it as a last resort.
        [[ -z "$sys_tz" && -r /etc/timezone ]] && sys_tz=$(tr -d '[:space:]' < /etc/timezone)
    fi
    # Empty, or the bare symlink basename, means "unknown" -> default to UTC.
    [[ -z "$sys_tz" || "$sys_tz" == "localtime" ]] && sys_tz="UTC"
    # A zone tzdata doesn't know is as bad as none — GNU date would silently
    # treat it as UTC anyway — so persist the honest default instead. That
    # includes tzdata being absent entirely (no /usr/share/zoneinfo): date
    # then parses every zone as UTC, so UTC is the only truthful value.
    [[ "$sys_tz" != "UTC" && ! -f "/usr/share/zoneinfo/$sys_tz" ]] && sys_tz="UTC"
    export SYSTEM_TIMEZONE="$sys_tz"
    write_env "SYSTEM_TIMEZONE" "$sys_tz"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Scheduler timezone (SYSTEM_TIMEZONE): ${sys_tz}" >> "$LOG_FILE"
}

# Detect VM location via ipinfo.io and store in .env
# Sets VM_COUNTRY (2-letter ISO, uppercase), USER_TIMEZONE (IANA), VM_CITY
# Falls back to US / America/New_York / Unknown if API is unreachable
_detect_vm_location() {
    # Skip if already detected (idempotent). Accept a legacy VM_TIMEZONE too.
    if [[ -n "${VM_COUNTRY:-}" && -n "${USER_TIMEZONE:-${VM_TIMEZONE:-}}" ]]; then
        return 0
    fi

    local json
    json=$(curl -sf --max-time 5 https://ipinfo.io/json 2>/dev/null) || json=""

    if [[ -n "$json" ]]; then
        local country timezone city
        country=$(echo "$json"  | grep -oP '"country"\s*:\s*"\K[^"]+' | head -1)
        timezone=$(echo "$json" | grep -oP '"timezone"\s*:\s*"\K[^"]+' | head -1)
        city=$(echo "$json"     | grep -oP '"city"\s*:\s*"\K[^"]+' | head -1)

        # Validate
        [[ "$country" =~ ^[A-Z]{2}$ ]]  || country="US"
        [[ -n "$timezone" ]]             || timezone="America/New_York"
        [[ -n "$city" ]]                 || city="Unknown"
    else
        country="US"
        timezone="America/New_York"
        city="Unknown"
    fi

    # Export for immediate use in this session
    export VM_COUNTRY="$country"
    export USER_TIMEZONE="$timezone"
    export VM_CITY="$city"

    # Persist to .env
    write_env "VM_COUNTRY"   "$country"
    write_env "USER_TIMEZONE" "$timezone"
    write_env "VM_CITY"      "$city"

    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Detected VM location: ${city}, ${country} (${timezone})" >> "$LOG_FILE"
}

# Ensure the Claude Code CLI is installed. Claude Code is proprietary and not
# redistributable, so it is NEVER baked into the distributed container image
# (see Containerfile). It is pulled here at install/first-run time instead.
#
# Container mode: install into a prefix on the persistent bind mount
# ($CLAUDE_HOME/.npm-global) — the only location that survives a container
# recreate (the nvm global dir lives in the ephemeral overlay layer, and
# ~/.local is a tmpfs). $CLAUDE_HOME/.npm-global/bin is added to PATH by
# entrypoint.sh, run.sh and monitor.sh.
# VM/bare-metal mode: install -g into the nvm global dir (already on PATH).
# Idempotent: no-op if a `claude` binary is already resolvable.
deps_ensure_claude_code() {
    if command -v claude >/dev/null 2>&1 || [[ -f "$HOME/.bun/bin/claude" ]]; then
        return 0
    fi
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        local prefix="$CLAUDE_HOME/.npm-global"
        [[ -x "$prefix/bin/claude" ]] && return 0
        mkdir -p "$prefix"
        npm install -g --prefix "$prefix" @anthropic-ai/claude-code >> "${LOG_FILE:-/dev/null}" 2>&1 || true
        export PATH="$prefix/bin:$PATH"
    else
        npm install -g @anthropic-ai/claude-code >> "${LOG_FILE:-/dev/null}" 2>&1 || true
    fi
}

deps_check_and_install() {
    # In container mode, system deps are pre-baked in the image — skip package
    # installs. Claude Code is the exception: it is not redistributable, so it
    # is pulled at runtime here rather than baked into the image.
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        ui_info "Container mode — skipping package installation (pre-baked in image)"
        _migrate_timezone_env 2>/dev/null || true
        _detect_vm_location 2>/dev/null || true
        _detect_system_timezone 2>/dev/null || true
        ui_progress_bar "Claude Code CLI" "running"
        deps_ensure_claude_code
        if command -v claude >/dev/null 2>&1 || [[ -x "$CLAUDE_HOME/.npm-global/bin/claude" ]]; then
            ui_progress_bar "Claude Code CLI" "done"
        else
            ui_progress_bar "Claude Code CLI" "fail"
            ui_warn "Claude Code CLI not found after install — check npm output"
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] claude binary not found after runtime npm install (container mode)" >> "$LOG_FILE"
        fi
        return 0
    fi

    ui_step 1 3 "Getting everything ready"

    ui_info "You'll be asked for your password once to get started."
    ui_info "After that, everything is automatic."
    ui_blank

    # ── Detect timezones (user wall-clock + scheduler) and VM location ───────
    _migrate_timezone_env
    _detect_vm_location
    _detect_system_timezone

    # ── Phase 1: upfront sudo block ───────────────────────────────────────────

    # Essential small packages (fast to install from any mirror)
    local need_apt=()
    command -v tmux     >/dev/null 2>&1 || need_apt+=("tmux")
    command -v at       >/dev/null 2>&1 || need_apt+=("at")
    command -v unzip    >/dev/null 2>&1 || need_apt+=("unzip")       # required by bun installer
    command -v xvfb-run >/dev/null 2>&1 || need_apt+=("xvfb")        # required by stealth-chrome service
    command -v matchbox-window-manager >/dev/null 2>&1 || need_apt+=("matchbox-window-manager")  # lightweight WM for stealth-chrome (xvfb)
    [[ -d /usr/share/zoneinfo ]] || need_apt+=("tzdata")             # without it, date parses every TZ=<zone> as UTC — all schedule conversions break
    command -v keyctl   >/dev/null 2>&1 || need_apt+=("keyutils")    # provides keyctl, the kernel-keyring sink the connector DCR flow writes credentials to (see Containerfile); not installed by default on most distros
    command -v jq       >/dev/null 2>&1 || need_apt+=("jq")          # required by the settings.json hooks (inject-agent-prompt.sh, reply-gate.sh); without it the reply gate silently no-ops and agent rule injection breaks
    # Check if Chromium/Chrome is already installed
    local chrome_needed=false
    if ! command -v chromium-browser >/dev/null 2>&1 && \
       ! command -v chromium >/dev/null 2>&1 && \
       ! command -v google-chrome-stable >/dev/null 2>&1 && \
       ! command -v google-chrome >/dev/null 2>&1; then
        chrome_needed=true
    fi

    if [[ ${#need_apt[@]} -gt 0 || "$chrome_needed" == "true" ]]; then
        # Skip sudo credential cache in container mode (running as root or with pre-configured sudo)
        if [[ ! -f /.dockerenv && "${CONTAINER:-}" != "true" ]]; then
            sudo -v   # cache credentials — user enters password once here
        fi

        # Select the fastest apt mirror: cloud-provider CDN > country mirror > default
        # Cloud-provider mirrors are internal to their networks and orders of magnitude
        # faster than public geographic mirrors (e.g. azure: 48 MB/s vs sg: 40 KB/s).
        local _mirror=""

        # 1. Detect cloud provider via DMI sys_vendor (no network needed)
        local _vendor=""
        _vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)
        case "$_vendor" in
            "Microsoft Corporation")
                _mirror="azure.archive.ubuntu.com"
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Azure VM detected — using Azure apt mirror" >> "$LOG_FILE"
                ;;
            "Amazon EC2"|"Amazon")
                _mirror="archive.ubuntu.com"
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] AWS VM detected — using default apt mirror" >> "$LOG_FILE"
                ;;
            "Google")
                _mirror="archive.ubuntu.com"
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] GCP VM detected — using default apt mirror" >> "$LOG_FILE"
                ;;
        esac

        # 2. Fall back to country mirror if no cloud provider matched
        if [[ -z "$_mirror" ]]; then
            local _country
            _country=$(echo "${VM_COUNTRY:-}" | tr '[:upper:]' '[:lower:]')
            if [[ -n "$_country" && "$_country" =~ ^[a-z]{2}$ ]]; then
                _mirror="${_country}.archive.ubuntu.com"
            fi
        fi

        # 3. Speed-test the chosen mirror; fall back to default if too slow (<200 KB/s)
        if [[ -n "$_mirror" && "$_mirror" != "archive.ubuntu.com" ]]; then
            local _speed
            _speed=$(curl -sf --max-time 5 -w "%{speed_download}" -o /dev/null \
                "http://${_mirror}/ubuntu/dists/noble/Release" 2>/dev/null || echo "0")
            # speed_download is in bytes/sec; 200000 = 200 KB/s threshold
            if (( ${_speed%.*} < 200000 )); then
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Mirror ${_mirror} too slow (${_speed} B/s) — falling back to archive.ubuntu.com" >> "$LOG_FILE"
                _mirror="archive.ubuntu.com"
            fi
        fi

        # 4. Apply the chosen mirror to apt sources
        # Pattern matches the default AND any previously-set *.archive.ubuntu.com variant
        # (e.g. sg.archive.ubuntu.com set by a prior install run) so re-runs also work.
        if [[ -n "$_mirror" ]]; then
            if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
                sudo sed -i "s|http://[a-z0-9.-]*archive\.ubuntu\.com/ubuntu|http://${_mirror}/ubuntu|g" \
                    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
            fi
            if [[ -f /etc/apt/sources.list ]]; then
                sudo sed -i "s|http://[a-z0-9.-]*archive\.ubuntu\.com/ubuntu|http://${_mirror}/ubuntu|g" \
                    /etc/apt/sources.list 2>/dev/null || true
            fi
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] apt mirror: ${_mirror} (vendor=${_vendor:-none} country=${VM_COUNTRY:-?})" >> "$LOG_FILE"
        fi

        # Update package index first (essential on fresh VMs)
        ui_progress_bar "Updating package lists" "running"
        if sudo apt-get update -y >> "${LOG_FILE:-/dev/null}" 2>&1; then
            ui_progress_bar "Updating package lists" "done"
        else
            ui_progress_bar "Updating package lists" "fail"
            ui_warn "Package list update had errors — install will continue"
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] apt-get update failed" >> "$LOG_FILE"
        fi

        # Install essential small packages first
        if [[ ${#need_apt[@]} -gt 0 ]]; then
            ui_progress_bar "System essentials" "running"
            set +e
            sudo apt-get install -y --no-install-recommends "${need_apt[@]}" >> "${LOG_FILE:-/dev/null}" 2>&1
            local apt_exit=$?
            set -e

            if [[ "$apt_exit" -eq 0 ]]; then
                ui_progress_bar "System essentials" "done"
            else
                ui_progress_bar "System essentials" "fail"
                ui_error "Failed to install system packages."
                if [[ -n "${LOG_FILE:-}" ]]; then
                    ui_error "Details:"
                    grep -E "^E:|^Err:|^dpkg:|failed|error" "$LOG_FILE" | tail -10 >&2
                fi
                exit 1
            fi
        else
            ui_progress_bar "System essentials" "done"
        fi

        # Soft dependency: qrencode (QR code for token transfer — nice to have, not required)
        if ! command -v qrencode >/dev/null 2>&1; then
            sudo apt-get install -y --no-install-recommends qrencode >> "${LOG_FILE:-/dev/null}" 2>&1 || true
        fi

        # Install Chromium browser (works on all architectures: amd64, arm64)
        # Falls back to Chrome .deb on amd64 if chromium-browser package unavailable
        if [[ "$chrome_needed" == "true" ]]; then
            ui_progress_bar "Web browser" "running"
            # Try Chromium first (preferred — multi-arch, no proprietary bits)
            set +e
            sudo apt-get install -y --no-install-recommends chromium-browser >> "${LOG_FILE:-/dev/null}" 2>&1
            local chromium_exit=$?
            set -e

            if [[ "$chromium_exit" -ne 0 ]]; then
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] chromium-browser package install failed — trying Google Chrome .deb" >> "$LOG_FILE"
                local arch
                arch=$(uname -m)
                if [[ "$arch" == "x86_64" ]]; then
                    local chrome_deb="/tmp/google-chrome-stable.deb"
                    curl -fsSL \
                        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" \
                        -o "$chrome_deb" >> "${LOG_FILE:-/dev/null}" 2>&1
                    set +e
                    sudo apt-get install -y --no-install-recommends "$chrome_deb" >> "${LOG_FILE:-/dev/null}" 2>&1
                    local chrome_exit=$?
                    set -e
                    rm -f "$chrome_deb"
                    if [[ "$chrome_exit" -ne 0 ]]; then
                        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Chrome .deb install failed — falling back to manual lib installs" >> "$LOG_FILE"
                        _install_chrome_deps_fallback
                    fi
                else
                    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Non-amd64 arch ($arch) — installing browser deps manually" >> "$LOG_FILE"
                    _install_chrome_deps_fallback
                fi
            fi
            # Verify a browser installed successfully
            if command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1 || \
               command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; then
                ui_progress_bar "Web browser" "done"
            else
                ui_progress_bar "Web browser" "fail"
                ui_error "Failed to install web browser (Chromium or Chrome)."
                if [[ -n "${LOG_FILE:-}" ]]; then
                    ui_error "Details:"
                    grep -E "^E:|^Err:|^dpkg:|failed|error" "$LOG_FILE" | tail -10 >&2
                fi
                exit 1
            fi
        else
            ui_progress_bar "Web browser" "done"
        fi

        ui_blank
    fi

    # Register systemd services while we have sudo (services exist in config/)
    # In container mode, skip systemd — entrypoint.sh manages processes directly
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Container mode: skipping systemd service registration" >> "$LOG_FILE"
    else
        _deps_install_services
        # Enable linger so user services survive logout (no sudo needed)
        loginctl enable-linger "$USER" 2>/dev/null || true
    fi

    # ── Phase 2: user-space installs ──────────────────────────────────────────

    # Node / nvm
    export NVM_DIR="$HOME/.nvm"
    if ! command -v node >/dev/null 2>&1 && [[ ! -d "$NVM_DIR" ]]; then
        ui_progress_bar "Node.js" "running"
        curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh \
            | bash >/dev/null 2>&1 || true
        set +eu
        # shellcheck disable=SC1090
        source "$NVM_DIR/nvm.sh" 2>/dev/null || true
        nvm install --lts >/dev/null 2>&1 || true
        nvm use --lts      >/dev/null 2>&1 || true
        set -eu
    fi
    # Always load nvm for rest of script
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        set +eu
        # shellcheck disable=SC1090
        source "$NVM_DIR/nvm.sh" 2>/dev/null || true
        set -eu
    fi
    if ! command -v node >/dev/null 2>&1; then
        ui_progress_bar "Node.js" "fail"
        ui_warn "Node.js not found after install — subsequent steps may fail"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] node not found after nvm install" >> "$LOG_FILE"
    else
        ui_progress_bar "Node.js" "done"
    fi

    # Bun (also required by Telegram plugin)
    if ! command -v bun >/dev/null 2>&1 && [[ ! -x "$HOME/.bun/bin/bun" ]]; then
        ui_progress_bar "Bun" "running"
        local bun_log
        bun_log=$(curl -fsSL https://bun.sh/install | bash 2>&1) || true
        if [[ ! -x "$HOME/.bun/bin/bun" ]]; then
            ui_warn "Bun install failed. Output: $bun_log"
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Bun install failed: $bun_log" >> "$LOG_FILE"
        else
            ui_progress_bar "Bun" "done"
        fi
    else
        ui_progress_bar "Bun" "done"
    fi
    # Always ensure bun is on PATH for this session
    export PATH="$HOME/.bun/bin:$PATH"

    # Claude Code CLI — proprietary, not redistributable, so always pulled at
    # install time (never baked). bunx would otherwise fall back to downloading it.
    if ! command -v claude >/dev/null 2>&1 && [[ ! -f "$HOME/.bun/bin/claude" ]]; then
        ui_progress_bar "Claude Code CLI" "running"
        deps_ensure_claude_code
    fi
    if ! command -v claude >/dev/null 2>&1 && [[ ! -f "$HOME/.bun/bin/claude" ]]; then
        ui_progress_bar "Claude Code CLI" "fail"
        ui_warn "Claude Code CLI not found after install — check npm output"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] claude binary not found after npm install" >> "$LOG_FILE"
    else
        ui_progress_bar "Claude Code CLI" "done"
    fi


    # cloudflared
    local cloudflared_bin="$HOME/bin/cloudflared"
    export PATH="$HOME/bin:$PATH"
    if ! command -v cloudflared >/dev/null 2>&1 && [[ ! -x "$cloudflared_bin" ]]; then
        ui_progress_bar "Secure tunnel" "running"
        mkdir -p "$HOME/bin"
        local arch
        arch=$(uname -m)
        local cf_url
        case "$arch" in
            x86_64)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
            aarch64) cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
            armv7l)  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
            *)       cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
        esac
        curl -fsSL "$cf_url" -o "$cloudflared_bin" 2>/dev/null || true
        chmod +x "$cloudflared_bin"
    fi
    if [[ ! -x "$cloudflared_bin" ]] && ! command -v cloudflared >/dev/null 2>&1; then
        ui_progress_bar "Secure tunnel" "fail"
        ui_warn "cloudflared not found after install — OAuth tunnel will not work"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] cloudflared not found after install" >> "$LOG_FILE"
    else
        ui_progress_bar "Secure tunnel" "done"
    fi

    # npm install — skip puppeteer's bundled Chromium since we use system Chromium/Chrome
    # (system browser is launched by stealth-chrome service / entrypoint.sh; puppeteer connects via CDP)
    ui_progress_bar "App packages" "running"
    cd "$CLAUDE_HOME"
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true npm install >/dev/null 2>&1 || true

    # Persist the skip-download env var so future npm installs also skip it
    if [[ -f "$CLAUDE_HOME/.env" ]] && ! grep -q "PUPPETEER_SKIP_CHROMIUM_DOWNLOAD" "$CLAUDE_HOME/.env"; then
        echo "PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true" >> "$CLAUDE_HOME/.env"
    fi

    # Verify system browser is available (Chromium or Chrome)
    if command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1 || \
       command -v google-chrome-stable >/dev/null 2>&1 || command -v google-chrome >/dev/null 2>&1; then
        ui_progress_bar "App packages" "done"
    else
        ui_progress_bar "App packages" "fail"
        ui_warn "System browser not found — browser features may not work"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] No system browser found (chromium-browser, chromium, google-chrome-stable, google-chrome)" >> "$LOG_FILE"
    fi

    # agent-browser: install globally so it's on PATH
    # (also installed locally via npm install above)
    # Note: skip 'agent-browser install' — TaskRamen.ai always uses --cdp 9222 to
    # connect to the existing stealth Chrome; no separate Chrome download needed.
    ui_progress_bar "Browser automation" "running"
    npm install -g agent-browser >/dev/null 2>&1 || true
    if ! command -v agent-browser >/dev/null 2>&1 && [[ ! -f "$CLAUDE_HOME/node_modules/.bin/agent-browser" ]]; then
        ui_progress_bar "Browser automation" "fail"
        ui_warn "agent-browser not found after install — browser automation may not work"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] agent-browser not found after install" >> "$LOG_FILE"
    else
        ui_progress_bar "Browser automation" "done"
    fi

    # ── Verify agent-browser can connect to browser on CDP port 9222 ─────────
    ui_progress_bar "Checking everything works" "running"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Verifying agent-browser → browser CDP connection..." >> "$LOG_FILE"
    # In container mode, browser is started by entrypoint.sh; in VM mode, use systemctl
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Container mode: browser managed by entrypoint.sh" >> "$LOG_FILE"
    else
        systemctl --user start stealth-chrome 2>/dev/null || true
    fi
    local cdp_ok=false
    for _i in 1 2 3 4 5 6 7 8 9 10; do
        if ss -tlnp 2>/dev/null | grep -q ':9222'; then
            cdp_ok=true
            break
        fi
        sleep 1
    done
    if [[ "$cdp_ok" == "true" ]]; then
        local ab_bin
        if command -v agent-browser >/dev/null 2>&1; then
            ab_bin="agent-browser"
        elif [[ -f "$CLAUDE_HOME/node_modules/.bin/agent-browser" ]]; then
            ab_bin="$CLAUDE_HOME/node_modules/.bin/agent-browser"
        fi
        if [[ -n "${ab_bin:-}" ]]; then
            local snap_out
            snap_out=$($ab_bin snapshot --cdp 9222 about:blank 2>&1) || true
            if echo "$snap_out" | grep -qi "snapshot\|root\|body\|html"; then
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] Agent browser connected to browser on port 9222" >> "$LOG_FILE"
            else
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] agent-browser ran but response unexpected — may still work. Output: $snap_out" >> "$LOG_FILE"
            fi
        else
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] agent-browser binary not found — skipping CDP check" >> "$LOG_FILE"
        fi
    else
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Browser not on port 9222 after 10s wait" >> "$LOG_FILE"
    fi
    ui_progress_bar "Checking everything works" "done"

    # ── Verify infrastructure services started correctly ──────────────────────
    # In container mode, skip systemd service checks — entrypoint.sh manages processes
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        ui_progress_bar "Background services" "done"
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Container mode: services managed by entrypoint.sh — skipping systemd checks" >> "$LOG_FILE"
    else
        ui_progress_bar "Background services" "running"
        local infra_services=("stealth-chrome" "claude-router" "openrouter-bridge")
        local failed_svcs=()
        for svc in "${infra_services[@]}"; do
            systemctl --user start "$svc" 2>/dev/null || true
            sleep 1
            local svc_state
            svc_state=$(systemctl --user is-active "$svc" 2>/dev/null || echo "unknown")
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Service $svc: $svc_state" >> "$LOG_FILE"
            if [[ "$svc_state" != "active" ]]; then
                failed_svcs+=("$svc ($svc_state)")
            fi
        done
        if [[ ${#failed_svcs[@]} -gt 0 ]]; then
            ui_progress_bar "Background services" "fail"
            ui_warn "Some background services didn't start: ${failed_svcs[*]}"
            ui_warn "This may fix itself on reboot. Check install.log if issues persist."
        else
            ui_progress_bar "Background services" "done"
        fi
    fi

    ui_blank
}

# Fallback: manually install Chrome/Chromium runtime libraries from apt
# Used when the google-chrome-stable .deb install fails or on non-amd64 arch
_install_chrome_deps_fallback() {
    local need_apt=()

    # Some packages were renamed with t64 suffix in Ubuntu 24.04 (time_t64 transition).
    # _pkg_or_t64 checks installed state and picks the right variant name for apt.
    _pkg_or_t64() {
        local pkg="$1"
        dpkg -s "$pkg"        &>/dev/null && return 0   # already installed
        dpkg -s "${pkg}t64"   &>/dev/null && return 0   # t64 variant already installed
        if apt-cache show "${pkg}t64" &>/dev/null 2>&1; then
            need_apt+=("${pkg}t64")
        else
            need_apt+=("$pkg")
        fi
    }

    dpkg -s libatk1.0-0        &>/dev/null || need_apt+=("libatk1.0-0")
    dpkg -s libatk-bridge2.0-0 &>/dev/null || need_apt+=("libatk-bridge2.0-0")
    _pkg_or_t64 "libcups2"
    dpkg -s libxcomposite1     &>/dev/null || need_apt+=("libxcomposite1")
    dpkg -s libxdamage1        &>/dev/null || need_apt+=("libxdamage1")
    dpkg -s libxfixes3         &>/dev/null || need_apt+=("libxfixes3")
    dpkg -s libxrandr2         &>/dev/null || need_apt+=("libxrandr2")
    dpkg -s libgbm1            &>/dev/null || need_apt+=("libgbm1")
    dpkg -s libcairo2          &>/dev/null || need_apt+=("libcairo2")
    dpkg -s libpango-1.0-0     &>/dev/null || need_apt+=("libpango-1.0-0")
    _pkg_or_t64 "libasound2"
    _pkg_or_t64 "libgtk-3-0"

    if [[ ${#need_apt[@]} -gt 0 ]]; then
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Installing ${#need_apt[@]} Chrome dependency packages from apt" >> "$LOG_FILE"
        set +e
        sudo apt-get install -y --no-install-recommends "${need_apt[@]}" >> "${LOG_FILE:-/dev/null}" 2>&1
        local apt_exit=$?
        set -e

        if [[ "$apt_exit" -ne 0 ]]; then
            return 1
        fi
    fi
}

# Install system-level systemd services
_deps_install_services() {
    local svc_dir="$CLAUDE_HOME/config/systemd"
    local gen_dir="$svc_dir/generated"
    local current_user="$USER"
    local user_home="$HOME"

    # Generate service files with actual paths substituted
    mkdir -p "$gen_dir"
    for tmpl in "$svc_dir"/*.service; do
        local basename
        basename=$(basename "$tmpl")
        sed "s|__USER__|$current_user|g; \
             s|__HOME__|$user_home|g; \
             s|__CLAUDE_HOME__|$CLAUDE_HOME|g" \
            "$tmpl" > "$gen_dir/$basename"
    done

    # Copy to system and reload (|| true: non-fatal if systemd unavailable)
    sudo cp "$gen_dir"/*.service /etc/systemd/system/ 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true

    # Allow passwordless restart of claudebot.service (needed for post-install
    # config changes) and stealth-chrome.service (needed by the unattended
    # nightly Chrome restart in core/nightly-review.sh — it runs from cron with
    # no TTY, so a password prompt would hang it).
    local sudoers_file="/etc/sudoers.d/claudebot"
    echo "$USER ALL=(ALL) NOPASSWD: /bin/systemctl restart claudebot.service, /bin/systemctl restart stealth-chrome.service" | \
        sudo tee "$sudoers_file" > /dev/null
    sudo chmod 440 "$sudoers_file"
}

# Export PATH updates persistently to shell profile
deps_update_shell_profile() {
    # Skip in container mode — shell profile is on read-only filesystem
    # and PATH is already set by the entrypoint
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        return 0
    fi

    local shell_rc="$HOME/.bashrc"
    [[ -f "$HOME/.zshrc" ]] && shell_rc="$HOME/.zshrc"
    local marker="# ${APP_SLUG:-taskramen}-paths"

    if ! grep -q "$marker" "$shell_rc" 2>/dev/null; then
        cat >> "$shell_rc" <<EOF

$marker
export CLAUDE_HOME="$CLAUDE_HOME"
export PATH="\$HOME/.bun/bin:\$HOME/.local/bin:\$HOME/bin:\$PATH"
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
alias proxy-on='\$CLAUDE_HOME/core/toggle-proxy.sh on'
alias proxy-off='\$CLAUDE_HOME/core/toggle-proxy.sh off'
EOF
    fi
}
