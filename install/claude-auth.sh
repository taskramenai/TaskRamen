#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/claude-auth.sh — Headless VM auth via tmux + setup-token flow
# Sources: install/ui.sh, install/utils.sh

# Write/ensure the install-state flags on ~/.claude/settings.json. Idempotent.
#
# Called from BOTH the "keep existing credentials" and the "new auth"
# branches below. The two flags it guarantees are what entrypoint.sh's
# _check_install_state looks for under the "settings" category:
#
#   - skipDangerousModePermissionPrompt = True
#     Required so --dangerously-skip-permissions never prompts for
#     interactive confirmation. Without this, claudebot stalls waiting
#     for an interactive y/n the first time it runs a dangerous tool.
#
#   - model = "sonnet"
#     Sets the default to the Sonnet alias, which Claude Code resolves
#     server-side to the latest Sonnet — so the default auto-tracks new
#     Sonnet releases (e.g. 4.6 -> 5) without a version bump here. A full
#     dated id (e.g. "claude-sonnet-4-6") would pin instead; the alias is
#     the intended behaviour (issue #419).
#
# Previously this lived only inside the "new auth" branch -- a reinstall
# where the user chose "keep existing credentials" returned from
# claude_auth_setup() WITHOUT updating settings.json, so the
# entrypoint's _check_install_state reported "settings missing" forever
# and the .auth-complete marker was never written. The interactive
# pairing terminal hung waiting for a marker it would never get,
# the orchestrator's step 8 timed out, and the install was declared
# failed even though claudebot was working.
#
# The settings.json file itself is ALSO ephemeral on every interactive
# reinstall, because start-container.ps1 destroys and recreates the
# container (`podman rm` + `podman run`) which wipes the writable
# layer; only the bind-mounted $CLAUDE_HOME/taskramen/ survives.
# config/claude-settings.json.example was updated to include these
# flags in the template, but that's only the safety net -- the
# authoritative source is this function being called on every
# install path.
_ensure_claude_settings_flags() {
    mkdir -p "$HOME/.claude"
    python3 -c '
import json, os
path = os.path.expanduser("~/.claude/settings.json")
try:
    with open(path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    data = {}
changed = False
if data.get("skipDangerousModePermissionPrompt") is not True:
    data["skipDangerousModePermissionPrompt"] = True
    changed = True
if data.get("model") != "sonnet":
    data["model"] = "sonnet"
    changed = True
if changed:
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print("CHANGED")
else:
    print("UNCHANGED")
' 2>/dev/null
}

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

# Strip ANSI escape codes from a string
_strip_ansi() {
    # Input as $1 (existing callers) or, when no arg is given, streamed on stdin
    # (lets callers pipe large buffers without building an argument/variable).
    { if [ "$#" -gt 0 ]; then echo "$1"; else cat; fi; } | sed \
        's/\x1b\[[0-9;]*[mGKHFABCDJh]//g;
         s/\x1b\[[?][0-9]*[hl]//g;
         s/\x1b][0-9]*;[^\x07]*\x07//g;
         s/\x1b][^\\]*\\//g;
         s/\r//g'
}

# ── Interactive-login (#6) helpers ────────────────────────────────────────────
# These are only used when claude_auth runs in "login" mode. The OAuth authorize
# endpoint is identical for setup-token and interactive login, so the URL capture
# in _claude_auth_tmux is shared; only the launch command, a few extra TUI
# prompts, and the success signal (credentials.json vs an sk token) differ.

_is_container() { [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; }

# Path to ~/.claude.json (symlinked to the writable volume in container mode —
# matches the inline logic on the token path below).
_claude_json_path() {
    if _is_container; then echo "$CLAUDE_HOME/.claude/.claude.json"; else echo "$HOME/.claude.json"; fi
}

# `auth status` with the env token stripped → reflects the stored login creds
# (#6), not the headless token (#5). Echoes "True"/"False"/"".
_login_status() {
    local CLAUDE="${CLAUDE:-$(_claude_bin)}" out
    out=$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
        timeout --kill-after=5 60 $CLAUDE auth status </dev/null 2>/dev/null) || true
    echo "$out" | python3 -c '
import json, sys, re
data = sys.stdin.read()
try:
    print(json.loads(data).get("loggedIn", False))
except Exception:
    m = re.search(r"\"loggedIn\"\s*:\s*(true|false)", data, re.IGNORECASE)
    print("True" if (m and m.group(1).lower() == "true") else "")
' 2>/dev/null
}

# Pre-seed onboarding flags so the interactive `claude` TUI does not stop on the
# theme picker or welcome screen before reaching login. Also used post-auth on
# the token path (theme is harmless there). Idempotent.
_preseed_onboarding() {
    local cj; cj=$(_claude_json_path)
    python3 -c '
import json, sys, os
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    data = {}
data["hasCompletedOnboarding"] = True
data["lastOnboardingVersion"] = "2.1.91"
data.setdefault("theme", "dark")
# Pre-accept the per-project trust dialog for the workspace dir(s) so the
# interactive login TUI does not stop on "Is this a project you created or one
# you trust?". config.sh sets the SAME flag, but only in config_generate which
# runs AFTER claude_auth in the install phase order (install.sh:84 vs :85) — so
# during login the flag is not yet present and the dialog blocks the flow. The
# headless run path never sees it (it uses --dangerously-skip-permissions).
projects = data.setdefault("projects", {})
for key in sys.argv[2:]:
    if key:
        projects.setdefault(key, {})["hasTrustDialogAccepted"] = True
with open(path, "w") as f:
    json.dump(data, f, indent=2)
' "$cj" "${CLAUDE_HOME:-}" "$(pwd)" 2>/dev/null || true
}

# Dismiss an interactive first-run prompt by pressing Enter on its default. The
# "Select login method" picker (Subscription vs Console) appears only when
# unauthenticated and is not covered by onboarding flags — its default (Claude
# account / subscription) is what we want. Idempotent via per-prompt shell flags
# declared `local` in _claude_auth_tmux; bash dynamic scoping makes them visible
# here (avoids predictable /tmp marker files, CWE-377/59).
_dismiss_login_prompt() {
    local socket="$1" session="$2" clean="$3"
    if echo "$clean" | grep -qiE "select login method|log in with your|claude account|anthropic console|subscription"; then
        if [[ "${_cl_login_method_dismissed:-}" != "true" ]]; then
            tmux -L "$socket" send-keys -t "$session" "" Enter 2>/dev/null || true
            _cl_login_method_dismissed="true"
            ui_info "Selected 'Claude account (subscription)' login method." >&2
        fi
    fi
    if echo "$clean" | grep -qiE "choose the text style|looks best with your terminal"; then
        if [[ "${_cl_theme_dismissed:-}" != "true" ]]; then
            tmux -L "$socket" send-keys -t "$session" "" Enter 2>/dev/null || true
            _cl_theme_dismissed="true"
        fi
    fi
    if echo "$clean" | grep -qiE "do you trust the files|trust the files in this folder|trust this folder|quick safety check|project you created or one you trust"; then
        if [[ "${_cl_trust_dismissed:-}" != "true" ]]; then
            tmux -L "$socket" send-keys -t "$session" "" Enter 2>/dev/null || true
            _cl_trust_dismissed="true"
        fi
    fi
}

