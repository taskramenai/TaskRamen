#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/config.sh — Write/update .env, generate .mcp.json, copy settings.json
# Sources: install/ui.sh, install/utils.sh

# Branding (PRODUCT_NAME, APP_SLUG) -- guarded source so the values resolve
# whenever CLAUDE_HOME is known, regardless of caller / source order.
[ -n "${CLAUDE_HOME:-}" ] && [ -f "$CLAUDE_HOME/core/branding.sh" ] && source "$CLAUDE_HOME/core/branding.sh"

config_generate() {
    ui_info "Generating config files..."

    # ── Ensure .env exists ───────────────────────────────────────────────────
    if [[ ! -f "$CLAUDE_HOME/.env" ]]; then
        cp "$CLAUDE_HOME/.env.example" "$CLAUDE_HOME/.env"
        chmod 600 "$CLAUDE_HOME/.env"
    fi

    # ── Write paths to .env ──────────────────────────────────────────────────
    write_env "CLAUDE_HOME" "$CLAUDE_HOME"
    write_env "USER_HOME"   "$HOME"
    write_env "CLOUDFLARED_BIN" "$HOME/bin/cloudflared"

    # Generate webhook channel secret if not already set
    if ! grep -q "^WEBHOOK_CHANNEL_SECRET=" "$CLAUDE_HOME/.env" 2>/dev/null; then
        local webhook_secret
        webhook_secret=$(python3 -c "import secrets; print(secrets.token_hex(32))")
        write_env "WEBHOOK_CHANNEL_SECRET" "$webhook_secret"
    fi

    # ── Generate minimal .mcp.json (no Google credentials yet) ───────────────
    # Only written if it doesn't already exist; google credentials added later
    if [[ ! -f "$CLAUDE_HOME/.mcp.json" ]]; then
        cat > "$CLAUDE_HOME/.mcp.json" <<'EOF'
{
  "mcpServers": {}
}
EOF
        chmod 600 "$CLAUDE_HOME/.mcp.json"
    fi

    # ── Copy settings.json into ~/.claude/ ───────────────────────────────────
    local settings_src="$CLAUDE_HOME/config/claude-settings.json.example"
    local settings_dst="$HOME/.claude/settings.json"

    mkdir -p "$HOME/.claude"
    if [[ ! -f "$settings_dst" ]]; then
        cp "$settings_src" "$settings_dst"
        ui_ok "Installed ~/.claude/settings.json"
    else
        # MERGE, don't skip. This used to bail out whenever the file existed,
        # which left required keys unset forever — most importantly
        # skipDangerousModePermissionPrompt, the very key entrypoint.sh's
        # _check_install_state greps for to decide whether the install finished.
        # The result was an install wizard that re-ran on every container boot.
        # Merge is additive and idempotent: absent top-level keys are filled from
        # the template and permissions.allow is unioned, but anything the user
        # already set is left exactly as-is.
        python3 -c '
import json, os, sys

src, dst = sys.argv[1], sys.argv[2]

with open(src) as f:
    template = json.load(f)
try:
    with open(dst) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise ValueError("settings.json is not a JSON object")
except FileNotFoundError:
    data = {}
except (json.JSONDecodeError, ValueError, OSError) as exc:
    # Do NOT silently start from {} — that discards every setting the user has,
    # while the caller goes on to report a successful merge. Keep the damaged
    # file so it can be inspected, and let the installer say what happened.
    backup = dst + ".corrupt"
    try:
        os.replace(dst, backup)
        note = " (moved aside to %s)" % backup
    except OSError:
        note = ""
    sys.stderr.write(
        "settings.json could not be parsed (%s)%s — starting from the template.\n"
        % (exc, note))
    data = {}

added = []
for key, value in template.items():
    # permissions is unioned below. model is deliberately NOT merged: it is a
    # preference, not an install requirement — a pre-existing settings.json
    # with no model key means the install runs on the CLI default, and
    # injecting the template value here would silently re-pin it. Fresh
    # installs still get the template model via the copy path above.
    if key in ("permissions", "model"):
        continue
    if key not in data:
        data[key] = value
        added.append(key)

# permissions.allow: union the template entries in, preserving user additions
# and ordering. permissions.deny is managed by the hook block further down.
tmpl_allow = (template.get("permissions") or {}).get("allow") or []
perms = data.get("permissions")
if not isinstance(perms, dict):
    perms = {}
    data["permissions"] = perms
allow = perms.get("allow")
if not isinstance(allow, list):
    allow = []
for entry in tmpl_allow:
    if entry not in allow:
        allow.append(entry)
        added.append("permissions.allow:" + str(entry))
perms["allow"] = allow

with open(dst, "w") as f:
    json.dump(data, f, indent=2)

print(",".join(added))
' "$settings_src" "$settings_dst" >/dev/null
        ui_ok "Merged required keys into existing ~/.claude/settings.json"
    fi

    # ── Inject hooks into settings.json ──────────────────────────────────────
    # Refreshes TaskRamen-owned hook entries (matched by claude_home in the
    # command) so paths stay correct on re-runs; user-added hooks are preserved
    python3 -c '
import json, sys, os

path = os.path.expanduser("~/.claude/settings.json")
claude_home = sys.argv[1]

try:
    with open(path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, OSError):
    data = {}

reply_gate = claude_home + "/core/hooks/reply-gate.sh"
ours = {
    "PreToolUse": [
        {
            "matcher": "Agent",
            "hooks": [
                {
                    "type": "command",
                    "command": claude_home + "/core/hooks/inject-agent-prompt.sh"
                },
                {
                    "type": "command",
                    "command": "bash " + claude_home + "/core/pre-agent-watcher.sh",
                    "async": True
                }
            ]
        }
    ],
    # Reply gate (issue #432): one-shot advisory nudge when a turn ends with
    # terminal text but no Telegram send. See core/hooks/reply-gate.sh.
    "UserPromptSubmit": [
        {"hooks": [{"type": "command", "command": reply_gate + " clear"}]}
    ],
    "MessageDisplay": [
        {"hooks": [{"type": "command", "command": reply_gate + " text"}]}
    ],
    "PostToolUse": [
        {
            "matcher": "mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__edit_message",
            "hooks": [{"type": "command", "command": reply_gate + " replied"}]
        },
        {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": reply_gate + " bash"}]
        },
        # Stale frozen-alert prevention (issue #437): flag a deliberately
        # stopped agent so its status watcher exits silently.
        # See core/hooks/task-stopped.sh.
        {
            "matcher": "TaskStop",
            "hooks": [{"type": "command", "command": claude_home + "/core/hooks/task-stopped.sh"}]
        }
    ],
    # PostToolUse fires only on SUCCESS; a failed TaskStop (unknown id / task
    # already finished — exactly the stale case) fires PostToolUseFailure, so
    # the stop hook is registered under both events.
    "PostToolUseFailure": [
        {
            "matcher": "TaskStop",
            "hooks": [{"type": "command", "command": claude_home + "/core/hooks/task-stopped.sh"}]
        }
    ],
    "Stop": [
        {"hooks": [{"type": "command", "command": reply_gate + " stop"}]}
    ]
}

# Merge per event: drop stale TaskRamen entries so paths stay correct on
# re-runs (matched by script name, not path, so entries from a previous
# install location are also replaced), but preserve hooks the user added.
OUR_SCRIPTS = (
    "core/hooks/inject-agent-prompt.sh",
    "core/hooks/reply-gate.sh",
    "core/hooks/task-stopped.sh",
    "core/pre-agent-watcher.sh",
)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    hooks = {}
data["hooks"] = hooks
for event, entries in ours.items():
    existing = hooks.get(event)
    if not isinstance(existing, list):
        existing = []
    kept = []
    for entry in existing:
        try:
            cmds = " ".join(h.get("command", "") for h in entry.get("hooks", []))
        except (AttributeError, TypeError):
            cmds = ""
        if claude_home not in cmds and not any(s in cmds for s in OUR_SCRIPTS):
            kept.append(entry)
    hooks[event] = kept + entries

# Always ensure marketplace + plugin enabled (needed even if settings.json
# already existed before the installer ran — e.g. created by a prior claude run)
data.setdefault("extraKnownMarketplaces", {})["claude-plugins-official"] = {
    "source": {"source": "github", "repo": "anthropics/claude-plugins-official"}
}
data.setdefault("enabledPlugins", {})["telegram@claude-plugins-official"] = True

# Deny prompt-creating tools (issue #461): the session runs headless over
# Telegram, so AskUserQuestion / ExitPlanMode render a blocking TUI prompt
# nobody can answer — it wedges the model until the #448 watchdog Escapes it.
# A bare tool name in permissions.deny removes the tool from Claude context
# entirely, so no prompt is ever drawn. Additive + idempotent so existing
# installs pick it up on re-run without disturbing user-defined rules.
perms = data.get("permissions")
if not isinstance(perms, dict):
    perms = {}
    data["permissions"] = perms
deny = perms.get("deny")
if not isinstance(deny, list):
    deny = []
for _t in ("AskUserQuestion", "ExitPlanMode"):
    if _t not in deny:
        deny.append(_t)
perms["deny"] = deny

# Remove webhook-channel from enabledMcpjsonServers if present — the server is
# loaded via --dangerously-load-development-channels server:webhook-channel in
# run.sh. Having it in enabledMcpjsonServers too causes Claude Code to spawn TWO
# instances (double-load), and the second crashes on EADDRINUSE for port 8788.
servers = data.get("enabledMcpjsonServers", [])
if "webhook-channel" in servers:
    servers.remove("webhook-channel")
    if not servers:
        data.pop("enabledMcpjsonServers", None)
    else:
        data["enabledMcpjsonServers"] = servers

with open(path, "w") as f:
    json.dump(data, f, indent=2)
' "$CLAUDE_HOME"
    ui_ok "Registered hooks in ~/.claude/settings.json"

    # ── Publish Claude Code skills ───────────────────────────────────────────
    # .claude/skills/ is generated from .agents/skills/, not committed — see
    # core/link-skills.sh for why.
    if [[ -x "$CLAUDE_HOME/core/link-skills.sh" ]]; then
        "$CLAUDE_HOME/core/link-skills.sh" >/dev/null 2>&1 || true
        ui_ok "Published skills into ~/.claude/skills/"
    fi

    # ── Install the git hooks ────────────────────────────────────────────────
    # core/git-hooks/pre-commit refuses to commit paths holding real user data.
    # Pointing core.hooksPath at a tracked directory means the hook survives
    # re-clones and updates, unlike anything written into .git/hooks.
    if [[ -d "$CLAUDE_HOME/.git" && -d "$CLAUDE_HOME/core/git-hooks" ]]; then
        chmod +x "$CLAUDE_HOME/core/git-hooks/"* 2>/dev/null || true
        if git -C "$CLAUDE_HOME" config core.hooksPath core/git-hooks 2>/dev/null; then
            ui_ok "Installed git pre-commit guard (core/git-hooks)"
        fi
    fi

    # ── Auto-trust CLAUDE_HOME to skip "Do you trust this folder?" dialog ───
    # Trust state lives in ~/.claude.json under projects.<path>.hasTrustDialogAccepted
    # In container mode, ~/.claude.json is on read-only fs — write to $CLAUDE_HOME/.claude/ instead
    python3 -c '
import json, sys, os

container = os.path.exists("/.dockerenv") or os.environ.get("CONTAINER") == "true"
if container:
    claude_home = os.environ.get("CLAUDE_HOME", os.path.expanduser("~/" + os.environ.get("APP_SLUG", "taskramen")))
    path = os.path.join(claude_home, ".claude", ".claude.json")
else:
    path = os.path.expanduser("~/.claude.json")

os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, OSError):
    data = {}

