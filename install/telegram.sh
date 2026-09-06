#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/telegram.sh — BotFather instructions, token prompt (web + terminal), chat_id auto-detect
# Sources: install/ui.sh, install/utils.sh, install/tunnel-helper.sh

# shellcheck source=install/tunnel-helper.sh
source "$(dirname "${BASH_SOURCE[0]}")/tunnel-helper.sh"

telegram_setup() {
    ui_step 2 3 "Connect Telegram"

    # ── Check if already paired to a valid bot ────────────────────────────────
    local existing_token="${TELEGRAM_BOT_TOKEN:-}"
    if [[ -z "$existing_token" ]] && [[ -f "$CLAUDE_HOME/.env" ]]; then
        existing_token=$(grep -oP '(?<=^TELEGRAM_BOT_TOKEN=).*' "$CLAUDE_HOME/.env" 2>/dev/null || true)
    fi

    if [[ -n "$existing_token" ]] && validate_token_format "$existing_token"; then
        local existing_me
        existing_me=$(curl -sf "https://api.telegram.org/bot${existing_token}/getMe" 2>/dev/null || echo "")
        local existing_ok
        existing_ok=$(echo "$existing_me" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("ok") else "no")' 2>/dev/null || echo "no")

        if [[ "$existing_ok" == "yes" ]]; then
            local existing_botname
            existing_botname=$(echo "$existing_me" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"].get("username","unknown"))' 2>/dev/null || echo "unknown")
            ui_info "You are already paired to Telegram bot @${existing_botname}."
            ui_blank
            printf "  ${C_BRIGHT_WHITE}Keep existing bot or pair a new one? (keep/new):${C_RESET}  "
            local choice=""
            read -r choice
            # printf '%s' rather than echo: a $choice that happens to start
            # with `-n` / `-e` would be eaten as a flag by some echo impls.
            choice=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if [[ "$choice" != "new" ]]; then
                ui_ok "Keeping existing bot @${existing_botname}."
                TELEGRAM_BOT_TOKEN="$existing_token"
                # Ensure chat_id is also set
                local existing_chat_id="${TELEGRAM_CHAT_ID:-}"
                if [[ -z "$existing_chat_id" ]] && [[ -f "$CLAUDE_HOME/.env" ]]; then
                    existing_chat_id=$(grep -oP '(?<=^TELEGRAM_CHAT_ID=).*' "$CLAUDE_HOME/.env" 2>/dev/null || true)
                fi
                if [[ -n "$existing_chat_id" ]]; then
                    TELEGRAM_CHAT_ID="$existing_chat_id"
                    # Re-sync even when nothing changed: a tray "Reconnect
                    # Telegram" run is often a repair attempt, and the plugin's
                    # allow list may be missing this chat ID.
                    tg_sync_plugin_config
                    return 0
                fi
                # Chat ID missing — need to re-detect
                ui_warn "Chat ID not found. Send a message to your bot to re-detect it."
                ui_blank
                printf "  Waiting for your message...  "
                local detected_id=""
                while true; do
                    ui_spinner_start "Waiting for your message"
                    local deadline=$(( $(date +%s) + 120 ))
                    local offset=0
                    while [[ $(date +%s) -lt $deadline ]]; do
                        ui_spinner_tick
                        local resp
                        resp=$(tg_get_updates "$offset")
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
                            detected_id="$chat_id"
                            break 2
                        fi
                        sleep 2
                    done
                    ui_spinner_stop
                    ui_warn "Still waiting... Make sure you sent a message to your bot in Telegram."
                    printf "  Waiting for your message...  "
                done
                ui_spinner_stop
                TELEGRAM_CHAT_ID="$detected_id"
                write_env "TELEGRAM_CHAT_ID" "$TELEGRAM_CHAT_ID"
                tg_sync_plugin_config
                ui_ok "Chat ID detected."
                return 0
            fi
            ui_blank
            ui_info "Pairing a new bot..."
            ui_blank
        fi
    fi

    ui_info "We'll create a Telegram bot that becomes your assistant."
    ui_blank

    # ── Collect token via web page + tunnel OR terminal paste ─────────────────

    local token=""
    local TOKEN_FILE="/tmp/tg_token_received"
    local TUNNEL_PID_FILE="/tmp/tg_tunnel.pid"
    local TUNNEL_LOG_FILE="/tmp/tg_tunnel.log"
    local HTTP_PID=""
    local tunnel_ok=false

    rm -f "$TOKEN_FILE"

    # Cleanup function for background processes (tunnel + HTTP server)
    _tg_cleanup() {
        kill "$HTTP_PID" 2>/dev/null || true
        stop_quick_tunnel "$TUNNEL_PID_FILE"
        rm -f "$TOKEN_FILE" "$TUNNEL_LOG_FILE"
    }
    trap _tg_cleanup EXIT

    # (Re)start the token web server + cloudflared quick tunnel. Updates
    # tunnel_ok / PUBLIC_URL / TUNNEL_PROBE_OK in telegram_setup's scope
    # (bash dynamic scoping — same mechanism _tg_cleanup relies on). Used
    # for the initial setup and by the `newqr` handler, which tears down
    # the old pair and stands up a fresh tunnel: a brand-new
    # *.trycloudflare.com hostname lands on a different edge, which is the
    # practical fix when one hostname's edge persistently won't route
    # ("this site can't be reached" on repeated scans).
    _tg_start_pairing_server() {
        # kill is async; wait until the old server has exited and released port
        # 18088 before relaunching, otherwise the rebind below can race the
        # dying process and fail with EADDRINUSE (SO_REUSEADDR only covers a
        # socket in TIME_WAIT, not a still-live listener), silently killing the
        # web-submit path. Guarded so the first call (HTTP_PID unset) is a no-op.
        if [[ -n "${HTTP_PID:-}" ]]; then
            kill "$HTTP_PID" 2>/dev/null || true
            wait "$HTTP_PID" 2>/dev/null || true
        fi
        stop_quick_tunnel "$TUNNEL_PID_FILE"
        rm -f "$TOKEN_FILE"
        python3 "$CLAUDE_HOME/install/token-server.py" \
            --port 18088 --output "$TOKEN_FILE" &
        HTTP_PID=$!
        tunnel_ok=false
        PUBLIC_URL=""
        TUNNEL_PROBE_OK=false
        if start_quick_tunnel 18088 "$TUNNEL_PID_FILE" "$TUNNEL_LOG_FILE"; then
            tunnel_ok=true
        fi
    }

    # Renders the "scan this QR / open this URL" block, gated on a live
    # tunnel. Reused by the initial display, the keep-waiting timeout
    # re-show, and the `newqr` handler.
    _tg_show_qr_block() {
        [[ "$tunnel_ok" == "true" && -n "${PUBLIC_URL:-}" ]] || return 0
        ui_info "Scan this QR code or go to this URL for Telegram setup:"
        if [[ "${TUNNEL_PROBE_OK:-false}" != "true" ]]; then
            ui_warn "If the first scan fails (\"Error 1033\" or \"site can't be reached\"), wait 5-15s and try again -- the Cloudflare tunnel may still be propagating."
        fi
        ui_blank
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ANSIUTF8 -m 1 "$PUBLIC_URL" 2>/dev/null || true
            ui_blank
        fi
        printf "    ${C_CYAN}%s${C_RESET}\n" "$PUBLIC_URL"
        ui_blank
    }

    # Prints the token-paste prompt, preceded by the `newqr` hint when a
    # tunnel is up (no point offering a fresh QR if tunnels are
    # unavailable). The paste prompt stays the last line so the cursor
    # sits where the user types.
    _tg_prompt_for_token() {
        if [[ "$tunnel_ok" == "true" ]]; then
            ui_info "Or, if the QR code above won't load, type \"newqr\" for a fresh one."
        fi
        printf "  ${C_BRIGHT_WHITE}Paste your bot token here:${C_RESET}  "
    }

    # Start the token web server + cloudflared tunnel
    _tg_start_pairing_server

    # ── Show instructions ─────────────────────────────────────────────────────

    if [[ "$tunnel_ok" == "true" ]]; then
        # _tg_show_qr_block surfaces the propagation-retry hint when
        # TUNNEL_PROBE_OK is false, so a slow-routing edge isn't mistaken
        # for a broken QR. See tunnel-helper.sh's _quick_tunnel_attempt.
        _tg_show_qr_block
        ui_divider "Alternative: manual setup"
        ui_blank
    fi

    ui_info "Manual setup (if the QR code doesn't work):"
    ui_bullet "Open Telegram → search for @BotFather"
    ui_bullet "Tap Start, then send:  /newbot"
    ui_bullet "Choose any name  (e.g. \"My Assistant\")"
    ui_bullet "Choose a username ending in bot  (e.g. \"myhelper_bot\")"
    ui_bullet "Copy the token BotFather gives you"
    ui_info "  (It looks like: 1234567890:ABCdefGHIjklMNO-pqrSTUvwxyz)"
    ui_blank

    _tg_prompt_for_token

    # ── Dual-listen loop: stdin + web server ──────────────────────────────────

    local start_time
    start_time=$(date +%s)
    local timeout_secs=600    # 10 minutes
    local reminder_sent=false

    while true; do
        local now
        now=$(date +%s)
        local elapsed=$(( now - start_time ))

        # Overall timeout — offer to keep waiting rather than aborting the
        # entire installer. The token web server and cloudflared tunnel are
        # still running from the original setup, so a retry costs nothing
        # except clearing the terminal noise. Unlimited retries: a user who
        # walks away mid-install shouldn't lose progress just because they
        # were slow.
        if [[ $elapsed -ge $timeout_secs ]]; then
            ui_blank
            ui_warn "No token received in 10 minutes."
            printf "  ${C_BRIGHT_WHITE}Keep waiting? (Y/n):${C_RESET}  "
            local cont=""
            read -r cont
            cont=$(printf '%s' "$cont" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if [[ "$cont" == "n" || "$cont" == "no" ]]; then
                ui_error "Aborted by user."
                exit 1
            fi
            # Re-show QR + URL so the user can act without scrolling up
            # through 10 minutes of terminal history.
            ui_blank
            _tg_show_qr_block
            _tg_prompt_for_token
            start_time=$(date +%s)
            reminder_sent=false
            continue
        fi

        # 5-minute reminder
        if [[ $elapsed -ge 300 && "$reminder_sent" != "true" ]]; then
            reminder_sent=true
            ui_blank
            ui_warn "Still waiting for your token... (5 minutes remaining)"
            _tg_prompt_for_token
        fi

        # Check if web server already delivered token
        if [[ -f "$TOKEN_FILE" ]]; then
            local web_token
            web_token=$(cat "$TOKEN_FILE")
            if [[ -n "$web_token" ]] && validate_token_format "$web_token"; then
                token="$web_token"
                ui_blank
                ui_ok "Token received via web page."
                break
            fi
            # File exists but invalid/empty — ignore and keep waiting
        fi

        # Non-blocking read from stdin (1s timeout)
        if read -t 1 -r user_input; then
            user_input=$(printf '%s' "$user_input" | tr -d '[:space:]')
            if [[ -n "$user_input" ]]; then
                # `newqr` (case-insensitive): tear down the current
                # server+tunnel and stand up a fresh one, then re-show the
                # QR. Checked before token validation so a "newqr" request
                # isn't rejected as a malformed token.
                if [[ "$(printf '%s' "$user_input" | tr '[:upper:]' '[:lower:]')" == "newqr" ]]; then
                    ui_blank
                    ui_info "Generating a fresh QR code (new tunnel)..."
                    _tg_start_pairing_server
                    if [[ "$tunnel_ok" != "true" ]]; then
                        ui_warn "Couldn't bring up a new tunnel right now. Paste your token manually below, or type \"newqr\" to try again."
                    fi
                    ui_blank
                    _tg_show_qr_block
                    _tg_prompt_for_token
                    start_time=$(date +%s)
                    reminder_sent=false
                    continue
                fi
                if validate_token_format "$user_input"; then
                    token="$user_input"
                    ui_ok "Token looks valid."
                    break
                else
                    ui_error "That doesn't look like a valid token. Please try again."
                    ui_info "(It should be numbers, a colon, then letters/numbers — about 46 characters)"
                    _tg_prompt_for_token
                fi
            fi
        fi
    done

    # ── Cleanup tunnel + server ───────────────────────────────────────────────

    _tg_cleanup
    trap - EXIT

    # ── Validate token with Telegram getMe API ────────────────────────────────

    ui_info "Verifying token with Telegram..."
    local me_resp
    me_resp=$(curl -sf "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || echo "")
    local me_ok
    me_ok=$(echo "$me_resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("yes" if d.get("ok") else "no")' 2>/dev/null || echo "no")

    if [[ "$me_ok" != "yes" ]]; then
        ui_error "Token verification failed — Telegram rejected this token."
        ui_error "Please check the token and restart the installer."
        exit 1
    fi

    local bot_username
    bot_username=$(echo "$me_resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["result"].get("username",""))' 2>/dev/null || echo "")
    if [[ -n "$bot_username" ]]; then
        ui_ok "@${bot_username} connected!"
    else
        ui_ok "Token verified successfully."
    fi

    TELEGRAM_BOT_TOKEN="$token"

    # ── Prompt user to message the bot ─────────────────────────────────────────
    ui_blank
    if [[ -n "$bot_username" ]]; then
        local bot_url="https://t.me/${bot_username}"
        ui_info "Now send a message to your bot to complete setup."
        ui_blank

        # Show QR code to the bot's Telegram link
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t ANSIUTF8 -m 1 "$bot_url" 2>/dev/null || true
            ui_blank
        fi

        ui_info "Scan the QR code or open this link on your phone:"
        printf "    ${C_CYAN}%s${C_RESET}\n" "$bot_url"
        ui_blank
        ui_info "Tap Start, then send any message."
    else
        ui_info "Now open your new bot in Telegram and send it any message."
        ui_info "(Tap the bot's name -> Start, then say anything)"
    fi
    ui_blank
    printf "  Waiting for your message...  "

    local detected_id=""
    while true; do
        ui_spinner_start "Waiting for your message"

        local deadline=$(( $(date +%s) + 120 ))
        local offset=0

        while [[ $(date +%s) -lt $deadline ]]; do
            ui_spinner_tick
            local resp
            resp=$(tg_get_updates "$offset")
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
                detected_id="$chat_id"
                break 2
            fi
            sleep 2
        done

        ui_spinner_stop
        ui_warn "Still waiting... Make sure you sent a message to your bot in Telegram."
        printf "  Waiting for your message...  "
    done

    ui_spinner_stop
    TELEGRAM_CHAT_ID="$detected_id"

    ui_ok "Connected! Sending a test message to your phone..."

    # Save to .env
    write_env "TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN"
    write_env "TELEGRAM_CHAT_ID"   "$TELEGRAM_CHAT_ID"

    # Sync the plugin's own token file and allow list so the new account is
    # answered immediately — without this, a changed bot/account keeps the
    # plugin on the old credentials until a manual /telegram:access pair.
    tg_sync_plugin_config

    # Send confirmation message
    send_tg "✅ *Telegram connected!*

Your assistant is being set up now. The next steps will happen here in Telegram.

Stay tuned — I'll message you in just a moment." "Markdown"

    ui_blank
}