# Flip .env into login mode: comment the headless token so #5 can't shadow #6,
# and persist TASKRAMEN_AUTH_MODE=login (read by run.sh + monitor.sh). Echoes the
# .env backup path for the rollback message.
_apply_login_mode() {
    local env_file="$CLAUDE_HOME/.env"
    local backup; backup="$CLAUDE_HOME/.env.bak.$(date +%Y%m%d%H%M%S)"
    cp "$env_file" "$backup" 2>/dev/null || true
    if grep -q "^CLAUDE_CODE_OAUTH_TOKEN=" "$env_file" 2>/dev/null; then
        sed -i 's|^CLAUDE_CODE_OAUTH_TOKEN=|#CLAUDE_CODE_OAUTH_TOKEN=|' "$env_file"
    fi
    write_env "TASKRAMEN_AUTH_MODE" "login"
    echo "$backup"
}

# _claude_auth_tmux <mode>: drive `claude setup-token` (token) or plain `claude`
# (login) in tmux, capture the OAuth URL, relay it over Telegram, inject the
# returned code, then capture the result — an sk token (token) which is echoed to
# stdout, or credentials.json (login) signalled via return code only.
_claude_auth_tmux() {
    local mode="${1:-token}"
    local CLAUDE
    CLAUDE=$(_claude_bin)
    local auth_session="claude-auth-$$"
    local auth_socket="claude-auth-$$"   # plain name, not a path — tmux -L takes a socket name

    # script(1) captures all bytes written to the pty — including what Ink renders before
    # clearing the screen on exit. We poll this file for both the OAuth URL and the sk token.
    # Without this, the sk token is only visible for ~500ms before Ink calls unmount()+exit(0).
    local capture_file="/tmp/claude-setup-token-$$.txt"

    # Per-prompt "already dismissed" flags (login mode only) — kept as shell
    # locals, read/written by _dismiss_login_prompt via bash dynamic scoping.
    local _cl_login_method_dismissed="" _cl_theme_dismissed="" _cl_trust_dismissed=""

    trap "tmux -L \"$auth_socket\" kill-server 2>/dev/null || true; rm -f \"$capture_file\"" EXIT INT TERM

    if [ "$mode" = login ]; then
        ui_info "Starting interactive Claude login (tmux method)..." >&2
    else
        ui_info "Starting Claude authentication (tmux method)..." >&2
    fi

    # Create a very wide tmux session — URL is 300+ chars and wraps at column width,
    # breaking the grep. 400 columns prevents wrapping for all known OAuth URL lengths.
    tmux -L "$auth_socket" new-session -d -s "$auth_session" -x 400 -y 50 2>/dev/null || true

    # Run claude wrapped in script(1) so ALL terminal output is captured to a
    # persistent file. The -f flag flushes after each write so we can poll in near-real-time.
    # The -q flag suppresses the "Script started/done" header lines.
    # Input (our injected code) still passes through to claude via the pty.
    # Login mode drives the dedicated `claude auth login --claudeai` subcommand
    # (documented; --claudeai = Claude.ai subscription, the default), with every
    # higher-precedence credential stripped so it actually performs a sign-in.
    # That subcommand goes STRAIGHT to the OAuth URL — no trust dialog, no theme
    # picker, no login-method picker, no REPL — as a SINGLE OAuth transaction (one
    # state/code_challenge). The previous plain-`claude` + `/login` path could
    # have two logins in flight (startup + /login), so the authorized code didn't
    # match the verifier the process was waiting on ("Invalid OAuth request:
    # missing parameter"). Token mode runs `claude setup-token`. Capture is identical.
    local inner
    if [ "$mode" = login ]; then
        inner="env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN $CLAUDE auth login --claudeai"
    else
        inner="$CLAUDE setup-token"
    fi
    local script_cmd="script -q -f \"$capture_file\" -c '$inner'"
    [[ -n "${LOG_FILE:-}" ]] && {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] tmux socket=$auth_socket session=$auth_session" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Exact command being sent to tmux: $script_cmd" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] capture_file=$capture_file" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] CLAUDE binary=$CLAUDE" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] tmux env dump:" >> "$LOG_FILE"
        tmux -L "$auth_socket" show-environment -t "$auth_session" >> "$LOG_FILE" 2>&1 || echo "(show-environment failed)" >> "$LOG_FILE"
    }
    tmux -L "$auth_socket" send-keys -t "$auth_session" \
        "$script_cmd" Enter 2>/dev/null || true

    # Poll for OAuth URL — check capture file first (persistent), fall back to pane
    local url=""
    for _i in $(seq 1 45); do
        sleep 1

        # Login mode only: dismiss the unauthenticated TUI prompts (login-method
        # picker / theme / trust) so the flow reaches the OAuth URL; and if a
        # prior partial run already authenticated us, the TUI shows the main
        # screen and never emits a URL — treat present creds as success.
        if [ "$mode" = login ]; then
            local _pane_l
            _pane_l=$(_strip_ansi "$(tmux -L "$auth_socket" capture-pane -t "$auth_session" -p -S - 2>/dev/null || echo "")")
            # `claude auth login --claudeai` goes straight to the OAuth URL, so no
            # prompt navigation is normally needed. _dismiss_login_prompt is kept
            # only as a harmless fallback in case a build surfaces a trust/theme/
            # method prompt before the URL.
            _dismiss_login_prompt "$auth_socket" "$auth_session" "$_pane_l"
            if taskramen_creds_present && printf '%s' "$_pane_l" | grep -qiE "what can i help|welcome to claude code"; then
                ui_ok "Already authenticated (credentials present) — no OAuth needed." >&2
                return 0
            fi
        fi

        # Primary: scan the capture file (ANSI-stripped)
        if [[ -f "$capture_file" ]]; then
            local file_clean
            file_clean=$(_strip_ansi "$(cat "$capture_file" 2>/dev/null || true)")
            url=$(echo "$file_clean" | grep -o 'https://claude\.com/cai/oauth/authorize[^[:space:]]*' | head -1)
            if [[ -z "$url" ]]; then
                url=$(echo "$file_clean" \
                    | tr -d '\r' \
                    | grep -A1 'https://claude\.com/cai/oauth/authorize' \
                    | tr -d '\n' \
                    | grep -o 'https://claude\.com/cai/oauth/authorize[^[:space:]]*')
            fi
        fi

        # Fallback: tmux pane (in case script didn't start yet)
        if [[ -z "$url" ]]; then
            local pane_out
            pane_out=$(tmux -L "$auth_socket" capture-pane -t "$auth_session" -p -S - 2>/dev/null || echo "")
            local clean_out
            clean_out=$(_strip_ansi "$pane_out")
            url=$(echo "$clean_out" | grep -o 'https://claude\.com/cai/oauth/authorize[^[:space:]]*' | head -1)
            if [[ -z "$url" ]]; then
                url=$(echo "$clean_out" \
                    | tr -d '\r' \
                    | grep -A1 'https://claude\.com/cai/oauth/authorize' \
                    | tr -d '\n' \
                    | grep -o 'https://claude\.com/cai/oauth/authorize[^[:space:]]*')
            fi
        fi

        # Log every 5s to help diagnose capture issues
        if (( _i % 5 == 0 )) && [[ -n "${LOG_FILE:-}" ]]; then
            local _cf_exists="no" _cf_size="0"
            if [[ -f "$capture_file" ]]; then
                _cf_exists="yes"
                _cf_size=$(stat -c%s "$capture_file" 2>/dev/null || echo "?")
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] URL poll t=${_i}s, capture_file exists=${_cf_exists}, size=${_cf_size}b, url_found=$([ -n "$url" ] && echo yes || echo no)" >> "$LOG_FILE"
            if [[ "$_cf_exists" == "yes" ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Raw last 200 bytes (hex):" >> "$LOG_FILE"
                tail -c 200 "$capture_file" 2>/dev/null | { xxd 2>/dev/null || od -An -tx1; } >> "$LOG_FILE" 2>&1
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] grep sk-ant-oat01 on RAW file:" >> "$LOG_FILE"
                grep -c 'sk-ant-oat01' "$capture_file" >> "$LOG_FILE" 2>&1 || echo "0 matches" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] grep sk-ant-oat01 on STRIPPED file:" >> "$LOG_FILE"
                _strip_ansi "$(cat "$capture_file" 2>/dev/null)" | grep -c 'sk-ant-oat01' >> "$LOG_FILE" 2>&1 || echo "0 matches" >> "$LOG_FILE"
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] tmux session alive:" >> "$LOG_FILE"
            tmux -L "$auth_socket" has-session -t "$auth_session" >> "$LOG_FILE" 2>&1 && echo "yes" >> "$LOG_FILE" || echo "NO - session dead" >> "$LOG_FILE"
        fi

        if [[ -n "$url" ]]; then
            # Applies to BOTH modes: the capture file is flushed incrementally, so
            # a poll can read the URL line MID-WRITE and grab a prefix missing its
            # trailing query params — most importantly &state=, whose absence
            # makes the OAuth code exchange fail with "Invalid OAuth request:
            # missing parameter". `claude auth login` and `claude setup-token`
            # print the same authorize-URL shape, so settling is robust for both.
            # Wait until the captured URL stops growing, always keeping the
            # LONGEST authorize-URL token seen.
            local _settle_prev=""
            while [[ "$url" != "$_settle_prev" ]]; do
                _settle_prev="$url"
                sleep 1
                local _settle_cand
                # Combine the persistent capture file AND the live pane so the
                # settle works regardless of which source first yielded the URL.
                # Stream straight through strip/grep/awk — never buffer the
                # (potentially large) scrollback in a variable/argument. Keep
                # the LONGEST authorize-URL token seen.
                _settle_cand=$( { cat "$capture_file" 2>/dev/null; tmux -L "$auth_socket" capture-pane -t "$auth_session" -p -S - 2>/dev/null; } \
                    | _strip_ansi \
                    | grep -oE 'https://claude\.com/cai/oauth/authorize[^[:space:]]+' \
                    | awk '{ if (length($0) > m) { m = length($0); b = $0 } } END { print b }' )
                [[ ${#_settle_cand} -gt ${#url} ]] && url="$_settle_cand"
            done
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] OAuth URL settled (len=${#url}, has_state=$(printf '%s' "$url" | grep -q 'state=' && echo yes || echo no))" >> "$LOG_FILE"
            break
        fi
    done

    if [[ -z "$url" ]]; then
        [[ -n "${LOG_FILE:-}" ]] && {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] OAuth URL not found after 45s." >> "$LOG_FILE"
            if [[ -f "$capture_file" ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] FULL raw capture file dump:" >> "$LOG_FILE"
                cat "$capture_file" >> "$LOG_FILE" 2>&1
                echo "" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] FULL stripped capture file dump:" >> "$LOG_FILE"
                _strip_ansi "$(cat "$capture_file" 2>/dev/null)" >> "$LOG_FILE" 2>&1
                echo "" >> "$LOG_FILE"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] capture file does NOT exist at $capture_file" >> "$LOG_FILE"
            fi
        }
        ui_warn "Could not capture OAuth URL from claude setup-token — falling back to manual method" >&2
        tmux -L "$auth_socket" kill-session -t "$auth_session" 2>/dev/null || true
        return 1
    fi

    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Captured OAuth URL (len=${#url}): ${url:0:80}..." >> "$LOG_FILE"
    ui_info "OAuth URL captured. Sending to Telegram..." >&2

    # Send URL as monospace (tap-to-copy) instead of clickable link.
    # User must paste into a browser where they're logged in to Claude.ai.
    local _tg_title="🔐 *Activate Claude*"
    send_tg "${_tg_title}

Copy and paste this link into a browser where you are logged in to Claude\\.ai:

\`\`\`
${url}
\`\`\`

After approving, the page shows a code\\. Copy and paste it here 👇" "MarkdownV2"

    ui_info "Waiting for auth code from Telegram..." >&2

    # Wait for user to send the code
    local code
    code=$(wait_for_reply 300) || true
    code=$(echo "$code" | xargs)

    if [[ -z "$code" ]]; then
        ui_warn "No code received within timeout." >&2
        tmux -L "$auth_socket" kill-session -t "$auth_session" 2>/dev/null || true
        send_tg "⚠️ No code received within 5 minutes. Please re-run the installer." "Markdown"
        return 1
    fi

    # Scrub the user's message bearing the auth code from Telegram (chat history
    # + getUpdates cache). The code is short-lived and one-time, but removing it
    # ensures no credential-bearing message lingers in the chat.
    tg_scrub_last_sensitive

    send_tg "✅ Code received\! Injecting into claude setup\-token now\.\.\." "MarkdownV2"
    ui_info "Injecting code into claude setup-token..." >&2

    # Log unexpected code format but don't warn the user — it works anyway
    if [[ ! "$code" =~ ^[A-Za-z0-9_\-#]{20,}$ ]]; then
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Unexpected code format: ${code:0:20}..." >> "$LOG_FILE"
    fi

    [[ -n "${LOG_FILE:-}" ]] && {
        local _hash_pos=-1
        [[ "$code" == *"#"* ]] && _hash_pos=$(echo "$code" | grep -bo '#' | head -1 | cut -d: -f1)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Code to inject: length=${#code}, first10='${code:0:10}', hash_position=${_hash_pos}" >> "$LOG_FILE"
        local _pre_inject_size="N/A"
        [[ -f "$capture_file" ]] && _pre_inject_size=$(stat -c%s "$capture_file" 2>/dev/null || echo "?")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Capture file size BEFORE injection: ${_pre_inject_size}b" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Injecting code via send-keys -l" >> "$LOG_FILE"
    }

    # Use -l (literal) flag so tmux sends the string character-by-character without any
    # key-name interpretation. Inject the code then press Enter.
    tmux -L "$auth_socket" send-keys -l -t "$auth_session" "$code" 2>/dev/null || true
    tmux -L "$auth_socket" send-keys -t "$auth_session" "" Enter 2>/dev/null || true

    # ── Login mode: success = credentials.json appears AND validates ───────────
    # The interactive login writes ~/.claude/.credentials.json; setup-token never
    # does. We do NOT switch modes on a mere file touch — a partial/stale creds
    # file must not flip the system into a broken login — so after the file shows
    # up we verify with `auth status` (a few retries let a mid-write file settle).
    # Returns via status code only (no token to echo); the EXIT trap (this helper
    # always runs inside a subshell) reclaims the tmux server + capture file.
    if [ "$mode" = login ]; then
        local have_creds=false _p
        for _p in $(seq 1 45); do
            sleep 1
            local _pane2; _pane2=$(_strip_ansi "$(tmux -L "$auth_socket" capture-pane -t "$auth_session" -p -S - 2>/dev/null || echo "")")
            _dismiss_login_prompt "$auth_socket" "$auth_session" "$_pane2"
            if taskramen_creds_present; then have_creds=true; break; fi
        done
        if ! $have_creds; then
            ui_warn "credentials.json did not appear after 45s — login did not complete." >&2
            return 1
        fi
        local _v
        for _v in $(seq 1 6); do
            if [ "$(_login_status)" = "True" ]; then
                ui_ok "Interactive login established and verified." >&2
                return 0
            fi
            sleep 2
        done
        ui_warn "credentials.json present but 'auth status' did not confirm login — NOT switching modes." >&2
        return 1
    fi

    [[ -n "${LOG_FILE:-}" ]] && {
        sleep 2
        local _post_inject_size="N/A"
        [[ -f "$capture_file" ]] && _post_inject_size=$(stat -c%s "$capture_file" 2>/dev/null || echo "?")
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Capture file size 2s AFTER injection: ${_post_inject_size}b" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] tmux session alive after injection:" >> "$LOG_FILE"
        tmux -L "$auth_socket" has-session -t "$auth_session" >> "$LOG_FILE" 2>&1 && echo "yes" >> "$LOG_FILE" || echo "NO - session dead" >> "$LOG_FILE"
    }

    # Start background capture file monitor (logs every 5s for up to 5 min)
    if [[ -n "${LOG_FILE:-}" ]]; then
        (
            for _mon_i in $(seq 1 60); do
                sleep 5
                local _ts
                _ts=$(date '+%Y-%m-%d %H:%M:%S')
                if ! tmux -L "$auth_socket" has-session -t "$auth_session" 2>/dev/null; then
                    echo "[$_ts] [DEBUG] POST-INJECT monitor t=$((5*_mon_i))s: tmux session DEAD — stopping monitor" >> "$LOG_FILE"
                    break
                fi
                local _mon_size="N/A" _mon_exists="no"
                if [[ -f "$capture_file" ]]; then
                    _mon_exists="yes"
                    _mon_size=$(stat -c%s "$capture_file" 2>/dev/null || echo "?")
                fi
                echo "[$_ts] [DEBUG] POST-INJECT monitor t=$((5*_mon_i))s: file_exists=${_mon_exists} size=${_mon_size}b session=alive" >> "$LOG_FILE"
                if [[ "$_mon_exists" == "yes" ]]; then
                    echo "[$_ts] [DEBUG] Raw last 200 bytes (hex):" >> "$LOG_FILE"
                    tail -c 200 "$capture_file" 2>/dev/null | { xxd 2>/dev/null || od -An -tx1; } >> "$LOG_FILE" 2>&1
                    echo "[$_ts] [DEBUG] grep sk-ant-oat01 RAW:" >> "$LOG_FILE"
                    grep -c 'sk-ant-oat01' "$capture_file" >> "$LOG_FILE" 2>&1 || echo "0 matches" >> "$LOG_FILE"
                    echo "[$_ts] [DEBUG] grep sk-ant-oat01 STRIPPED:" >> "$LOG_FILE"
                    sed 's/\x1b\[[0-9;]*[mGKHFABCDJh]//g; s/\x1b\[[?][0-9]*[hl]//g; s/\x1b][0-9]*;[^\x07]*\x07//g; s/\x1b][^\\]*\\//g; s/\r//g' "$capture_file" 2>/dev/null | grep -c 'sk-ant-oat01' >> "$LOG_FILE" 2>&1 || echo "0 matches" >> "$LOG_FILE"
                fi
            done
        ) &
        local _monitor_pid=$!
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Started post-inject capture monitor (PID=$_monitor_pid)" >> "$LOG_FILE"
    fi

    # Auto-poll the capture file for the sk token (token appears after code exchange)
    ui_info "Polling capture file for sk token (up to 30s)..." >&2

    local sk_token=""
    for _poll_i in $(seq 1 30); do
        sleep 1

        # Primary: grep raw capture file directly (no ANSI stripping needed)
        if [[ -f "$capture_file" ]]; then
            sk_token=$(grep -o 'sk-ant-oat01-[A-Za-z0-9_-]*' "$capture_file" 2>/dev/null | head -1)
            # Fallback: strip ANSI via sed directly on file, pipe to grep
            if [[ -z "$sk_token" ]]; then
                sk_token=$(sed 's/\x1b\[[0-9;]*[mGKHFABCDJh]//g; s/\x1b\[[?][0-9]*[hl]//g; s/\r//g' "$capture_file" 2>/dev/null \
                    | grep -o 'sk-ant-oat01-[A-Za-z0-9_-]*' | head -1)
            fi
        fi

        # Log every 5s
        if (( _poll_i % 5 == 0 )) && [[ -n "${LOG_FILE:-}" ]]; then
            local _poll_size="N/A" _poll_grep_count="0"
            if [[ -f "$capture_file" ]]; then
                _poll_size=$(stat -c%s "$capture_file" 2>/dev/null || echo "?")
                _poll_grep_count=$(grep -c 'sk-ant-oat01' "$capture_file" 2>/dev/null || echo "0")
            fi
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Token poll t=${_poll_i}s: file_size=${_poll_size}b, raw_grep_count=${_poll_grep_count}, token_found=$([ -n "$sk_token" ] && echo yes || echo no)" >> "$LOG_FILE"
        fi

        if [[ -n "$sk_token" ]]; then
            break
        fi
    done

    # Kill background monitor
    [[ -n "${_monitor_pid:-}" ]] && kill "$_monitor_pid" 2>/dev/null || true

    # Kill the auth session now that we're done with it
    tmux -L "$auth_socket" kill-session -t "$auth_session" 2>/dev/null || true

    if [[ -z "$sk_token" ]]; then
        [[ -n "${LOG_FILE:-}" ]] && {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] sk token not found after 30s" >> "$LOG_FILE"
            if [[ -f "$capture_file" ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] FULL raw capture file dump ($(stat -c%s "$capture_file" 2>/dev/null || echo '?')b):" >> "$LOG_FILE"
                cat "$capture_file" >> "$LOG_FILE" 2>&1
                echo "" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] FULL stripped capture file dump:" >> "$LOG_FILE"
                sed 's/\x1b\[[0-9;]*[mGKHFABCDJh]//g; s/\x1b\[[?][0-9]*[hl]//g; s/\r//g' "$capture_file" >> "$LOG_FILE" 2>&1
                echo "" >> "$LOG_FILE"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] capture file does NOT exist at $capture_file" >> "$LOG_FILE"
            fi
        }
        ui_warn "sk token not found in capture file after 30s." >&2
        return 1
    fi

    [[ -n "${LOG_FILE:-}" ]] && {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] sk token auto-captured from capture file" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] Token first 20 chars: ${sk_token:0:20}  total_length=${#sk_token}" >> "$LOG_FILE"
    }

    ui_ok "Successfully obtained long-lived token (sk token) from Claude!" >&2

    # Save token to .env
    write_env "CLAUDE_CODE_OAUTH_TOKEN" "$sk_token"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Wrote CLAUDE_CODE_OAUTH_TOKEN to $CLAUDE_HOME/.env" >> "$LOG_FILE"

    echo "$sk_token"
    trap - EXIT INT TERM
    return 0
}

claude_auth() {
    # ── Resolve the auth mode (token | login) ─────────────────────────────────
    # One sourceable resolver (core/auth-mode.sh) is the single source of truth;
    # claude_auth sources it itself so it works even when a caller only did
    # `source claude-auth.sh` (e.g. the Windows tray's "Reauthenticate Claude").
    #
    # Mode precedence:
    #   1. explicit arg:           claude_auth login | claude_auth token
    #   2. configured INTENT:      taskramen_auth_mode_raw  (env TASKRAMEN_AUTH_MODE,
    #                              else default — which is "login")
    # We use the RAW (intent) value, NOT the creds-gated effective value: this is
    # the ESTABLISHMENT path, so on a fresh box with no credentials.json yet the
    # default must still be "login" (run.sh/monitor.sh use the gated value for
    # runtime safety). A login establishes credentials.json + oauthAccount, the
    # connector-eligible state (issue #356); token runs the headless setup-token.
    local mode="${1:-}"
    if [[ -f "$CLAUDE_HOME/core/auth-mode.sh" ]]; then
        # shellcheck source=/dev/null
        source "$CLAUDE_HOME/core/auth-mode.sh"
        [[ -z "$mode" ]] && mode="$(taskramen_auth_mode_raw)"
    fi
    case "$mode" in login|token) ;; *) mode="token" ;; esac

    local CLAUDE
    CLAUDE=$(_claude_bin)
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Resolved claude binary: $CLAUDE" >> "$LOG_FILE"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Auth mode: $mode" >> "$LOG_FILE"
    ui_blank

    # User-visible announcement of which sign-in path this run uses, so it's clear
    # on the install/console screen (not just in the log) whether the new
    # interactive login or the legacy token path is active.
    ui_divider "Claude sign-in"
    if [ "$mode" = login ]; then
        ui_info "Sign-in method: Interactive login (Claude.ai subscription)"
        ui_bullet "Connects with your Claude.ai account — required for claude.ai connectors."
        ui_bullet "You'll approve a one-time link sent over Telegram."
    else
        ui_info "Sign-in method: Token (headless setup-token)"
        ui_bullet "Uses a long-lived CLAUDE_CODE_OAUTH_TOKEN — claude.ai connectors are not loaded."
    fi
    ui_blank

    # ── Coordinate with claudebot's Telegram plugin ──────────────────────────
    # claudebot's plugin (a bun process inside the claudebot tmux session)
    # long-polls Telegram getUpdates. Long-poll is EXCLUSIVE — if both
    # the plugin and our wait_for_reply call poll at once, replies race
    # and land at whichever wins. claude_auth's keep/new and OAuth code
    # prompts would then be stolen by the plugin.
    #
    # Plugin shutdown:
    #   - kill the plugin via bot.pid (canonical path the plugin writes
    #     on startup; same path monitor.sh:359 reads)
    #   - remove bot.pid so monitor.sh's Task 3 logs "skip no PID file"
    #     instead of attempting a respawn
    #   - pkill fallbacks for bot.pid-absent / stale cases
    # claudebot's tmux session and claude main process are left ALIVE.
    # monitor.sh's is_frozen finds claude alive and stands down naturally,
    # so no monitor.sh coordination is needed.
    #
    # Touch /tmp/claude_auth_alert_sent (the sentinel monitor.sh:514
    # already checks) to throttle monitor.sh's Task 5 auto-reauth — if
    # the user's token is expired and Task 5 fires during our reauth,
    # without this it would start a parallel reauth and race our
    # Telegram polling. Removed at each return path below.
    #
    # Trap is a safety net for abort/Ctrl-C/crash — without it the
    # sentinel would leak and permanently throttle Task 5's automatic
    # token-expiry detection until manually deleted. The trap survives
    # the `_claude_auth_tmux` call below because that helper runs in a
    # `$()` subshell (line 640), so its `trap - EXIT INT TERM` (line
    # 305) only affects the subshell — our outer trap is preserved.
    touch /tmp/claude_auth_alert_sent 2>/dev/null || true
    trap 'rm -f /tmp/claude_auth_alert_sent 2>/dev/null || true' EXIT INT TERM
    local _bot_pid_file="$HOME/.claude/channels/telegram/bot.pid"
    if [[ -f "$_bot_pid_file" ]]; then
        local _bot_pid
        _bot_pid=$(cat "$_bot_pid_file" 2>/dev/null)
        if [[ -n "$_bot_pid" ]] && kill -0 "$_bot_pid" 2>/dev/null; then
            kill "$_bot_pid" 2>/dev/null || true
            sleep 2
            if kill -0 "$_bot_pid" 2>/dev/null; then
                kill -9 "$_bot_pid" 2>/dev/null || true
                sleep 1
            fi
        fi
        rm -f "$_bot_pid_file"
    fi
    pkill -f "bun.*telegram.*server\.ts" 2>/dev/null || true
    pkill -f "bun.*external_plugins/telegram.*start" 2>/dev/null || true
    sleep 1

    # ── Check if existing token is valid ──────────────────────────────────────
    local existing_token="${CLAUDE_CODE_OAUTH_TOKEN:-}"
    if [[ -z "$existing_token" ]] && [[ -f "$CLAUDE_HOME/.env" ]]; then
        existing_token=$(grep -oP '(?<=^CLAUDE_CODE_OAUTH_TOKEN=).*' "$CLAUDE_HOME/.env" 2>/dev/null || true)
    fi

    if [ "$mode" = token ] && [[ -n "$existing_token" && "$existing_token" == sk-ant-oat01-* ]]; then
        ui_info "Checking existing Claude token..."

        # ── Why this pattern differs from core/monitor.sh's auth-status call ─
        # monitor.sh runs `claude auth status` every minute as a headless
        # daemon against a token that's already known to work. Its worry is
        # false-negative reauths: a transient CLI hiccup that fails JSON
        # parse would kick off a full OAuth flow on every cycle, so it treats
        # any inconclusive output as "assume valid".
        #
        # The installer's worries are the opposite:
        #   1. HANG RISK. This is often the FIRST `claude auth status` call
        #      ever in a fresh container/VM, with a TTY attached to stdin.
        #      If the CLI tries to prompt (onboarding, update, terms) it
        #      blocks on a TTY read; the substitution `$()` then waits on
        #      the still-open stdout pipe. PR #282 added `timeout 30` here
        #      thinking that would bound it — but plain `timeout` sends only
        #      SIGTERM, which the Node-based `claude` wrapper routinely
        #      ignores, so the pipe stays open and we hang past 30s anyway.
        #      Defenses below:
        #         </dev/null         — CLI cannot block reading from stdin
        #         --kill-after=5 60  — SIGKILL 5s after SIGTERM; generous
        #                              60s window for legitimate cold start
        #   2. INCONCLUSIVE BIAS. Empty/unparseable output is treated as
        #      INVALID here (force reauth), not as "assume valid". In
        #      installer context, reauth is cheap (user is already at the
        #      terminal, tmux setup-token flow re-runs, paste OAuth code,
        #      done). A false-positive reauth is mildly annoying; a
        #      false-positive "everything's fine" leaves the user with a
        #      broken install.
        # Stderr stays redirected to /dev/null so banner noise can't pollute
        # the JSON parse (the diagnosis PR #282 got right).
        local status_out logged_in _stderr_file _stderr _exit_code
        # mktemp -t with template: portable across GNU + BSD coreutils
        # (plain `mktemp` is GNU-only — fails on macOS / some BSDs).
        # Fallback path mixes $RANDOM + $$ to defeat the predictable-name
        # symlink race that a plain $$ filename in /tmp invites (CWE-377).
        _stderr_file=$(mktemp -t claude-auth-stderr.XXXXXX 2>/dev/null || echo "/tmp/_claude-auth-stderr-$RANDOM-$$")
        _exit_code=0
        status_out=$(CLAUDE_CODE_OAUTH_TOKEN="$existing_token" \
            timeout --kill-after=5 60 $CLAUDE auth status </dev/null 2>"$_stderr_file") || _exit_code=$?
        # `|| true` so set -e can't trip if the 2> redirect above failed to
        # create the file (e.g. tmpfs full / readonly /tmp / permissions).
        # Losing stderr on the diagnostic path is acceptable; aborting the
        # whole installer because we couldn't read a debug aid is not.
        _stderr=$(cat "$_stderr_file" 2>/dev/null || true)
        rm -f "$_stderr_file"
        logged_in=$(echo "$status_out" | python3 -c '
import json, sys, re
data = sys.stdin.read()
try:
    print(json.loads(data).get("loggedIn", False))
except Exception:
    # Fallback for pretty-printed JSON or output with prefix garbage:
    # match the loggedIn field directly.
    m = re.search(r'"'"'"loggedIn"\s*:\s*(true|false)'"'"', data, re.IGNORECASE)
    if m:
        print("True" if m.group(1).lower() == "true" else "False")
' 2>/dev/null)

        # Two-way for the installer: True → keep/new prompt; anything else
        # (False, empty, garbage) → fall through to reauth. See header
        # comment above for why we don't carry monitor.sh's third "assume
        # valid on inconclusive" branch into the installer.
        #
        # Diagnostic on the unhappy path: PR #288 added a parsed-value +
        # stdout-snippet log. That showed parsed='' AND raw='' for the
        # tray-reauth case — i.e. the CLI produced ZERO bytes on stdout.
        # That can be either (a) killed by timeout, or (b) exited fast
        # with error to stderr (which we'd been redirecting to /dev/null).
        # This round captures stderr + exit code + the resolved $CLAUDE
        # binary path so we can tell which it is. Still routes to
        # $LOG_FILE in installer context (invisible to the user) or to
        # stderr in the tray context (visible in the tray's console
        # window, which is where users can see and report it).
        if [[ "$logged_in" != "True" ]]; then
            # Comprehensive diagnostic block. Goal: one round-trip should
            # tell us *exactly* why a valid token isn't being recognized.
            # All probes are run with `|| true` and short timeouts so they
            # cannot affect control flow. Each result is appended to a
            # multi-line diag string emitted as one block.
            local _diag _line
            _diag=""

            _line="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] === claude auth pre-check diagnostic ==="
            _diag+="${_line}\n"

            # Primary call result (already captured).
            _diag+="[parse]     parsed='${logged_in}' exit=${_exit_code}\n"
            _diag+="[primary]   stdout(first 500): $(printf '%s' "$status_out" | tr '\n' ' ' | cut -c1-500)\n"
            _diag+="[primary]   stderr(first 500): $(printf '%s' "$_stderr" | tr '\n' ' ' | cut -c1-500)\n"

            # Resolved binary + version. Tells us if $CLAUDE is healthy
            # at all, separate from auth flow. `--version` should be
            # fast, deterministic, and require no creds.
            _diag+="[binary]    CLAUDE='${CLAUDE}'\n"
            local _which
            _which=$(command -v "${CLAUDE%% *}" 2>/dev/null || echo "<not on PATH>")
            _diag+="[binary]    which: ${_which}\n"
            local _ver _ver_ec=0
            _ver=$(timeout --kill-after=5 15 $CLAUDE --version </dev/null 2>&1) || _ver_ec=$?
            _diag+="[binary]    --version exit=${_ver_ec} out: $(printf '%s' "$_ver" | tr '\n' ' ' | cut -c1-200)\n"

            # Env state. We do NOT log the token itself — just length +
            # prefix so we can confirm it's plausibly a sk-ant-oat01 and
            # not empty/truncated. Also $HOME (CLI resolves creds via
            # \$HOME/.claude) and PATH (resolution sanity).
            _diag+="[env]       CLAUDE_CODE_OAUTH_TOKEN: len=${#existing_token} prefix='${existing_token:0:14}...'\n"
            _diag+="[env]       HOME='${HOME:-<unset>}'\n"
            _diag+="[env]       PATH(first 200): $(printf '%s' "${PATH:-}" | cut -c1-200)\n"

            # Stored credential state. The CLI may prefer
            # ~/.claude/credentials.json over the env-var token in
            # recent versions, in which case a missing/empty creds file
            # would explain loggedIn:false despite a working env-var.
            local _creds="$HOME/.claude/credentials.json"
            if [[ -e "$_creds" ]]; then
                _diag+="[creds]     $_creds: exists, size=$(stat -c%s "$_creds" 2>/dev/null || echo '?')b\n"
            else
                _diag+="[creds]     $_creds: ABSENT\n"
            fi
            # Container's symlinked creds (entrypoint sometimes routes here).
            local _creds2="${CLAUDE_HOME:-}/.claude/.credentials.json"
            if [[ -e "$_creds2" ]]; then
                _diag+="[creds]     $_creds2: exists, size=$(stat -c%s "$_creds2" 2>/dev/null || echo '?')b\n"
            else
                _diag+="[creds]     $_creds2: ABSENT\n"
            fi

            # Re-run probe 1: drop </dev/null. If the CLI was failing
            # because we starved it of stdin, this run will produce
            # different output than the primary call above.
            local _alt1_out _alt1_err _alt1_ec=0 _alt1_errfile
            _alt1_errfile=$(mktemp -t claude-alt1.XXXXXX 2>/dev/null || echo "/tmp/_claude-alt1-$RANDOM-$$")
            _alt1_out=$(CLAUDE_CODE_OAUTH_TOKEN="$existing_token" \
                timeout --kill-after=5 30 $CLAUDE auth status 2>"$_alt1_errfile") || _alt1_ec=$?
            _alt1_err=$(cat "$_alt1_errfile" 2>/dev/null || true)
            rm -f "$_alt1_errfile"
            _diag+="[alt1:noStdinRedir] exit=${_alt1_ec} stdout(200): $(printf '%s' "$_alt1_out" | tr '\n' ' ' | cut -c1-200)\n"
            _diag+="[alt1:noStdinRedir] stderr(200): $(printf '%s' "$_alt1_err" | tr '\n' ' ' | cut -c1-200)\n"

            # Re-run probe 2: rely on already-exported env-var, drop the
            # inline prefix. If bash is somehow failing to propagate the
            # VAR=... prefix through `timeout`, this run will succeed
            # where the primary failed.
            local _alt2_out _alt2_err _alt2_ec=0 _alt2_errfile
            _alt2_errfile=$(mktemp -t claude-alt2.XXXXXX 2>/dev/null || echo "/tmp/_claude-alt2-$RANDOM-$$")
            _alt2_out=$(timeout --kill-after=5 30 $CLAUDE auth status </dev/null 2>"$_alt2_errfile") || _alt2_ec=$?
            _alt2_err=$(cat "$_alt2_errfile" 2>/dev/null || true)
            rm -f "$_alt2_errfile"
            _diag+="[alt2:noPrefix] exit=${_alt2_ec} stdout(200): $(printf '%s' "$_alt2_out" | tr '\n' ' ' | cut -c1-200)\n"
            _diag+="[alt2:noPrefix] stderr(200): $(printf '%s' "$_alt2_err" | tr '\n' ' ' | cut -c1-200)\n"

            _diag+="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] === end diagnostic ==="

            # Emit the whole block at once so it stays contiguous in the
            # console / log even if other writers are active.
            if [[ -n "${LOG_FILE:-}" ]]; then
                printf '%b\n' "$_diag" >> "$LOG_FILE"
            else
                printf '%b\n' "$_diag" >&2
            fi
            unset _diag _line _which _ver _ver_ec _alt1_out _alt1_err _alt1_ec _alt1_errfile _alt2_out _alt2_err _alt2_ec _alt2_errfile _creds _creds2

            ui_warn "Existing token check did not confirm a valid session. Re-authenticating..."
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Existing token check returned '$logged_in' (need 'True'); proceeding with re-auth" >> "$LOG_FILE"
        else
            # Same parse-then-regex-fallback shape as logged_in above:
            # without the fallback, banner pollution would silently drop the
            # email and the user sees the generic "Claude is already
            # authenticated" instead of "...authenticated as <email>".
            local acct_email=""
            acct_email=$(echo "$status_out" | python3 -c '
import json, sys, re
data = sys.stdin.read()
try:
    d = json.loads(data)
    print(d.get("emailAddress") or d.get("email") or "")
except Exception:
    m = re.search(r'"'"'"email(?:Address)?"\s*:\s*"([^"]+)"'"'"', data, re.IGNORECASE)
    print(m.group(1) if m else "")
' 2>/dev/null || true)
            local acct_msg="Claude is already authenticated"
            [[ -n "$acct_email" ]] && acct_msg="Claude is already authenticated as ${acct_email}"
            ui_ok "$acct_msg."
            # Tell the user where the next interaction lives. The
            # keep/new prompt is sent to Telegram (see below) — without
            # this line, users sit at this terminal wondering why
            # nothing's happening.
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                ui_info "Check Telegram and reply *keep* to keep, or *new* to re-authenticate."
            fi

            # Prompt via Telegram if available, otherwise terminal
            local choice=""
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                send_tg "🔐 ${acct_msg}. Keep existing authentication or re-authenticate? Reply *keep* or *new*" "Markdown"
                choice=$(wait_for_reply 120) || true
            else
                printf "  ${C_BRIGHT_WHITE}Keep existing authentication or re-authenticate? (keep/new):${C_RESET}  "
                read -r choice
            fi
            # printf '%s' rather than echo: a $choice that happens to start
            # with `-n` / `-e` would be eaten as a flag by some echo impls
            # (per gemini review on this PR).
            choice=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if [[ "$choice" != "new" ]]; then
                ui_ok "Keeping existing Claude authentication."
                [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && send_tg "✅ Keeping existing Claude authentication." "Markdown"
                # Make sure the install-state flags in settings.json are
                # present even on the "keep" path. Without this,
                # entrypoint.sh's _check_install_state ("settings"
                # category) fails after an interactive reinstall ->
                # the .auth-complete marker is never written ->
                # orchestrator step 8 times out. See the function's
                # docstring for the full history.
                _ensure_claude_settings_flags >/dev/null 2>&1 || true
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Ensured settings.json flags on keep-existing-credentials path" >> "$LOG_FILE"
                # Bring the Telegram plugin back so the user can interact
                # with claude immediately via Telegram (no need to close
                # this reauth terminal). pkill claude → run.sh's
                # while-loop respawns claude+plugin within ~5s. .env is
                # unchanged so no full tmux restart needed. Skip in
                # installer context (LOG_FILE set) — claudebot isn't
                # running yet; entrypoint.sh starts it after install.sh
                # exits, and starting it early would conflict.
                if [[ -z "${LOG_FILE:-}" ]]; then
                    pkill -TERM -f 'claude.*--channels' 2>/dev/null || true
                fi
                rm -f /tmp/claude_auth_alert_sent 2>/dev/null || true
                return 0
            fi
            ui_blank
            ui_info "Re-authenticating..."
            [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && send_tg "🔄 Re-authenticating Claude..." "Markdown"
            ui_blank
        fi
    fi

    # ── Run the OAuth flow ────────────────────────────────────────────────────
    local token=""
    if [ "$mode" = login ]; then
        # Pre-seed onboarding so the interactive TUI skips theme/welcome before
        # reaching the login step.
        _preseed_onboarding
        # On reinstall with a valid existing interactive login, offer keep/new
        # over Telegram — the SAME prompt the token path has always shown.
        # Issue #377: once login became the default mode, a reinstall jumped
        # straight here and silently re-applied the existing login without ever
        # asking, because the keep/new prompt lived only in the token branch.
        # Default ("keep", no reply, or a bare terminal Enter) re-applies the
        # existing login; only an explicit "new" forces a fresh OAuth sign-in.
        # A still-valid token-only install (no credentials.json) is NOT prompted
        # — taskramen_creds_present is false, so _relogin stays true and it falls
        # straight through to a forced login migration.
        local _relogin=true
        if taskramen_creds_present && [ "$(_login_status)" = "True" ]; then
            _relogin=false
            local acct_msg="Claude is already authenticated (interactive login)"
            ui_ok "$acct_msg."
            # Tell the user where the next interaction lives (mirrors the token
            # path) — without this they sit at this terminal wondering why
            # nothing is happening while the keep/new prompt waits on Telegram.
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                ui_info "Check Telegram and reply *keep* to keep, or *new* to re-authenticate."
            fi
            local choice=""
            if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
                send_tg "🔐 Claude is already authenticated. Keep existing authentication or re-authenticate? Reply *keep* or *new*" "Markdown"
                choice=$(wait_for_reply 120) || true
            else
                printf "  ${C_BRIGHT_WHITE}Keep existing authentication or re-authenticate? (keep/new):${C_RESET}  "
                read -r choice
            fi
            # printf '%s' rather than echo: a $choice starting with -n/-e would
            # be eaten as a flag by some echo impls (matches the token path).
            choice=$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            if [[ "$choice" == "new" ]]; then
                _relogin=true
                ui_blank
                ui_info "Re-authenticating..."
                [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && send_tg "🔄 Re-authenticating Claude..." "Markdown"
                ui_blank
            else
                ui_ok "Keeping existing Claude interactive login."
                [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]] && send_tg "✅ Keeping existing Claude authentication." "Markdown"
            fi
        fi

        if [[ "$_relogin" == "true" ]]; then
            # Retry indefinitely until login completes — SAME contract as the
            # token loop below: claude_auth either succeeds or keeps trying, it
            # never returns a failure. This matters for two reasons: (1) install.sh
            # runs under `set -e`, so a non-zero return would abort the install;
            # (2) the Telegram poller was quiesced once above and is restored once
            # after success (the shared restart at the end) — there is no failure
            # path that could return early and leave the poller dead.
            local _attempt=0
            while true; do
                _attempt=$((_attempt + 1))
                [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Claude login tmux attempt $_attempt" >> "$LOG_FILE"
                # Subshell so _claude_auth_tmux's EXIT trap is scoped to it — the
                # same isolation the token path gets from `$(_claude_auth_tmux)`.
                if ( _claude_auth_tmux login ); then break; fi
                ui_warn "Login did not complete. Retrying..."
                send_tg "⚠️ Login didn't complete. Let's try again." "Markdown"
            done
        else
            ui_ok "A valid interactive login already exists — (re)applying login mode."
        fi
    else
        # Retry tmux method indefinitely until successful
        local _attempt=0
        while true; do
            _attempt=$((_attempt + 1))
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Claude auth tmux attempt $_attempt" >> "$LOG_FILE"

            token=$(_claude_auth_tmux) || true

            if [[ -n "$token" && "$token" == sk-ant-oat01-* ]]; then
                break
            fi

            # Token not obtained — notify user and retry
            ui_warn "Token appears incorrect. Retrying..."
            send_tg "⚠️ Token appears incorrect. Let's try again." "Markdown"
            token=""
        done
    fi

    # Lock down .env permissions so the token file is owner-read-only
    chmod 600 "$CLAUDE_HOME/.env" 2>/dev/null || true

    # Source CLAUDE_CODE_OAUTH_TOKEN from .env in ~/.bashrc so any shell has it.
    # Token mode only (login mode does not use the env-var token). Skip in
    # container mode — .bashrc is on read-only filesystem.
    if [ "$mode" = token ] && [[ ! -f /.dockerenv && "${CONTAINER:-}" != "true" ]]; then
        local bashrc="$HOME/.bashrc"
        local source_line="[ -f \"$CLAUDE_HOME/.env\" ] && export \$(grep -s CLAUDE_CODE_OAUTH_TOKEN \"$CLAUDE_HOME/.env\" | xargs)"
        local marker="# taskramen: load CLAUDE_CODE_OAUTH_TOKEN"
        if ! grep -qF "$marker" "$bashrc" 2>/dev/null; then
            printf '\n%s\n%s\n' "$marker" "$source_line" >> "$bashrc"
        fi
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Added .env source line to $bashrc (token stays in 600-perms .env)" >> "$LOG_FILE"
    fi

    # Write ~/.claude.json for onboarding skip
    # In container mode, ~/.claude.json is symlinked to the writable volume
    local claude_json="$HOME/.claude.json"
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        claude_json="$CLAUDE_HOME/.claude/.claude.json"
    fi
    python3 -c '
import json, sys, os
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    data = {}
data["hasCompletedOnboarding"] = True
data["lastOnboardingVersion"] = "2.1.91"
with open(path, "w") as f:
    json.dump(data, f, indent=2)
' "$claude_json"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Wrote/updated ~/.claude.json with onboarding flags" >> "$LOG_FILE"

    # Ensure install-state flags on ~/.claude/settings.json. Shared
    # with the "keep existing credentials" path above so both code
    # paths leave settings.json in the same state -- see the
    # _ensure_claude_settings_flags function's docstring at the top
    # of this file for the full history.
    _ensure_claude_settings_flags >/dev/null 2>&1 || true
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Ensured settings.json flags on new-auth path" >> "$LOG_FILE"

    # ── Login mode: flip .env into login mode ─────────────────────────────────
    # Comment the headless token (so #5 can't shadow #6) and persist
    # TASKRAMEN_AUTH_MODE=login. Done only after the login is established+verified
    # (above), never on a partial creds file.
    local _login_backup=""
    if [ "$mode" = login ]; then
        _login_backup=$(_apply_login_mode)
        ui_info "Switched .env to login mode (backup: $_login_backup)."
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Applied login mode; .env backup: $_login_backup" >> "$LOG_FILE"
    fi

    # Verify auth. Same hang defenses as the pre-check above (see the long
    # comment there for why this pattern intentionally diverges from
    # core/monitor.sh's): `</dev/null` so the CLI can't block on a TTY read
    # on its first invocation, and `timeout --kill-after=5 60` so SIGKILL
    # frees the substitution even when the Node wrapper swallows SIGTERM
    # (plain `timeout 30` was the source of the PR #282 hang at this very
    # message). Stderr → /dev/null so banner noise can't pollute JSON parse.
    #
    # Three-way mapping differs from the pre-check though: an inconclusive
    # result here means we just shape-checked a sk-ant-oat01-* token from
    # the tmux flow but `auth status` didn't confirm in time. The token is
    # structurally valid and already saved to .env, so empty is treated as
    # success — only a definitive loggedIn:false produces a warning.
    if [ "$mode" = login ]; then
        # Login was already established AND verified (auth status) inside
        # _claude_auth_tmux before we ever flipped .env, so no re-verify here.
        ui_ok "Claude interactive login active (claude.ai connectors enabled)."
        send_tg "✅ *Claude authenticated\!*
🚀 Starting your assistant now\.\.\." "MarkdownV2"
    else
    ui_info "Verifying Claude authentication..."
    local status_out logged_in
    status_out=$(CLAUDE_CODE_OAUTH_TOKEN="$token" \
        timeout --kill-after=5 60 $CLAUDE auth status </dev/null 2>/dev/null) || true
    logged_in=$(echo "$status_out" | python3 -c '
import json, sys, re
data = sys.stdin.read()
try:
    print(json.loads(data).get("loggedIn", False))
except Exception:
    # Fallback for pretty-printed JSON or output with prefix garbage:
    # match the loggedIn field directly.
    m = re.search(r'"'"'"loggedIn"\s*:\s*(true|false)'"'"', data, re.IGNORECASE)
    if m:
        print("True" if m.group(1).lower() == "true" else "False")
' 2>/dev/null)
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] claude auth status: $status_out" >> "$LOG_FILE"

    if [[ "$logged_in" == "False" ]]; then
        ui_warn "Auth status reports the new token is not logged in. The token has been saved; Claude will attempt to use it on startup."
        [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Post-auth check returned loggedIn=False" >> "$LOG_FILE"
        send_tg "⚠️ Auth status check didn't confirm login, but the token has been saved. Claude will attempt to use it on startup." "Markdown"
    else
        ui_ok "Claude account activated!"
        send_tg "✅ *Claude authenticated\!*
🚀 Starting your assistant now\.\.\." "MarkdownV2"
    fi
    fi

    # Full claudebot restart so run.sh re-sources .env and the freshly-
    # spawned claude picks up the new CLAUDE_CODE_OAUTH_TOKEN. Same
    # primitive PodmanHelper.RestartClaudeSessionFull uses. Skip in
    # installer context —
    # entrypoint.sh starts claudebot after install.sh exits, and
    # starting it early would conflict with that line.
    if [[ -z "${LOG_FILE:-}" ]]; then
        if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
            tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
            sleep 2
            tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh"
            tmux -L claudebot pipe-pane -t claudebot "cat >> ${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
        else
            sudo systemctl restart claudebot.service >/dev/null 2>&1 || true
        fi
    fi
    rm -f /tmp/claude_auth_alert_sent 2>/dev/null || true
}
