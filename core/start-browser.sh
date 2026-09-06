#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# Derive CLAUDE_HOME/HOME from this script's location (core/) so the script is
# self-sufficient and carries no hardcoded /home/<user> paths
# (CLAUDE.md: no hardcoded user paths). Falls back to inherited env if set.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CLAUDE_HOME="${CLAUDE_HOME:-$(dirname "$SCRIPT_DIR")}"
export HOME="${HOME:-$(dirname "$CLAUDE_HOME")}"

# 1. Start a lightweight window manager in the background (needed by Chrome in xvfb)
matchbox-window-manager 2>/dev/null &

# 2. Give the window manager a moment to initialize
sleep 1

# 3. Clean stale Chrome profile lock files from prior runs/crashes
rm -f "$CLAUDE_HOME/.chrome-profile"/SingletonLock "$CLAUDE_HOME/.chrome-profile"/SingletonSocket "$CLAUDE_HOME/.chrome-profile"/SingletonCookie 2>/dev/null || true

# 4. Start Chromium with DevTools, Mobile Emulation, and Stealth Flags
# Auto-detect chromium binary: prefer chromium-browser (Ubuntu), fall back to chromium (Debian)
CHROMIUM_BIN="${CHROMIUM_BIN:-$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || echo /usr/bin/chromium-browser)}"
# Fix for Chrome 128+: crashpad requires --database pointing to a writable dir.
# Setting XDG dirs ensures Chromium finds writable paths for crash reports.
export XDG_CONFIG_HOME=/tmp/.chromium
export XDG_CACHE_HOME=/tmp/.chromium
mkdir -p /tmp/.chromium
# Suppress stderr (dbus noise). Crashes are caught by monitor.sh and tmux pipe-pane log.
exec "$CHROMIUM_BIN" \
  --remote-debugging-port=9222 \
  --remote-debugging-address=127.0.0.1 \
  --user-data-dir="$CLAUDE_HOME/.chrome-profile" \
  --disk-cache-dir="$HOME/.cache/chromium" \
  --enable-logging=stderr --v=0 \
  --window-size=390,844 \
  --user-agent="Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1" \
  --disable-blink-features=AutomationControlled \
  --disable-infobars \
  --no-sandbox \
  --disable-setuid-sandbox \
  --disable-dev-shm-usage \
  --password-store=basic \
  --use-mock-keychain \
  --disable-gpu \
  --disable-features=IsolateOrigins,site-per-process,OptimizationHints,dbus \
  --disable-site-isolation-trials \
  --no-first-run \
  --no-default-browser-check \
  --disable-crash-reporter \
  --crash-dumps-dir=/tmp \
  --ignore-certificate-errors \
  2>/dev/null
