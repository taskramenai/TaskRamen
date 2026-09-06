#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

set -euo pipefail

# ── Container entrypoint for TaskRamen.ai ────────────────────────────
# Runs as ccuser (via USER in Containerfile + --userns=keep-id).
# Scheduling via supercronic (no root, no sudo).
# Claude Code runs directly as ccuser — no privilege issues.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_HOME="${CLAUDE_HOME:-$SCRIPT_DIR}"
# Derive HOME from CLAUDE_HOME's parent (matches run.sh/monitor.sh) instead of
# hardcoding a username path (CLAUDE.md: no hardcoded /home/<user> paths).
export HOME="${HOME:-$(dirname "$CLAUDE_HOME")}"
export CONTAINER=true
export TMUX_TMPDIR=/tmp
# Pin a clean TMPDIR base. Claude Code derives its per-process temp workspace as
# ${TMPDIR:-/tmp}/claude-<uid>/... and passes the deeper TMPDIR to its children;
# without a clean base the path compounds (claude-<uid>/claude-<uid>/…) and the
# agent-status-watcher's computed tasks dir no longer matches reality (issue #304).
export TMPDIR=/tmp
export GIT_CONFIG_GLOBAL="$CLAUDE_HOME/.gitconfig"
[ -f "$CLAUDE_HOME/core/branding.sh" ] && source "$CLAUDE_HOME/core/branding.sh" || true
# auth-mode.sh is side-effect-free (only defines functions + a default). It
# provides taskramen_creds_present(), used by the install-state checks below to
# detect a usable interactive-login credential the same way the installer does.
[ -f "$CLAUDE_HOME/core/auth-mode.sh" ] && source "$CLAUDE_HOME/core/auth-mode.sh" || true
# Tolerant .env loader (core/env-loader.sh). .env is read by load_env, which
# parses KEY=VALUE literally instead of `source`-ing the file as shell — so a
# value with spaces (e.g. the space-separated SERVICE_GOOGLE_WORKSPACE_RW_SCOPES) can
# never run as a command or, under `set -e`, kill PID 1 at boot. See issue #387
# / TaskRamenInstaller#118. Fallback keeps boot working on a partial tree.
[ -f "$CLAUDE_HOME/core/env-loader.sh" ] && source "$CLAUDE_HOME/core/env-loader.sh" || true
if ! declare -F load_env_file >/dev/null 2>&1; then
    load_env_file() {
        [[ -n "${1:-}" && -f "$1" ]] || return 0
        local _e; case $- in *e*) _e=1 ;; *) _e=0 ;; esac
        set +e; set -a; source "$1" 2>/dev/null; set +a
        [[ "$_e" == 1 ]] && set -e
        return 0
    }
    load_env() { load_env_file "${CLAUDE_HOME:-}/.env"; return 0; }
fi
# Package caches live on the persistent bind mount, NOT the 512MB /tmp tmpfs that
# Chrome also uses — the npm cache (~149M) would otherwise fill /tmp and crash the
# browser (issue #305).
mkdir -p "$CLAUDE_HOME/.cache/npm" || true
export npm_config_cache="$CLAUDE_HOME/.cache/npm"

# ── Load nvm ────────────────────────────────────────────────────────
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true
# $CLAUDE_HOME/.npm-global/bin holds the runtime-installed Claude Code CLI.
# Claude Code is proprietary / not redistributable, so it is NOT baked into the
# image (see Containerfile); it is pulled at first run into the persistent bind
# mount — the only writable location that survives a container recreate. This
# dir must lead the PATH so run.sh/monitor.sh resolve `claude` here instead of
# falling through to `bunx claude` (which re-downloads CC into /tmp every call).
export PATH="$CLAUDE_HOME/.npm-global/bin:$HOME/.nvm/bin:$HOME/.bun/bin:$HOME/.local/bin:$HOME/bin:$PATH"

# ── Ensure npm dependencies are installed ───────────────────────────
_ensure_deps() {
    if [[ ! -d "$CLAUDE_HOME/node_modules" ]]; then
        echo "[entrypoint] Installing npm dependencies..."
        cd "$CLAUDE_HOME" && PUPPETEER_SKIP_DOWNLOAD=true PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true npm install >/dev/null 2>&1 || true
    fi
    if [[ -d "$CLAUDE_HOME/core/webhook-channel" && ! -d "$CLAUDE_HOME/core/webhook-channel/node_modules" ]]; then
        echo "[entrypoint] Installing webhook-channel dependencies..."
        cd "$CLAUDE_HOME/core/webhook-channel" && npm install --production >/dev/null 2>&1 || true
    fi
}