projects = data.setdefault("projects", {})
project_key = sys.argv[1]
entry = projects.setdefault(project_key, {})
entry["hasTrustDialogAccepted"] = True

with open(path, "w") as f:
    json.dump(data, f, indent=2)
' "$CLAUDE_HOME"
    ui_ok "Trusted $CLAUDE_HOME (workspace trust dialog will be skipped)"

    # ── Install Telegram plugin for --channels support ───────────────────────
    # Bypass `claude plugin install` entirely — it uses an Ink/React TUI that
    # requires interactive keyboard input and clones via SSH by default (hangs
    # on fresh VMs with no known_hosts). Instead: clone the marketplace repo
    # directly via HTTPS, copy the plugin files, and write the JSON metadata.
    _install_telegram_plugin_manual() {
        local plugin_base="$HOME/.claude/plugins"
        local marketplace_dir="$plugin_base/marketplaces/claude-plugins-official"
        local repo_url="https://github.com/anthropics/claude-plugins-official.git"

        ui_info "Installing Telegram plugin (direct)..."

        # Clone marketplace repo (sparse — telegram subdir only) if not present.
        # Retry with backoff: a single transient github clone blip would otherwise
        # leave the plugin uninstalled until the next container start re-clones it,
        # and the telegram MCP can't connect in that window.
        if [[ ! -d "$marketplace_dir/.git" ]]; then
            local _clone_ok="" _delay=2 _a
            for _a in 1 2 3 4; do
                # Clear any partial clone so the retry isn't blocked by a
                # non-empty dest. Guard the rm to the intended marketplace path.
                if [[ "$marketplace_dir" == */claude-plugins-official ]]; then
                    rm -rf "$marketplace_dir" 2>/dev/null || true
                fi
                mkdir -p "$marketplace_dir"
                if git clone --depth 1 --filter=blob:none --sparse \
                        "$repo_url" "$marketplace_dir" >/dev/null 2>&1; then
                    _clone_ok=1; break
                fi
                if [[ $_a -lt 4 ]]; then
                    sleep "$_delay"
                    _delay=$((_delay * 2))
                fi
            done
            [[ -n "$_clone_ok" ]] || return 1
        fi
        # Ensure marketplace index + telegram plugin are checked out.
        # .claude-plugin/marketplace.json is the 73KB index Claude Code reads to
        # validate that "telegram" exists in the marketplace — without it you get
        # "Plugin 'telegram' not found in marketplace" even if files are present.
        (cd "$marketplace_dir" && git sparse-checkout set .claude-plugin external_plugins/telegram >/dev/null 2>&1) || true
        (cd "$marketplace_dir" && git pull --depth 1 >/dev/null 2>&1) || true

        local src_dir="$marketplace_dir/external_plugins/telegram"
        [[ -f "$src_dir/package.json" ]] || return 1

        # Read version from package.json (fallback to 0.0.6)
        local version
        version=$(python3 -c "import json; print(json.load(open('$src_dir/package.json')).get('version','0.0.6'))" 2>/dev/null || echo "0.0.6")

        local cache_dir="$plugin_base/cache/claude-plugins-official/telegram/$version"
        mkdir -p "$cache_dir"
        cp -r "$src_dir/." "$cache_dir/"

        # Write known_marketplaces.json
        python3 -c "
import json, os
path = '$plugin_base/known_marketplaces.json'
try:
    data = json.load(open(path))
except:
    data = {}
data['claude-plugins-official'] = {
    'source': {'source': 'github', 'repo': 'anthropics/claude-plugins-official'},
    'installLocation': '$marketplace_dir',
    'lastUpdated': __import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
}
json.dump(data, open(path, 'w'), indent=2)
"

        # Write/update installed_plugins.json
        python3 -c "
import json, datetime
path = '$plugin_base/installed_plugins.json'
try:
    data = json.load(open(path))
except:
    data = {'version': 2, 'plugins': {}}
now = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.000Z')
data['plugins']['telegram@claude-plugins-official'] = [{
    'scope': 'user',
    'installPath': '$cache_dir',
    'version': '$version',
    'installedAt': now,
    'lastUpdated': now
}]
json.dump(data, open(path, 'w'), indent=2)
"
        return 0
    }

    local CLAUDE
    CLAUDE=$(_claude_bin 2>/dev/null || echo "claude")
    if $CLAUDE plugin list 2>/dev/null | grep -q "telegram@claude-plugins-official"; then
        ui_ok "Telegram plugin already installed."
    elif _install_telegram_plugin_manual; then
        ui_ok "Telegram plugin installed."
    else
        ui_warn "Telegram plugin install failed — retry manually: claude plugin install telegram@claude-plugins-official"
    fi

    # ── Pre-install + verify plugin dependencies ─────────────────────────────
    # The plugin's start script is `bun install && bun server.ts`, so its deps
    # are normally installed lazily by the FIRST MCP spawn. That is a fragile
    # window: the installer restarts claudebot several times (auth, optional
    # setups), and a restart landing mid-`bun install` corrupts bun's global
    # cache — after which every later spawn faithfully reproduces the same
    # broken node_modules from that cache and the telegram MCP fails to
    # connect on every session, with the error swallowed by Claude Code (seen
    # in the field as "Cannot find module
    # '@modelcontextprotocol/sdk/server/index.js'" while the file existed).
    # Install the deps NOW so the first real spawn is a no-op install, verify
    # them for real, and on failure clear bun's cache and retry once.
    #
    # Verification boots server.ts with no token and a scratch HOME: reaching
    # its "TELEGRAM_BOT_TOKEN required" check proves every import resolved
    # (a broken install prints a module error instead), and without a token
    # it exits immediately — it can never start polling Telegram.
    _tg_verify_plugin_deps() {
        local dir="$1" bun_bin scratch
        bun_bin=$(command -v bun 2>/dev/null) || bun_bin="$HOME/.bun/bin/bun"
        [[ -x "$bun_bin" ]] || return 1
        # Guarded: an empty $scratch must not reach HOME= or rm -rf below
        scratch=$(mktemp -d) || return 1
        local ok=1
        # bun exits non-zero here BY DESIGN (missing token) — install.sh runs
        # under `set -o pipefail`, which would fail the pipeline even when
        # grep matches, so neutralise bun's status
        if (cd "$dir" && { env -u TELEGRAM_BOT_TOKEN HOME="$scratch" \
                timeout 30 "$bun_bin" server.ts 2>&1 || true; } \
                | grep -q "TELEGRAM_BOT_TOKEN required"); then
            ok=0
        fi
        rm -rf "$scratch" 2>/dev/null || true
        return $ok
    }

    _tg_preinstall_plugin_deps() {
        local dir="$1" bun_bin
        bun_bin=$(command -v bun 2>/dev/null) || bun_bin="$HOME/.bun/bin/bun"
        [[ -x "$bun_bin" ]] || return 1
        (cd "$dir" && timeout 180 "$bun_bin" install --no-summary >/dev/null 2>&1) || true
        _tg_verify_plugin_deps "$dir" && return 0
        # Broken state usually lives in bun's global cache — clear it and
        # force a fresh install from the network
        rm -rf "$dir/node_modules" "$HOME/.bun/install/cache" 2>/dev/null || true
        (cd "$dir" && timeout 180 "$bun_bin" install --force --no-summary >/dev/null 2>&1) || true
        _tg_verify_plugin_deps "$dir"
    }

    local tg_cache_dir
    # `|| true`: under install.sh's set -e/pipefail an empty glob (plugin
    # install failed above) would otherwise abort the installer here.
    # -t (newest first): if an upgrade left multiple version dirs cached,
    # verify the freshly installed one, not the lexically-first leftover.
    tg_cache_dir=$(ls -dt "$HOME/.claude/plugins/cache/claude-plugins-official/telegram"/*/ 2>/dev/null | head -1 || true)
    if [[ -n "$tg_cache_dir" && -f "${tg_cache_dir%/}/server.ts" ]]; then
        ui_info "Verifying Telegram plugin dependencies..."
        if _tg_preinstall_plugin_deps "${tg_cache_dir%/}"; then
            ui_ok "Telegram plugin dependencies verified."
        else
            ui_warn "Telegram plugin dependencies broken — the telegram MCP may fail to connect. Manual fix: cd ${tg_cache_dir%/} && rm -rf node_modules ~/.bun/install/cache && bun install --force"
        fi
    fi

    # ── Install webhook channel MCP server ────────────────────────────────────
    _install_webhook_channel() {
        local plugin_src="$CLAUDE_HOME/core/webhook-channel"

        ui_info "Installing webhook channel MCP server..."

        # Install dependencies in-place
        (cd "$plugin_src" && npm install --production >/dev/null 2>&1) || true

        # Register in project .mcp.json so --channels server:webhook-channel works
        python3 -c "
import json
path = '$CLAUDE_HOME/.mcp.json'
try:
    data = json.load(open(path))
except:
    data = {'mcpServers': {}}
if 'mcpServers' not in data:
    data['mcpServers'] = {}
data['mcpServers']['webhook-channel'] = {
    'command': 'node',
    'args': ['\${CLAUDE_HOME}/core/webhook-channel/server.js'],
    'env': {'CLAUDE_HOME': '\${CLAUDE_HOME}'}
}
json.dump(data, open(path, 'w'), indent=2)
"
        return 0
    }

    if _install_webhook_channel; then
        ui_ok "Webhook channel MCP server installed."
    else
        ui_warn "Webhook channel MCP server install failed."
    fi

    # ── Pre-configure Telegram channel to skip pairing prompt ───────────────
    # The plugin reads access.json on every message — keeping allowFrom in
    # sync with TELEGRAM_CHAT_ID means no manual /telegram:access pair step.
    # tg_sync_plugin_config (utils.sh) always updates the plugin's token and
    # replaces allowFrom with the current chat ID, so a reinstall that
    # re-pairs to a different Telegram account or bot takes effect (and
    # revokes the old account) instead of being skipped because the files
    # already exist.
    tg_sync_plugin_config
    ui_ok "Telegram access pre-configured (pairing prompt will be skipped)"

    # ── Add shell shortcuts to ~/.bashrc ─────────────────────────────────────
    config_shell_shortcuts

    ui_ok "Config files ready."
}

# config_shell_shortcuts
# Writes convenience aliases to ~/.bashrc — always rewrites the block so
# updates to alias definitions are applied on re-runs of the installer.
config_shell_shortcuts() {
    # Skip in container mode — .bashrc is on read-only filesystem
    if [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]; then
        return 0
    fi

    local marker="# ${APP_SLUG:-taskramen} shortcuts"
    local bashrc="$HOME/.bashrc"

    # Remove any existing block (from marker line to next blank line after it)
    if grep -qF "$marker" "$bashrc" 2>/dev/null; then
        # Delete from marker line through the alias lines that follow it
        sed -i "/^${marker}/,/^alias claudebot/d" "$bashrc"
    fi

    cat >> "$bashrc" <<EOF

$marker
alias claudebot='TMUX_TMPDIR=/tmp tmux -L claudebot attach -t claudebot'
EOF
    ui_ok "Updated 'claudebot' alias in ~/.bashrc"
}

# DEPRECATED — DO NOT CALL. The Google Workspace MCP has been removed; this
# function (which registered the google-workspace MCP server in .mcp.json) is no
# longer used. Google is now connected via the vendored
# claudeconnectorskillheadless flow with credentials in .env (SERVICE_GOOGLE_WORKSPACE_RW_*)
# and direct REST calls. Kept for reference only — see CLAUDE.md "Connecting Services".
# config_add_google <client_id> <client_secret> <user_google_email>
# Writes Google credentials to .env and regenerates .mcp.json
config_add_google() {
    local client_id="$1"
    local client_secret="$2"
    local user_email="$3"

    write_env "GOOGLE_OAUTH_CLIENT_ID"     "$client_id"
    write_env "GOOGLE_OAUTH_CLIENT_SECRET" "$client_secret"
    write_env "USER_GOOGLE_EMAIL"          "$user_email"

    # Merge google-workspace into existing .mcp.json (preserves other MCP entries)
    GOOGLE_CLIENT_SECRET="$client_secret" python3 -c '
import json, sys, os

mcp_path = sys.argv[1]
client_id, user_email = sys.argv[2], sys.argv[3]
client_secret = os.environ["GOOGLE_CLIENT_SECRET"]

try:
    with open(mcp_path, "r") as f:
        data = json.load(f)
except (json.JSONDecodeError, FileNotFoundError, OSError):
    data = {}

data.setdefault("mcpServers", {})["google-workspace"] = {
    "command": "uvx",
    "args": ["--with", "pytz", "workspace-mcp", "--tool-tier", "core"],
    "env": {
        "GOOGLE_OAUTH_CLIENT_ID": client_id,
        "GOOGLE_OAUTH_CLIENT_SECRET": client_secret,
        "OAUTHLIB_INSECURE_TRANSPORT": "1",
        "USER_GOOGLE_EMAIL": user_email
    }
}

with open(mcp_path, "w") as f:
    json.dump(data, f, indent=2)
' "$CLAUDE_HOME/.mcp.json" "$client_id" "$user_email"
    chmod 600 "$CLAUDE_HOME/.mcp.json"
    ui_ok "Google credentials saved to .mcp.json"
}
