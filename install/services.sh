#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/services.sh — Enable and start system-level systemd services, health check
# Services must already be registered by deps.sh (which runs the sudo cp + daemon-reload).
# In container mode (/.dockerenv or CONTAINER=true), systemd is not used — entrypoint.sh
# manages all processes directly.

CORE_SERVICES=(claudebot.service claudemonitor.service stealth-chrome.service)
OPTIONAL_SERVICES=(claude-router.service openrouter-bridge.service)

# Helper: detect container mode
_is_container_mode() {
    [[ -f /.dockerenv || "${CONTAINER:-}" == "true" ]]
}

# services_enable_start
# Enables and starts the three core services. Uses sudo (credentials cached from Phase 1).
# In container mode, this is a no-op — entrypoint.sh handles process management.
services_enable_start() {
    if _is_container_mode; then
        ui_progress_bar "Starting your assistant" "done"
        ui_info "Container mode: services managed by entrypoint.sh"
        _schedule_nightly_review || true
        _schedule_daily_tip || true
        _schedule_tz_resync || true
        ui_blank
        return 0
    fi

    ui_progress_bar "Starting your assistant" "running"
    for svc in "${CORE_SERVICES[@]}"; do
        sudo systemctl enable --now "$svc" >> "${LOG_FILE:-/dev/null}" 2>&1 || true
    done
    _schedule_nightly_review || true
    _schedule_daily_tip || true
    _schedule_tz_resync || true
    ui_progress_bar "Starting your assistant" "done"
    ui_blank
}

# services_health_check
# Checks that all core services are active. Returns 0 if all OK, 1 otherwise.
# In container mode, checks processes directly instead of systemd.
services_health_check() {
    if _is_container_mode; then
        local all_ok=true
        local failed=""
        # Check claudebot (tmux session)
        if ! tmux -L claudebot has-session -t claudebot 2>/dev/null; then
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] claudebot tmux session is not running" >> "$LOG_FILE"
            failed="${failed} claudebot"
            all_ok=false
        fi
        # Check chromium
        if ! pgrep -f "chromium" >/dev/null 2>&1; then
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] chromium is not running" >> "$LOG_FILE"
            failed="${failed} chromium"
            all_ok=false
        fi
        # Check monitor
        if ! pgrep -f "monitor.sh" >/dev/null 2>&1; then
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] monitor.sh is not running" >> "$LOG_FILE"
            failed="${failed} monitor"
            all_ok=false
        fi
        if [[ "$all_ok" == "true" ]]; then
            return 0
        fi
        ui_warn "Services not running:${failed}"
        return 1
    fi

    local all_ok=true
    for svc in "${CORE_SERVICES[@]}"; do
        if ! sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $svc is not running" >> "$LOG_FILE"
            all_ok=false
        fi
    done

    if [[ "$all_ok" == "true" ]]; then
        return 0
    fi
    ui_warn "Some services failed to start — the assistant may not work correctly"
    return 1
}

# _schedule_nightly_review
# Schedules core/nightly-review.sh to run at 3am USER-local time daily by
# delegating to core/schedule.sh with --no-inject, so cron/supercronic invokes
# the script DIRECTLY (not via inject.sh — nightly-review.sh is a maintenance
# script, not a prompt: it restarts the session + Chrome, then injects the
# review into the live session itself via core/inject.sh).
# schedule.sh (via core/tz-lib.sh) converts the 3am user-local time into the
# scheduler frame, writes the container/VM crontab, and tags the entry for DST
# resync — so this function just passes the wall-clock schedule through and no
# longer does its own timezone math. Idempotency is the caller's job: we skip
# scheduling if nightly-review.sh is already in the crontab.
_schedule_nightly_review() {
    # Idempotent: skip if nightly-review.sh is already scheduled.
    if _is_container_mode; then
        if grep -qF "nightly-review.sh" "$CLAUDE_HOME/.crontab" 2>/dev/null; then
            return 0
        fi
    else
        if crontab -l 2>/dev/null | grep -qF "nightly-review.sh"; then
            return 0
        fi
    fi

    # 3am user-local — schedule.sh converts to the scheduler frame and tags for
    # DST resync.
    # --no-inject: nightly-review.sh is a maintenance script (it restarts the
    # session + Chrome and injects the review into the live session itself), so
    # cron must invoke it directly, not deliver it as a prompt through inject.sh.
    # Pass CONTAINER through so schedule.sh picks the right crontab backend even
    # if it was only detected via /.dockerenv (it keys off $CONTAINER).
    if _is_container_mode; then
        CONTAINER=true "$CLAUDE_HOME/core/schedule.sh" --no-inject '0 3 * * *' "$CLAUDE_HOME/core/nightly-review.sh" >> "${LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        "$CLAUDE_HOME/core/schedule.sh" --no-inject '0 3 * * *' "$CLAUDE_HOME/core/nightly-review.sh" >> "${LOG_FILE:-/dev/null}" 2>&1 || return 1
    fi

    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Nightly review scheduled: 3am user-local" >> "$LOG_FILE"
}

