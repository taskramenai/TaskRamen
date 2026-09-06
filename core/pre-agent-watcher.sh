#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# PreToolUse hook — starts agent-status-watcher.sh BEFORE the agent runs.
# Receives Claude Code hook JSON via stdin.
#
# MAINTENANCE: This script is registered as a PreToolUse hook (matcher: "Agent",
# async: true) in ~/.claude/settings.json. It is injected during install by
# install/config.sh — see the config_generate() function.
# If you rename, move, change args, or change async behaviour of this script,
# you MUST update the corresponding entry in install/config.sh.
#
# LIFECYCLE: run.sh kills any live pre-agent-watcher.sh / agent-status-watcher.sh
# processes pre-launch on every Claude (re)start — a hook still in its 60s wait
# (or a detached watcher) at that point belongs to the dead instance and would
# otherwise false-alarm "frozen" on the previous session's agents. If you rename
# this script, update run.sh's _kill_stale_agent_watchers pkill pattern.

if [ -z "$CLAUDE_HOME" ]; then
    echo "$(date): ERROR: CLAUDE_HOME is not set — cannot start watcher" >> /tmp/auto-watcher-debug.log
    exit 0
fi

read -r -d '' PAYLOAD || true

# Parse tasks directory and label from the pre-tool input.
# Output is written to a temp file (not eval'd) to avoid injection risks.
PARSE_OUT=$(mktemp /tmp/watcher_parse_XXXXXX.txt)
echo "$PAYLOAD" | CLAUDE_HOME="$CLAUDE_HOME" python3 -c "
import json, sys, os
try:
    d = json.load(sys.stdin)
    inp = d.get('tool_input', {})
    session_id = d.get('session_id', '')
    uid = os.getuid()
    claude_home = os.environ.get('CLAUDE_HOME', '')
    path_slug = claude_home.replace('/', '-')
    desc = inp.get('description', '')
    label = desc[:40] if desc else 'background agent'
    tasks_dir = ''
    if session_id and path_slug:
        # Claude Code writes agent output under
        #   \${TMPDIR:-/tmp}/claude-<uid>/<slug>/<session>/tasks
        # A polluted/nested TMPDIR (repeated claude-<uid> segments) shifts the
        # real directory deeper than the canonical single-level path, so probe
        # candidates in priority order and pick the first that exists (issue #304).
        rel = f'{path_slug}/{session_id}/tasks'
        candidates = []
        tmpdir = os.environ.get('TMPDIR', '').rstrip('/')
        if tmpdir:
            candidates.append(f'{tmpdir}/{rel}')
        # /tmp + N repeated claude-<uid> levels (canonical at N=1, then nested)
        for n in range(1, 7):
            candidates.append('/tmp/' + (f'claude-{uid}/' * n) + rel)
        canonical = f'/tmp/claude-{uid}/{rel}'
        for c in candidates:
            if os.path.isdir(c):
                tasks_dir = c
                break
        # Fall back to the canonical path so the hook's 60s wait-loop can still
        # poll for a dir that may be created moments after this hook fires
        # (correct once the TMPDIR pin keeps the base clean).
        if not tasks_dir:
            tasks_dir = canonical
    # Write tab-separated values (no shell metacharacters in output format)
    # Format: TASKS_DIR<tab>LABEL
    print(f'{tasks_dir}\t{label}')
except Exception:
    print('\t')
" 2>/dev/null > "$PARSE_OUT"

# Read parsed values from temp file (safe: no eval)
IFS=$'\t' read -r TASKS_DIR LABEL < "$PARSE_OUT"
rm -f "$PARSE_OUT"

# Sanitize: strip any characters that could cause issues in shell or filenames
TASKS_DIR="${TASKS_DIR//[^a-zA-Z0-9\/._-]/}"

# Sanitize LABEL: strip characters that could cause issues when passed as tmux keystrokes
LABEL="${LABEL//[^a-zA-Z0-9 ._-]/}"
LABEL="${LABEL:0:60}"  # cap at 60 chars

echo "$(date): PRE TASKS_DIR=$TASKS_DIR LABEL=$LABEL" >> /tmp/auto-watcher-debug.log

# Only start watcher if we derived a valid tasks directory
if [ -z "$TASKS_DIR" ] || [ "$TASKS_DIR" = "None" ]; then
    exit 0
fi

