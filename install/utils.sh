#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/utils.sh — Shared helpers: Telegram send/poll, .env writer, key validator

# Requires: TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID to be set in environment
# (called after telegram.sh has populated them)

TG_API_BASE="https://api.telegram.org/bot"
TG_POLL_TIMEOUT=30   # long-poll seconds per call

# ── Telegram helpers ──────────────────────────────────────────────────────────

# send_tg <text> [parse_mode]
# Sends a message to the configured chat. Returns 0 on success, 1 on failure.
send_tg() {
    local text="$1"
    local parse_mode="${2:-Markdown}"
    local url="${TG_API_BASE}${TELEGRAM_BOT_TOKEN}/sendMessage"

    local json_text
    json_text=$(echo "$text" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')

    # If parse_mode is empty, omit it entirely — avoids Markdown interpretation of
    # special chars (underscores, asterisks) in plain-text content like OAuth URLs.
    local json_body
    if [[ -z "$parse_mode" ]]; then
        json_body=$(printf '{"chat_id":%s,"text":%s}' "$TELEGRAM_CHAT_ID" "$json_text")
    else
        json_body=$(printf '{"chat_id":%s,"text":%s,"parse_mode":"%s"}' "$TELEGRAM_CHAT_ID" "$json_text" "$parse_mode")
    fi

    local response
    response=$(curl -s -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$json_body" \
        2>/dev/null)

    if echo "$response" | python3 -c 'import json,sys; d=json.load(sys.stdin); exit(0 if d.get("ok") else 1)' 2>/dev/null; then
        return 0
    fi
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] send_tg failed. Response: $response" >> "$LOG_FILE"
    return 1
}

# tg_get_updates <offset>
# Fetches updates from Telegram. Echoes the raw JSON response.
tg_get_updates() {
    local offset="${1:-0}"
    curl -s "${TG_API_BASE}${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=${TG_POLL_TIMEOUT}&offset=${offset}" \
        2>/dev/null
}

# tg_poll_chat_id
# Polls getUpdates until a message arrives. Echoes the chat_id of the first message.
# Sets TG_DETECTED_CHAT_ID as a side-effect.
tg_poll_chat_id() {
    local offset=0
    while true; do
        local resp
        resp=$(tg_get_updates "$offset")
        local count
        count=$(echo "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(len(d.get("result", [])))
' 2>/dev/null)
        if [[ "$count" -gt 0 ]]; then
            local chat_id
            chat_id=$(echo "$resp" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for upd in d.get("result", []):
    msg = upd.get("message") or upd.get("channel_post")
    if msg:
        print(msg["chat"]["id"])
        break
' 2>/dev/null)
            if [[ -n "$chat_id" ]]; then
                TG_DETECTED_CHAT_ID="$chat_id"
                echo "$chat_id"
                return 0
            fi
        fi
    done
}

# wait_for_reply <timeout_seconds>
# Polls until a text message arrives after send_tg. Echoes the message text.
# Returns 1 if timed out.
wait_for_reply() {
    local timeout="${1:-300}"
    local deadline=$(( $(date +%s) + timeout ))
    local offset=0

    # Clear any stale sensitive-message tracking from a previous reply so a
    # timed-out poll can't leave the wrong message id behind for deletion.
    # Stored under the owner-only ~/.claude (not world-writable /tmp) to avoid
    # symlink/DoS exposure (CWE-59 / CWE-377).
    rm -f "$HOME/.claude/tg_last_message_id" "$HOME/.claude/tg_last_update_offset" 2>/dev/null || true

    # Drain any stale updates first (use current update_id + 1 as offset)
    local drain
    drain=$(curl -s "${TG_API_BASE}${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=1&offset=-1" 2>/dev/null)
    local last_id
    last_id=$(echo "$drain" | python3 -c '
import json, sys
d = json.load(sys.stdin)
res = d.get("result", [])
if res:
    print(res[-1]["update_id"] + 1)
else:
    print(0)
' 2>/dev/null)
    offset="$last_id"

    while [[ $(date +%s) -lt $deadline ]]; do
        local resp
        resp=$(tg_get_updates "$offset")
        local result
        # Only accept replies from the configured chat (when TELEGRAM_CHAT_ID
        # is set): this poll receives OAuth auth codes and yes/no decisions,
        # and without the filter any stranger who messages the bot inside the
        # window has their text consumed as the reply. Foreign / non-text
        # updates emit a sentinel line with an empty message_id so the loop
        # advances the offset past them instead of hot-spinning on the same
        # pending batch.
        result=$(echo "$resp" | TG_CHAT_ID="${TELEGRAM_CHAT_ID:-}" python3 -c '
import json, os, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit()
if not isinstance(d, dict):
    sys.exit()
# Per-item isinstance guards: a malformed update is skipped, never
# allowed to crash the parse (which would stall the offset and re-read
# the same batch forever).
want = os.environ.get("TG_CHAT_ID", "").strip()
next_off = None
match = None
for upd in d.get("result") or []:
    if not (isinstance(upd, dict) and isinstance(upd.get("update_id"), int)):
        continue
    next_off = upd["update_id"] + 1
    msg = upd.get("message") or upd.get("channel_post")
    if not (isinstance(msg, dict) and isinstance(msg.get("text"), str)):
        continue
    chat = msg.get("chat") if isinstance(msg.get("chat"), dict) else {}
    if want and str(chat.get("id")) != want:
        continue
    match = (msg.get("message_id", ""), msg["text"])
    break
if match is not None:
    print(next_off, "|", match[0], "|", match[1])
elif next_off is not None:
    print(next_off, "|", "", "|")
' 2>/dev/null)
        if [[ -n "$result" ]]; then
            local new_offset msg_id
            # head -n 1: the metadata lives on the first line; a multi-line
            # message body must not corrupt the offset/id parsed from it.
            new_offset=$(echo "$result" | head -n 1 | cut -d'|' -f1 | tr -d ' ')
            msg_id=$(echo "$result" | head -n 1 | cut -d'|' -f2 | tr -d ' ')
            if [[ -z "$msg_id" ]]; then
                # Sentinel: batch held only foreign/non-text updates — skip
                # past them and keep waiting for the configured chat.
                [[ "$new_offset" =~ ^[0-9]+$ ]] && offset="$new_offset"
                continue
            fi
            local text
            text=$(echo "$result" | cut -d'|' -f3- | sed 's/^ //')
            # Acknowledge (advance offset)
            curl -s "${TG_API_BASE}${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=1&offset=${new_offset}" \
                >/dev/null 2>&1
            # Record this message's id + the advanced offset so callers that
            # handle secrets (auth codes, tokens) can scrub it from the chat and
            # the getUpdates cache via tg_scrub_last_sensitive. Stored under the
            # owner-only ~/.claude (not world-writable /tmp).
            mkdir -p "$HOME/.claude" 2>/dev/null || true
            { echo "$msg_id" > "$HOME/.claude/tg_last_message_id"; echo "$new_offset" > "$HOME/.claude/tg_last_update_offset"; } 2>/dev/null || true
            echo "$text"
            return 0
        fi
    done
    return 1
}

# wait_for_keyword <keyword> <timeout_seconds>
# Like wait_for_reply but only returns when the reply contains a specific word (case-insensitive).
wait_for_keyword() {
    local keyword="${1,,}"   # lowercase
    local timeout="${2:-300}"
    local deadline=$(( $(date +%s) + timeout ))

    while [[ $(date +%s) -lt $deadline ]]; do
        local reply
        reply=$(wait_for_reply 60)
        if [[ -n "$reply" ]]; then
            local lower="${reply,,}"
            if [[ "$lower" == *"$keyword"* || "$lower" == *"yes"* || "$lower" == *"done"* || "$lower" == *"ok"* ]]; then
                echo "$reply"
                return 0
            fi
        fi
    done
    return 1
}

# ── Telegram sensitive-message scrubbing ──────────────────────────────────────
# Mirrors the deletion/flush pattern used by the Google setup flow so that any
# message carrying a secret (auth code, setup token) can be removed from the
# chat and from Telegram's getUpdates buffer after it has been consumed.

# tg_delete_message <message_id>
# Best-effort removal of a message from the chat (both sides).
tg_delete_message() {
    local msg_id="$1"
    [[ -z "$msg_id" ]] && return 0
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
    curl -s --max-time 10 -X POST "${TG_API_BASE}${TELEGRAM_BOT_TOKEN}/deleteMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":${TELEGRAM_CHAT_ID},\"message_id\":${msg_id}}" \
        >/dev/null 2>&1 || true
}

# tg_flush_updates <offset>
# Advance the getUpdates offset so an already-consumed update (which may have
# carried a secret) can no longer be re-fetched by anyone holding the bot token.
tg_flush_updates() {
    local offset="$1"
    [[ -z "$offset" ]] && return 0
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]] || return 0
    curl -s --max-time 10 "${TG_API_BASE}${TELEGRAM_BOT_TOKEN}/getUpdates?timeout=0&offset=${offset}" \
        >/dev/null 2>&1 || true
}

# tg_scrub_last_sensitive
# Delete the message captured by the most recent wait_for_reply (if any) and
# flush the update cache, then clear the tracking files. Prints nothing to
# stdout so it is safe to call inside command-substitution functions whose
# stdout is captured (e.g. the claude-auth token helpers).
tg_scrub_last_sensitive() {
    [[ -f "$HOME/.claude/tg_last_message_id" ]] || return 0
    tg_delete_message "$(cat "$HOME/.claude/tg_last_message_id" 2>/dev/null)"
    [[ -f "$HOME/.claude/tg_last_update_offset" ]] && tg_flush_updates "$(cat "$HOME/.claude/tg_last_update_offset" 2>/dev/null)"
    rm -f "$HOME/.claude/tg_last_message_id" "$HOME/.claude/tg_last_update_offset" 2>/dev/null || true
}

# ── .env helpers ──────────────────────────────────────────────────────────────

# write_env <key> <value>
# Adds or updates a key=value line in $CLAUDE_HOME/.env
#
# The value is single-quoted so that any space-, '#'-, '$'- or quote-containing
# value survives the file being shell-`source`d (e.g. by entrypoint.sh and
# source_env below). Without this, a space-separated value such as the
# space-delimited SERVICE_GOOGLE_WORKSPACE_RW_SCOPES list would be parsed by bash as
# "run command <2nd-word> with KEY=<1st-word> in its env", which under
# `set -euo pipefail` aborts the shell and crash-loops the container at boot.
# Callers therefore pass the raw value WITHOUT adding their own quotes.
write_env() {
    local key="$1"
    local value="$2"
    local env_file="$CLAUDE_HOME/.env"

    # Single-quote the value, escaping any embedded single quote as '\''.
    # Stored values (tokens, ids, scope URLs, emails, timezones) virtually
    # never contain a single quote, but handle it anyway for safety.
    local q=${value//\'/\'\\\'\'}
    local line="${key}='${q}'"

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        # Update existing line. Escape the chars sed treats specially in a
        # replacement string (\, &, and the | delimiter) so an arbitrary
        # value can never be misinterpreted.
        local repl=${line//\\/\\\\}
        repl=${repl//&/\\&}
        repl=${repl//|/\\|}
        sed -i "s|^${key}=.*|${repl}|" "$env_file"
    else
        printf '%s\n' "$line" >> "$env_file"
    fi
    chmod 600 "$env_file"
}

# source_env
# Sources $CLAUDE_HOME/.env into current shell
source_env() {
    # Use the tolerant loader (core/env-loader.sh): it parses KEY=VALUE
    # literally, so a value containing spaces (e.g. the space-separated
    # SERVICE_GOOGLE_WORKSPACE_RW_SCOPES) can never run as a command or abort the
    # caller under `set -e`. See issue #387. Falls back to the old `source`
    # behaviour only if the loader file is somehow absent.
    if [[ -f "$CLAUDE_HOME/core/env-loader.sh" ]]; then
        # shellcheck disable=SC1091
        source "$CLAUDE_HOME/core/env-loader.sh"
        load_env_file "$CLAUDE_HOME/.env"
    elif [[ -f "$CLAUDE_HOME/.env" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$CLAUDE_HOME/.env"
        set +a
    fi
}

# ── Telegram plugin config sync ───────────────────────────────────────────────

# tg_sync_plugin_config
# Syncs the Telegram plugin's own config dir ($HOME/.claude/channels/telegram)
# with the current TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID:
#   - updates TELEGRAM_BOT_TOKEN in the plugin's .env (the plugin reads its
#     token from there, not from $CLAUDE_HOME/.env)
#   - REPLACES access.json's allowFrom with the current TELEGRAM_CHAT_ID,
#     creating the file if missing. Replacing (not merging) is deliberate:
#     when the user re-pairs to a different Telegram account, the previous
#     account must lose access. Chats added manually via /telegram:access
#     pair are therefore also reset by a re-pair; dmPolicy/groups/pending
#     and any other fields are preserved.
# Must run on EVERY pairing, not just the first install: re-pairing to a
# different Telegram account or bot otherwise leaves the plugin reading the
# old token/allow list, and the bot silently ignores the new account until a
# manual /telegram:access pair in the Claude terminal.
tg_sync_plugin_config() {
    [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] || return 0
    # The interactive flows validate the token before we get here, but the
    # headless path takes it straight from the environment. Re-validate so a
    # malformed value never lands in the plugin's .env.
    validate_token_format "$TELEGRAM_BOT_TOKEN" || return 0

    local tg_dir="$HOME/.claude/channels/telegram"
    mkdir -p "$tg_dir/approved" "$tg_dir/inbox"

    # Both files are rewritten by one python3 script. Write errors raise and
    # exit non-zero on purpose — under the installer's set -e a broken config
    # dir aborts loudly instead of leaving a half-synced plugin.
    TG_DIR="$tg_dir" python3 - "$TELEGRAM_CHAT_ID" "$TELEGRAM_BOT_TOKEN" <<'PYEOF'
import json, os, sys

tg_dir = os.environ["TG_DIR"]
chat_id = str(sys.argv[1])
bot_token = sys.argv[2]

def write_0600(path, text):
    # O_CREAT with mode 0600 so a fresh file is never readable by others,
    # even briefly (these hold credentials; plain open() would use the umask).
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)

# Plugin .env: replace the TELEGRAM_BOT_TOKEN line, keep any other lines.
env_path = os.path.join(tg_dir, ".env")
lines = []
try:
    with open(env_path) as f:
        lines = [l for l in f if not l.startswith("TELEGRAM_BOT_TOKEN=")]
except OSError:
    pass
lines.append("TELEGRAM_BOT_TOKEN=%s\n" % bot_token)
write_0600(env_path, "".join(lines))

# access.json: replace allowFrom with the current chat ID, keep other fields.
access_path = os.path.join(tg_dir, "access.json")
data = {}
try:
    with open(access_path) as f:
        data = json.load(f)
except (OSError, ValueError):
    pass
if not isinstance(data, dict):
    data = {}
data.setdefault("dmPolicy", "pairing")
data.setdefault("groups", {})
data.setdefault("pending", {})
data["allowFrom"] = [chat_id]
write_0600(access_path, json.dumps(data, indent=2))
PYEOF
    # Repair perms on files that pre-existed with a looser mode (O_CREAT's
    # mode only applies to newly created files).
    chmod 600 "$tg_dir/.env" "$tg_dir/access.json"
}

# ── Key/token validators ──────────────────────────────────────────────────────

# validate_token_format <token>
# Returns 0 if it looks like a Telegram bot token (numbers:alphanum, 40+ chars)
validate_token_format() {
    local token="$1"
    if [[ "$token" =~ ^[0-9]{8,12}:[A-Za-z0-9_-]{35,}$ ]]; then
        return 0
    fi
    return 1
}

# validate_serpapi_key <key>
# Returns 0 if non-empty and looks like a hex string (40 chars)
validate_serpapi_key() {
    local key="$1"
    if [[ "$key" =~ ^[a-f0-9]{40}$ ]]; then
        return 0
    fi
    return 1
}

# validate_google_client_id <id>
# Returns 0 if it ends in .apps.googleusercontent.com
validate_google_client_id() {
    local id="$1"
    if [[ "$id" == *".apps.googleusercontent.com" ]]; then
        return 0
    fi
    return 1
}

# validate_google_client_secret <secret>
# Returns 0 if starts with GOCSPX- or is a reasonable length
validate_google_client_secret() {
    local secret="$1"
    if [[ ${#secret} -ge 20 ]]; then
        return 0
    fi
    return 1
}
