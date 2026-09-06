#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# PostToolUse hook (matcher: TaskStop) — flags a deliberately-stopped agent so
# its status watcher exits silently instead of escalating to stale
# "may be frozen"/"appears FROZEN" alerts (issue #437).
#
# Touches /tmp/agent_stopped_<task_id>.flag; agent-status-watcher.sh derives
# the same path from its output file's basename (<task_id>.output) and treats
# the flag as "agent gone — exit with no injection". The watcher removes the
# flag on exit; run.sh's watcher reaping covers the rest, so a leftover flag
# can never suppress a future task (ids are unique).
#
# MAINTENANCE: registered under BOTH PostToolUse and PostToolUseFailure
# (matcher: "TaskStop") in ~/.claude/settings.json by install/config.sh — see
# config_generate(). Per the hooks docs, PostToolUse fires only when the tool
# call SUCCEEDS; a failed TaskStop (unknown id / task already finished —
# exactly the stale case) fires PostToolUseFailure instead, hence the dual
# registration. If TaskStop turns out not to emit tool hooks at all on some
# Claude Code version, nothing breaks — the watcher's other gone signal
# (output file vanished) and the staleness check baked into the frozen
# trigger texts still prevent stale alerts. If you rename or move this
# script, update install/config.sh (hook entries and OUR_SCRIPTS) and the
# flag-path derivation in core/agent-status-watcher.sh.

read -r -d '' PAYLOAD || true

TASK_ID=$(printf '%s' "$PAYLOAD" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', {})
    if not isinstance(inp, dict):
        inp = {}
    # task_id is the current parameter; shell_id is its deprecated alias
    print(inp.get('task_id') or inp.get('shell_id') or '')
except Exception:
    pass
" 2>/dev/null)

# Sanitize to filename-safe chars — MUST match the charset used when
# agent-status-watcher.sh derives the flag path from its output filename.
TASK_ID="${TASK_ID//[^a-zA-Z0-9._@-]/}"
[ -n "$TASK_ID" ] || exit 0

touch "/tmp/agent_stopped_${TASK_ID}.flag" 2>/dev/null || true
exit 0
