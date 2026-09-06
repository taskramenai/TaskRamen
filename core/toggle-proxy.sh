#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Determine CLAUDE_HOME dynamically
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="$(dirname "$SCRIPT_DIR")"

# Configuration
ENV_FILE="$CLAUDE_HOME/claudebot.env"
SERVICE_NAME="claudebot.service"
ROUTER_SERVICE="claude-router.service"
BRIDGE_SERVICE="openrouter-bridge.service"
PROXY_PORT="3456"

# Identity File
OAUTH_FILE="$HOME/.claude/.credentials.json"
OAUTH_BACKUP="$HOME/.claude/.credentials.json.backup"

# Helper: detect container mode
_is_container() {
    [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]
}

# Helper: restart claudebot — container or systemd
_restart_claudebot() {
    # Planned restart — keep monitor.sh's is_frozen from Telegramming a false
    # "Claude appears frozen" during the relaunch gap (issue #513). Default and
    # semantics match PLANNED_RESTART_STAMP in core/restart-lib.sh / monitor.sh
    # (same expansion, so an exported override lands in the same file).
    date +%s > "${PLANNED_RESTART_STAMP:-/tmp/claude_planned_restart}" 2>/dev/null || true
    if _is_container; then
        # Container mode: kill tmux session + restart run.sh directly
        tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
        sleep 2
        export CLAUDEBOT_LOG="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
        tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
        tmux -L claudebot pipe-pane -t claudebot "cat >> $CLAUDEBOT_LOG"
    else
        sudo systemctl restart $SERVICE_NAME
    fi
}

# Helper: start a service — container or systemd
_start_service() {
    local svc_name="$1"
    if _is_container; then
        case "$svc_name" in
            "$ROUTER_SERVICE")
                command -v ccr >/dev/null 2>&1 && ccr start &
                ;;
            "$BRIDGE_SERVICE")
                [[ -f "$CLAUDE_HOME/core/openrouter-bridge.py" ]] && python3 "$CLAUDE_HOME/core/openrouter-bridge.py" &
                ;;
        esac
    else
        sudo systemctl start "$svc_name"
    fi
}

# Helper: stop a service — container or systemd
_stop_service() {
    local svc_name="$1"
    if _is_container; then
        case "$svc_name" in
            "$ROUTER_SERVICE")
                pkill -f "ccr start" 2>/dev/null || true
                ;;
            "$BRIDGE_SERVICE")
                pkill -f "openrouter-bridge.py" 2>/dev/null || true
                ;;
        esac
    else
        sudo systemctl stop "$svc_name"
    fi
}

if [ "$1" == "on" ]; then
    echo "🚀 Switching to OpenRouter (Proxy) Mode..."

    _start_service "$ROUTER_SERVICE"

    if [ -f "$OAUTH_FILE" ]; then
        mv "$OAUTH_FILE" "$OAUTH_BACKUP"
        echo "📦 Claude Pro session stashed. (Identity hidden)"
    fi

    echo "ANTHROPIC_BASE_URL=http://127.0.0.1:$PROXY_PORT" > $ENV_FILE
    echo "ANTHROPIC_API_KEY=dummy-key" >> $ENV_FILE  # placeholder — real key not needed when routing through local proxy

    export ANTHROPIC_BASE_URL="http://127.0.0.1:$PROXY_PORT"
    export ANTHROPIC_API_KEY="dummy-key"  # placeholder — real key not needed when routing through local proxy

    _restart_claudebot

    # Start the Tmux Injector Bridge
    _start_service "$BRIDGE_SERVICE"
    echo "✅ OpenRouter active. Telegram Tmux Bridge STARTED."

elif [ "$1" == "off" ]; then
    echo "🏠 Switching back to Claude Pro Mode..."

    # Stop the proxy and the injector bridge
    _stop_service "$ROUTER_SERVICE"
    _stop_service "$BRIDGE_SERVICE"

    if [ -f "$OAUTH_BACKUP" ]; then
        mv "$OAUTH_BACKUP" "$OAUTH_FILE"
        echo "🔓 Claude Pro session restored."
    fi

    > $ENV_FILE
    unset ANTHROPIC_BASE_URL
    unset ANTHROPIC_API_KEY

    _restart_claudebot
    echo "✅ Claude Pro active. Native Telegram integration RESTORED."

else
    echo "Usage: proxy-on | proxy-off"
fi