# ── Ensure Claude Code CLI is installed ─────────────────────────────
# Claude Code is proprietary and not redistributable, so it is never baked into
# the image. Pull it at runtime into the persistent bind mount the first time a
# container boots (and again after an image upgrade that recreates the
# container, where the wizard won't re-run because the install is already
# "complete"). Idempotent: no-op once $CLAUDE_HOME/.npm-global/bin/claude exists.
_ensure_claude_code() {
    if command -v claude >/dev/null 2>&1; then
        return 0
    fi
    local prefix="$CLAUDE_HOME/.npm-global"
    [[ -x "$prefix/bin/claude" ]] && return 0
    echo "[entrypoint] Installing Claude Code CLI (not bundled in image)..."
    mkdir -p "$prefix"
    # Capture stderr so a first-run install failure is diagnosable; stays quiet
    # on success.
    local err_log
    err_log=$(mktemp 2>/dev/null || echo "/tmp/_cc-install-err-$$")
    npm install -g --prefix "$prefix" @anthropic-ai/claude-code >/dev/null 2>"$err_log" || true
    if [[ -x "$prefix/bin/claude" ]]; then
        echo "[entrypoint] Claude Code CLI installed."
    else
        echo "[entrypoint] WARNING: Claude Code CLI install failed — will retry on next start."
        cat "$err_log" >&2 2>/dev/null || true
    fi
    rm -f "$err_log" 2>/dev/null || true
}