if [[ "$TASKS_DIR" != /tmp/* ]] && [[ "$TASKS_DIR" != /home/* ]]; then
    exit 0
fi

# Snapshot existing .output files before agent launches, then wait for a new one
BEFORE_FILES=$(ls "$TASKS_DIR"/*.output 2>/dev/null | LC_ALL=C sort)
WAIT=0
OUTPUT_FILE=""
while [ "$WAIT" -lt 60 ]; do
    sleep 1
    WAIT=$((WAIT + 1))
    AFTER_FILES=$(ls "$TASKS_DIR"/*.output 2>/dev/null | LC_ALL=C sort)
    # Find new files (in AFTER but not in BEFORE)
    NEW_FILES=$(LC_ALL=C comm -13 <(echo "$BEFORE_FILES") <(echo "$AFTER_FILES"))
    if [ -n "$NEW_FILES" ]; then
        # Accept symlinks immediately; accept regular files once size > 0.
        # Skip 0-byte stubs (ephemeral placeholders created before real output).
        for _f in $NEW_FILES; do
            _valid=""
            if [ -L "$_f" ]; then
                _valid=1
            elif [ -f "$_f" ]; then
                # wc -c, not stat -c%s: portable across GNU and BSD/macOS
                # coreutils (same rationale as agent-status-watcher.sh).
                _sz=$( { wc -c < "$_f"; } 2>/dev/null || echo 0)
                [ "$_sz" -gt 0 ] && _valid=1
            fi
            [ -n "$_valid" ] || continue
            # One watcher per output file (issue #451): two Agent calls in
            # quick succession run two instances of this hook, and both can
            # see the SAME first-appearing .output file as "new" relative to
            # their snapshots — attaching two watchers to one agent (duplicate
            # completion/status pings) and none to the other. Claim the file
            # atomically (noclobber create keyed on the full path, which is
            # session-unique) before accepting; a lost claim means another
            # hook instance owns this file — keep waiting for our own agent's
            # file to appear. Claims are never removed: removing on watcher
            # exit would let a hook still in this wait loop re-claim a
            # finished agent's file and re-emit its completion trigger.
            # Hash portably: md5sum (GNU) first, python3 hashlib as fallback
            # (macOS has no md5sum; python3 is already a hard dependency of
            # this hook). cut tolerates both "hash  -" and bare-hash outputs.
            _hash=$(printf '%s' "$_f" | { md5sum 2>/dev/null \
                || python3 -c 'import sys,hashlib;print(hashlib.md5(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null; } \
                | cut -d' ' -f1)
            if [ -z "$_hash" ]; then
                # No hash → no usable claim key. An empty key would make every
                # hook compete for the same flag file and permanently block all
                # future watchers, so FAIL OPEN instead: accept the file
                # unclaimed (pre-claim behavior — rare duplicate watcher
                # possible, watchers never silently lost).
                OUTPUT_FILE="$_f"
                break
            fi
            _claim="/tmp/watcher_claim_${_hash}.flag"
            if ( set -o noclobber; : > "$_claim" ) 2>/dev/null; then
                OUTPUT_FILE="$_f"
                break
            fi
        done
        [ -n "$OUTPUT_FILE" ] && break
    fi
done

if [ -z "$OUTPUT_FILE" ]; then
    # Check if there were new files but all were non-symlinks
    AFTER_FINAL=$(ls "$TASKS_DIR"/*.output 2>/dev/null | LC_ALL=C sort)
    ALL_NEW=$(LC_ALL=C comm -13 <(echo "$BEFORE_FILES") <(echo "$AFTER_FINAL"))
    if [ -n "$ALL_NEW" ]; then
        echo "$(date): PRE WARNING: new output files found but all were 0-byte stubs: $ALL_NEW" >> /tmp/auto-watcher-debug.log
    fi
    echo "$(date): PRE no valid output file found after 60s (0-byte stubs skipped)" >> /tmp/auto-watcher-debug.log
    exit 0
fi

echo "$(date): PRE discovered OUTPUT_FILE=$OUTPUT_FILE" >> /tmp/auto-watcher-debug.log

# Start watcher in background — detached so it outlives this hook call.
# Keep the `bash <path>` invocation shape: run.sh's _kill_stale_agent_watchers
# matches argv[0]=bash + script path to reap stale watchers on relaunch.
LOG_FILE="/tmp/watcher-$(date +%s).log"
nohup bash "$CLAUDE_HOME/core/agent-status-watcher.sh" "$OUTPUT_FILE" "$LABEL" "$LOG_FILE" \
    > "$LOG_FILE" 2>&1 &

exit 0
