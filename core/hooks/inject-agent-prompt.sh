#!/usr/bin/env bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# PreToolUse hook: inject agentprompt.md rules into every Agent tool call.
# Reads JSON from stdin. If tool_name == "Agent", prepends rules to the prompt field.
#
# MAINTENANCE: This script is registered as a PreToolUse hook (matcher: "Agent",
# sync) in ~/.claude/settings.json. It is injected during install by
# install/config.sh — see the config_generate() function, specifically the
# Python block that writes data["hooks"] (around line 53-66).
# If you rename, move, change args, or change sync/async behaviour of this script,
# you MUST update the corresponding entry in install/config.sh.

set -euo pipefail

CLAUDE_HOME="${CLAUDE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RULES_FILE="$CLAUDE_HOME/core/agentprompt.md"

# Read stdin
INPUT=$(cat)

# Extract tool name
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

# Only modify Agent tool calls
if [ "$TOOL_NAME" != "Agent" ]; then
  exit 0
fi

# Check rules file exists
if [ ! -f "$RULES_FILE" ]; then
  exit 0
fi

RULES=$(cat "$RULES_FILE")

# Read original prompt from tool_input
ORIGINAL_PROMPT=$(echo "$INPUT" | jq -r '.tool_input.prompt // empty')

# Prepend rules to prompt
NEW_PROMPT=$(printf '%s\n\n---\n\n%s' "$RULES" "$ORIGINAL_PROMPT")

# Output modified input — only override the prompt field, preserve everything else.
# Schema per https://code.claude.com/docs/en/hooks: PreToolUse input rewriting is
# hookSpecificOutput.updatedInput, and permissionDecision is required alongside it
# ("allow" changes nothing here — Agent calls run unattended/auto-approved in this
# headless setup). Any other output shape is silently ignored by Claude Code and
# the agent spawns with the raw, guardrail-free prompt (issue #484).
echo "$INPUT" | jq --arg new_prompt "$NEW_PROMPT" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: (.tool_input | .prompt = $new_prompt)
  }
}'