# ── Ensure Claude config directory exists ───────────────────────────
_ensure_claude_config() {
    mkdir -p "$CLAUDE_HOME/.claude" 2>/dev/null || true
    mkdir -p "$CLAUDE_HOME/.chrome-profile" 2>/dev/null || true

    # Ensure Telegram plugin is available
    local plugin_dir="$CLAUDE_HOME/.claude/plugins/marketplaces/claude-plugins-official"
    if [[ ! -d "$plugin_dir" ]]; then
        echo "[entrypoint] Installing Telegram plugin..."
        # Retry the clone with backoff so a transient github blip doesn't leave
        # the plugin missing until the next start (telegram MCP can't connect).
        local _delay=2 _a
        for _a in 1 2 3 4; do
            # Clear any partial clone; guard the rm to the intended path.
            if [[ "$plugin_dir" == */claude-plugins-official ]]; then
                rm -rf "$plugin_dir" 2>/dev/null || true
            fi
            mkdir -p "$CLAUDE_HOME/.claude/plugins/marketplaces"
            if git clone --depth 1 --filter=blob:none --sparse \
                    https://github.com/anthropics/claude-plugins-official.git \
                    "$plugin_dir" 2>/dev/null; then
                break
            fi
            if [[ $_a -lt 4 ]]; then
                sleep "$_delay"
                _delay=$((_delay * 2))
            fi
        done
        if [[ -d "$plugin_dir/.git" ]]; then
            cd "$plugin_dir" && git sparse-checkout set .claude-plugin external_plugins/telegram 2>/dev/null || true
        fi
    fi

    # Self-heal Telegram plugin dependencies. The plugin's start script runs
    # `bun install && bun server.ts` on every MCP spawn; if a claudebot
    # restart ever lands mid-install, bun's global cache keeps the damage and
    # every later spawn rebuilds the same broken node_modules — the telegram
    # MCP then fails to connect on every session with the error swallowed.
    # Verify by booting server.ts with no token against a scratch HOME:
    # reaching its "TELEGRAM_BOT_TOKEN required" check proves all imports
    # resolve, and without a token it exits immediately (never polls). On
    # failure, clear bun's cache and reinstall from the network.
    # bun exits non-zero here BY DESIGN (missing token) — under this script's
    # `set -o pipefail` that would fail the pipeline even when grep matches,
    # so neutralise bun's status; grep's match is the only signal we want.
    _tg_plugin_imports_ok() {
        local dir="$1" scratch ok=1
        # Guarded: /tmp is a small tmpfs that can fill up; an empty $scratch
        # must not reach HOME= or rm -rf below
        scratch=$(mktemp -d) || return 1
        if (cd "$dir" && { env -u TELEGRAM_BOT_TOKEN HOME="$scratch" \
                timeout 30 bun server.ts 2>&1 || true; } \
                | grep -q "TELEGRAM_BOT_TOKEN required"); then
            ok=0
        fi
        rm -rf "$scratch" 2>/dev/null || true
        return $ok
    }
    local tg_cache_dir
    # `|| true`: under set -e/pipefail an empty glob (fresh container, plugin
    # not installed yet) would otherwise abort the entrypoint here.
    # -t (newest first): if an upgrade left multiple version dirs cached,
    # verify the freshly installed one, not the lexically-first leftover.
    tg_cache_dir=$(ls -dt "$CLAUDE_HOME/.claude/plugins/cache/claude-plugins-official/telegram"/*/ 2>/dev/null | head -1 || true)
    if command -v bun >/dev/null 2>&1 && [[ -n "$tg_cache_dir" && -f "${tg_cache_dir%/}/server.ts" ]]; then
        tg_cache_dir="${tg_cache_dir%/}"
        if ! _tg_plugin_imports_ok "$tg_cache_dir"; then
            echo "[entrypoint] Telegram plugin deps broken — clearing bun cache and reinstalling..."
            rm -rf "$tg_cache_dir/node_modules" "$HOME/.bun/install/cache" 2>/dev/null || true
            (cd "$tg_cache_dir" && timeout 180 bun install --force --no-summary >/dev/null 2>&1) || true
            if _tg_plugin_imports_ok "$tg_cache_dir"; then
                echo "[entrypoint] Telegram plugin deps repaired."
            else
                echo "[entrypoint] WARNING: Telegram plugin deps still broken — telegram MCP may fail to connect."
            fi
        fi
    fi
}

# ── Child process tracking ──────────────────────────────────────────
CHILD_PIDS=()

cleanup() {
    # Guard against recursive calls — exit 0 below re-triggers EXIT trap
    [[ "${_CLEANUP_DONE:-}" == "1" ]] && return
    _CLEANUP_DONE=1
    echo "[entrypoint] Shutting down child processes..."
    for pid in "${CHILD_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
    wait 2>/dev/null || true
    echo "[entrypoint] Cleanup complete"
    exit 0
}

trap cleanup EXIT INT TERM
trap '' HUP  # Ignore SIGHUP so closing the terminal doesn't kill the container

# ── Load environment ────────────────────────────────────────────────
load_env

# ── Ensure all scripts are executable ───────────────────────────────
find "$CLAUDE_HOME" -name "*.sh" -type f -exec chmod +x {} + 2>/dev/null || true

# ── Publish Claude Code skills ──────────────────────────────────────
# .claude/skills/ entries are generated from .agents/skills/ rather than
# committed (git symlinks check out as plain text files on Windows). Run on
# every boot so a skill added by an image/code update is picked up without
# re-running the installer. Idempotent and never fails.
"$CLAUDE_HOME/core/link-skills.sh" 2>&1 | sed 's/^/[entrypoint] /' || true

# ── First-run setup ────────────────────────────────────────────────
_ensure_deps
_ensure_claude_code
_ensure_claude_config

# ── Install state validation ───────────────────────────────────────
INSTALL_STATE_FILE="$CLAUDE_HOME/.install-complete"

# Split into two checks:
#   _check_install_critical -- the FUNCTIONAL requirements (telegram +
#       claude auth). If any are missing, the bot literally cannot
#       operate; we hold the user at the pairing terminal.
#   _check_install_state    -- the FULL completeness check (functional
#       items + settings + sentinel). Used to decide whether to run
#       install.sh and whether to print "incomplete" warnings.
#
# The "safe to close" message + .auth-complete marker now gate on the
# CRITICAL check rather than the full check. Rationale: settings.json
# and the .install-complete sentinel are install-bookkeeping artifacts;
# their absence means the install record is incomplete but does not
# stop claudebot from running. If we made the user wait for those, a
# settings.json that drifted (or got wiped, like on every container
# recreate -- it's not in the bind mount) would lock the user out of
# the "safe to close" path forever, even though Telegram + Claude
# auth are perfectly functional. The orchestrator polls .auth-complete
# to know it can advance to step 9; missing settings shouldn't
# permanently block that handoff.
_check_install_critical() {
    local missing=()
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || ! grep -q "TELEGRAM_BOT_TOKEN" "$CLAUDE_HOME/.env" 2>/dev/null; then
        missing+=("telegram")
    fi
    if [[ -z "${TELEGRAM_CHAT_ID:-}" ]] || ! grep -q "TELEGRAM_CHAT_ID" "$CLAUDE_HOME/.env" 2>/dev/null; then
        missing+=("telegram_chat")
    fi
    # Claude auth: an uncommented token in .env (setup-token flow) OR a usable
    # interactive-login credential (TUI login flow). taskramen_creds_present()
    # validates every credentials.json path AND a non-empty OAuth token field,
    # so a truncated/empty creds file no longer counts. The token grep is
    # anchored (`^...=.`) so a login-mode .env — which COMMENTS the token out —
    # is judged by the credential check, not by a bare substring match on the
    # commented line. Matches install.sh's _install_critical_ok exactly.
    if ! grep -qE "^CLAUDE_CODE_OAUTH_TOKEN=." "$CLAUDE_HOME/.env" 2>/dev/null && \
       ! taskramen_creds_present; then
        missing+=("claude_auth")
    fi
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    else
        echo "[entrypoint] Install missing critical items: ${missing[*]}"
        return 1
    fi
}

_check_install_state() {
    local missing=()
    if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]] || ! grep -q "TELEGRAM_BOT_TOKEN" "$CLAUDE_HOME/.env" 2>/dev/null; then
        missing+=("telegram")
    fi
    if [[ -z "${TELEGRAM_CHAT_ID:-}" ]] || ! grep -q "TELEGRAM_CHAT_ID" "$CLAUDE_HOME/.env" 2>/dev/null; then
        missing+=("telegram_chat")
    fi
    # Claude auth: uncommented token OR usable login credential — same logic and
    # rationale as _check_install_critical above (kept identical on purpose).
    if ! grep -qE "^CLAUDE_CODE_OAUTH_TOKEN=." "$CLAUDE_HOME/.env" 2>/dev/null && \
       ! taskramen_creds_present; then
        missing+=("claude_auth")
    fi
    if [[ -f "$CLAUDE_HOME/.claude/settings.json" ]]; then
        if ! grep -q "skipDangerousModePermissionPrompt" "$CLAUDE_HOME/.claude/settings.json" 2>/dev/null; then
            missing+=("settings")
        fi
    else
        missing+=("settings")
    fi
    if [[ ! -f "$INSTALL_STATE_FILE" ]]; then
        missing+=("sentinel")
    fi
    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    else
        echo "[entrypoint] Install incomplete — missing: ${missing[*]}"
        return 1
    fi
}

# FORCE_INSTALL=1 is baked into the container env by the installer. To prevent
# it from re-triggering on every container restart, we track which container
# (by hostname) already ran the forced install.
_should_force_install() {
    [[ "${FORCE_INSTALL:-}" != "1" ]] && return 1
    local marker="$CLAUDE_HOME/.force-install-done"
    [[ -f "$marker" ]] && [[ "$(cat "$marker" 2>/dev/null)" == "$(hostname)" ]] && return 1
    return 0
}

if ! _check_install_state || _should_force_install; then
    echo "[entrypoint] Running install wizard..."
    # Pre-clean any stale auth-complete marker from a prior install. This is
    # belt-and-suspenders alongside the orchestrator's `podman machine ssh rm
    # -f` pre-clean — covers manual container restarts and any code path
    # that invokes entrypoint.sh without going through the orchestrator.
    # We delete it ONLY in the run-the-wizard branch; on no-op container
    # restarts the existing marker continues to reflect a valid install.
    rm -f "$CLAUDE_HOME/.auth-complete" 2>/dev/null || true
    "$CLAUDE_HOME/install.sh" || true
    load_env
    # Mark this container as having completed the forced install
    if [[ "${FORCE_INSTALL:-}" == "1" ]]; then
        # Bookkeeping only (suppresses re-running the forced install next boot).
        # A write failure must not abort boot — worst case the wizard re-runs.
        hostname > "$CLAUDE_HOME/.force-install-done" 2>/dev/null || true
    fi
    if ! _check_install_state; then
        echo "[entrypoint] WARNING: Install may be incomplete. Some features may not work."
        echo "[entrypoint] To re-run the installer, delete $INSTALL_STATE_FILE and restart."
    fi
fi

# After install is complete enough to function (Telegram + Claude auth
# present), ignore Ctrl+C and terminal close so the container stays
# alive regardless of what the user does with the terminal.
#
# Gates on _check_install_critical, NOT _check_install_state. See the
# function comment for the rationale -- the short version is that
# settings.json gets wiped on every container recreate (it's not in
# the bind mount), and a freshly-wiped settings.json shouldn't lock
# the user out of the "safe to close" path when Telegram + Claude
# auth are working fine. If non-critical items are missing, we still
# advise the user about it but proceed.
if _check_install_critical; then
    trap '' HUP INT TERM
    trap cleanup EXIT
    # Auth-complete marker for the Windows Inno orchestrator. The orchestrator
    # polls for this file via `podman exec` so it can reliably detect that
    # telegram pairing + claude auth finished successfully in this run,
    # without relying on the user closing the pairing terminal.
    touch "$CLAUDE_HOME/.auth-complete" 2>/dev/null || true
    echo ""
    echo "============================================="
    echo "  You can close this window now."
    echo "  ${PRODUCT_NAME:-TaskRamen.ai} will run in the background."
    echo "============================================="
    if ! _check_install_state; then
        echo ""
        echo "  Note: some non-critical install items are missing"
        echo "  (see 'Install incomplete' line above). The bot is"
        echo "  functional; this won't block you closing the window."
    fi
    echo ""

    # ── Detach file descriptors from terminal (defense-in-depth) ────────
    # Primary protection: --sig-proxy=false on `podman run` prevents
    # SIGTERM from reaching PID 1 when the terminal closes, and TERM is
    # ignored by the trap above.
    # Secondary: redirect stdin/stdout/stderr away from the TTY so that
    # closing the terminal doesn't cause EIO errors on stale file
    # descriptors.
    # - exec </dev/null: stdin no longer reads from TTY
    # - exec >>log 2>&1: output goes to log file (debuggable, not lost)
    ENTRYPOINT_LOG="${CLAUDE_HOME}/entrypoint.log"
    exec </dev/null
    if [[ -z "${DEBUG:-}" ]]; then
        # Redirect stdout/stderr to the log — but NEVER let an unwritable log
        # (bind mount full / read-only / wrong perms) terminate PID 1 here. A
        # failed `exec` redirect exits a non-interactive shell on its own,
        # independent of set -e. Probe first, fall back to /dev/null. Mirrors the
        # established pattern in core/nightly-review.sh. The log destination is
        # diagnostic only; its absence must not be fatal.
        # 2>/dev/null FIRST: a failed redirect reports to the current stderr
        # before a later 2>/dev/null would take effect, so order it ahead of the
        # >> to keep the probe silent when the log is unwritable.
        if : 2>/dev/null >>"$ENTRYPOINT_LOG"; then
            exec >>"$ENTRYPOINT_LOG" 2>&1
        else
            exec >/dev/null 2>&1
        fi
    fi
fi

# ── Disable ALL strict modes for service startup and keep-alive ──────
# All critical setup (install, config, validation) is done above.
# set -e: command failure exits script (disabled: background services can fail)
# set -u: unset variable exits script (disabled: sourced scripts may have unset vars)
# set -o pipefail: pipe failure exits script (disabled: filtered pipes may fail)
set +euo pipefail

# ── Set file permissions ─────────────────────────────────────────────
chmod 600 "$CLAUDE_HOME/.env" 2>/dev/null || true
chmod 600 "$CLAUDE_HOME/personalinfo.md" 2>/dev/null || true

# ── Start supercronic (rootless cron replacement) ───────────────────
touch "$CLAUDE_HOME/.crontab" 2>/dev/null || true
supercronic -inotify "$CLAUDE_HOME/.crontab" &
CHILD_PIDS+=($!)
echo "[entrypoint] supercronic started"

# ── Start Chromium under Xvfb ──────────────────────────────────────
echo "[entrypoint] Starting Chromium under Xvfb..."
export DISPLAY=:99
# NOTE: stderr filter here does NOT work — xvfb-run forks internally so Chromium
# inherits the original pty fd, bypassing this redirect. Fix needs to be in
# start-browser.sh instead (replace exec with run+wait+pipe). See container docs.
xvfb-run --server-num=99 -s "-screen 0 1920x1080x24" \
    -f /tmp/.Xauthority \
    "$CLAUDE_HOME/core/start-browser.sh" \
    2> >(grep --line-buffered -v -E \
        'Failed to connect to the bus|Floss manager|UPower|dri3 extension not supported|InitializeSandbox.*multiple threads|DEPRECATED_ENDPOINT|Failed to call method.*NameHasOwner|PropertiesChanged|idle_linux|gpu_memory_buffer' \
    >&2) &
CHILD_PIDS+=($!)
echo "[entrypoint] Chromium PID: ${CHILD_PIDS[-1]}"

# Wait for Xvfb display to be ready (X socket appears in /tmp/.X11-unix/)
for _i in $(seq 1 10); do
    if [[ -e /tmp/.X11-unix/X99 ]]; then
        echo "[entrypoint] Xvfb display :99 ready"
        break
    fi
    sleep 1
done

# Wait for Chromium to be ready on port 9222
for _i in $(seq 1 15); do
    if curl -sf http://127.0.0.1:9222/json/version >/dev/null 2>&1; then
        echo "[entrypoint] Chromium CDP ready on port 9222"
        break
    fi
    sleep 1
done

# ── Start monitor.sh ───────────────────────────────────────────────
# claudebot.env via the same tolerant loader (issue #387). This runs after
# `set +euo pipefail` so it is not a crash vector, but parsing it literally
# keeps any space-containing value correct and consistent with .env handling.
# Loaded here (not in the claudebot section below) because it may set
# CLAUDEBOT_LOG, which must be resolved before the monitor starts.
load_env_file "$CLAUDE_HOME/claudebot.env"

# Resolve CLAUDEBOT_LOG BEFORE starting monitor.sh so the watchdog inherits
# the SAME pane-log path the tmux pipe-pane below writes to. This used to be
# exported only in the "Start Claude bot" section further down — monitor.sh,
# already running by then, never saw it and fell back to its own
# /tmp/claudebot.log default, so TASK 1 (usage-limit detection) silently
# grepped a nonexistent file and never alerted on a real session limit while
# the banner sat in the pane the whole time.
export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/var/log/claudebot.log}"
touch "$CLAUDEBOT_LOG" 2>/dev/null || export CLAUDEBOT_LOG="/tmp/claudebot.log"

echo "[entrypoint] Starting monitor watchdog..."
"$CLAUDE_HOME/core/monitor.sh" &
CHILD_PIDS+=($!)

# ── Start Claude Router (if OPENROUTER_API_KEY is set) ─────────────
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
    if command -v ccr >/dev/null 2>&1; then
        echo "[entrypoint] Starting Claude Code Router..."
        ccr start &
        CHILD_PIDS+=($!)
    fi
    if [[ -f "$CLAUDE_HOME/core/openrouter-bridge.py" ]]; then
        echo "[entrypoint] Starting OpenRouter bridge..."
        python3 "$CLAUDE_HOME/core/openrouter-bridge.py" &
        CHILD_PIDS+=($!)
    fi
fi

# ── Start Claude bot (foreground via tmux) ──────────────────────────
echo "[entrypoint] Starting Claude bot in tmux session..."

# claudebot.env and CLAUDEBOT_LOG are resolved in the monitor.sh section
# above, before the watchdog starts, so it and this pipe-pane agree on the
# pane-log path.

tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"

# Auto-accept first-run prompts (theme selector, etc.)
(
    for _i in $(seq 1 30); do
        sleep 2
        pane_output=$(tmux -L claudebot capture-pane -t claudebot -p 2>/dev/null || true)
        if echo "$pane_output" | grep -q "Choose the text style\|looks best with your terminal"; then
            sleep 1
            tmux -L claudebot send-keys -t claudebot Enter 2>/dev/null || true
            echo "[entrypoint] Auto-accepted theme prompt"
            break
        fi
        if echo "$pane_output" | grep -q "What can I help you with\|Claude Code"; then
            break
        fi
    done
) &

# ── Health check after services have had time to start ─────────────
(
    sleep 15
    source "$CLAUDE_HOME/install/ui.sh" 2>/dev/null || true
    source "$CLAUDE_HOME/install/utils.sh" 2>/dev/null || true
    source "$CLAUDE_HOME/install/services.sh" 2>/dev/null || true
    if type services_health_check &>/dev/null; then
        if ! services_health_check; then
            echo "[entrypoint] WARNING: Some services may not be running"
        else
            echo "[entrypoint] All services healthy"
        fi
    fi
) &

# Keep container alive forever — monitor.sh handles Claude restarts.
# Container only exits on explicit stop (podman stop → SIGTERM ignored, then SIGKILL after timeout).
echo "[entrypoint] Claude bot running. Container will stay alive until explicitly stopped."
while true; do
    sleep 60 || true
done