# _schedule_daily_tip
# Schedules a daily "send the user a tip" task at 8am user-local. Unlike the
# nightly review (--no-inject, runs outside Claude), this one must go THROUGH
# Claude: schedule.sh's DEFAULT mode wraps the prompt as
# `core/inject.sh '<prompt>' --no-telegram`, so at fire time inject.sh hands
# Claude a [SYSTEM CRON TRIGGER] with a self-contained instruction to read
# tips.md and send one random tip (tips.md itself tells Claude how to pick and
# which connect-tips to skip — no CLAUDE.md handler needed). --no-telegram
# (added by schedule.sh) keeps inject.sh's own "Scheduled Task Fired" notice off
# the user's chat. Same zone handling and #RECUR_ tagging (delete-task.sh-
# managed) as the nightly review.
_schedule_daily_tip() {
    # The prompt embeds the absolute tips.md path so Claude has no ambiguity at
    # fire time. "tips.md" in the resulting cron line doubles as the idempotency
    # marker so re-running the installer never double-schedules.
    local tip_prompt="Refer to $CLAUDE_HOME/docs/tips.md and send the user one random tip by Telegram."

    # Migration: tips.md moved from the repo root to docs/. An install that
    # scheduled the tip before the move has a stored entry embedding the old
    # absolute path — and because the idempotency grep below matches on the
    # bare "tips.md", that stale entry would suppress rescheduling forever,
    # leaving a daily task pointing at a file that no longer exists. Rewrite
    # the path in place (the old path is not a substring of the new one, so
    # this cannot double-apply).
    local old_tip_path="$CLAUDE_HOME/tips.md"
    if _is_container_mode; then
        if grep -qF "$old_tip_path" "$CLAUDE_HOME/.crontab" 2>/dev/null; then
            # Same idiom as delete-task.sh: flock + truncate-write ("cat tmp >
            # file", never sed -i or mv — supercronic watches the file by
            # inode), then nudge supercronic to reload.
            local ctf="$CLAUDE_HOME/.crontab"
            flock "$ctf.lock" sh -c "sed 's|$old_tip_path|$CLAUDE_HOME/docs/tips.md|g' '$ctf' > '$ctf.tmp'; cat '$ctf.tmp' > '$ctf'; rm -f '$ctf.tmp'" || true
            kill -USR2 $(pgrep supercronic) 2>/dev/null || true
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Daily tip entry migrated to docs/tips.md" >> "$LOG_FILE"
        fi
    else
        if crontab -l 2>/dev/null | grep -qF "$old_tip_path"; then
            crontab -l 2>/dev/null | sed "s|$old_tip_path|$CLAUDE_HOME/docs/tips.md|g" | crontab -
            [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Daily tip entry migrated to docs/tips.md" >> "$LOG_FILE"
        fi
    fi

    if _is_container_mode; then
        if grep -qF "tips.md" "$CLAUDE_HOME/.crontab" 2>/dev/null; then
            return 0
        fi
    else
        if crontab -l 2>/dev/null | grep -qF "tips.md"; then
            return 0
        fi
    fi

    # 8am user-local — schedule.sh (via tz-lib) converts to the scheduler frame
    # and tags the entry for DST resync.
    # No --no-inject: route through inject.sh so Claude composes the tip.
    if _is_container_mode; then
        CONTAINER=true "$CLAUDE_HOME/core/schedule.sh" '0 8 * * *' "$tip_prompt" >> "${LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        "$CLAUDE_HOME/core/schedule.sh" '0 8 * * *' "$tip_prompt" >> "${LOG_FILE:-/dev/null}" 2>&1 || return 1
    fi

    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Daily tip scheduled: 8am user-local" >> "$LOG_FILE"
}

# _schedule_tz_resync
# Schedules core/tz-resync.sh to run daily. It re-derives the SYSTEM_TIMEZONE
# fields of every UF=-tagged recurring entry from its intent tag, so a DST
# transition in the user's zone can only leave a task an hour off for at most a
# day. Scheduled with --no-inject (it's a maintenance script, not a prompt) and
# --system-tz at a fixed scheduler-frame hour, so the resync job itself carries
# no intent tag and never resyncs itself. Idempotent: skip if already present.
_schedule_tz_resync() {
    if _is_container_mode; then
        if grep -qF "tz-resync.sh" "$CLAUDE_HOME/.crontab" 2>/dev/null; then
            return 0
        fi
    else
        if crontab -l 2>/dev/null | grep -qF "tz-resync.sh"; then
            return 0
        fi
    fi

    # 04:07 in the scheduler frame, daily — an off-peak time, after the common
    # 02:00/03:00-local DST transition instants have passed.
    if _is_container_mode; then
        CONTAINER=true "$CLAUDE_HOME/core/schedule.sh" --no-inject --system-tz '7 4 * * *' "$CLAUDE_HOME/core/tz-resync.sh" >> "${LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        "$CLAUDE_HOME/core/schedule.sh" --no-inject --system-tz '7 4 * * *' "$CLAUDE_HOME/core/tz-resync.sh" >> "${LOG_FILE:-/dev/null}" 2>&1 || return 1
    fi

    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Timezone resync scheduled: 04:07 scheduler-frame daily" >> "$LOG_FILE"
}

# services_restart_claudebot
# Restarts only the claudebot service (used after config changes).
# In container mode, kills and restarts the tmux session directly.
services_restart_claudebot() {
    if _is_container_mode; then
        tmux -L claudebot kill-session -t claudebot 2>/dev/null || true
        sleep 2
        local _log="${CLAUDEBOT_LOG:-/tmp/claudebot.log}"
        tmux -L claudebot new-session -d -s claudebot "$CLAUDE_HOME/core/run.sh 2>&1 | tee -a $_log"
        sleep 5
        return
    fi

    sudo systemctl restart claudebot.service >/dev/null 2>&1
    sleep 5   # give tmux session time to start
}

# services_status
# Prints a human-readable status of all core services.
# In container mode, checks processes directly.
services_status() {
    if _is_container_mode; then
        # claudebot
        if tmux -L claudebot has-session -t claudebot 2>/dev/null; then
            ui_ok "claudebot  (active)"
        else
            ui_warn "claudebot  (inactive)"
        fi
        # chromium
        if pgrep -f "chromium" >/dev/null 2>&1; then
            ui_ok "chromium  (active)"
        else
            ui_warn "chromium  (inactive)"
        fi
        # monitor
        if pgrep -f "monitor.sh" >/dev/null 2>&1; then
            ui_ok "monitor  (active)"
        else
            ui_warn "monitor  (inactive)"
        fi
        return
    fi

    for svc in "${CORE_SERVICES[@]}"; do
        local state
        state=$(sudo systemctl is-active "$svc" 2>/dev/null || echo "unknown")
        if [[ "$state" == "active" ]]; then
            ui_ok "$svc  ($state)"
        else
            ui_warn "$svc  ($state)"
        fi
    done
}
