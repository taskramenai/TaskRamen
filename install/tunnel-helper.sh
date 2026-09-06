#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/tunnel-helper.sh — Shared cloudflared quick tunnel start/stop functions
# Sources: install/utils.sh (for source_env)

# _quick_tunnel_log_failure <attempt> <cf_pid> <log_file>
# Appends a diagnostic block to $LOG_FILE (install.log) so we can see why
# a tunnel attempt failed after the fact. No-op if LOG_FILE is unset.
_quick_tunnel_log_failure() {
    local attempt="$1" cf_pid="$2" log_file="$3"
    [[ -z "${LOG_FILE:-}" ]] && return 0

    local proc_state="alive"
    kill -0 "$cf_pid" 2>/dev/null || proc_state="exited"

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] cloudflared quick tunnel attempt $attempt failed (process $proc_state, url=${PUBLIC_URL:-<not advertised>})"
        echo "--- cloudflared log tail (last 20 lines) ---"
        tail -n 20 "$log_file" 2>/dev/null || echo "(log file unreadable)"
        echo "--- end ---"
    } >> "$LOG_FILE"
}

# _quick_tunnel_attempt <cf_bin> <port> <pid_file> <log_file>
# Starts cloudflared, waits for the URL to appear, then probes (informational)
# until the Cloudflare edge actually routes to the local backend. Sets
# PUBLIC_URL (the advertised URL) and TUNNEL_PROBE_OK ("true" if the edge
# served a 200 within the probe budget, "false" otherwise) on success.
# Returns 0 if a URL was advertised and cloudflared is still alive, 1 on
# hard failure (no URL, or cloudflared died). Leaves the cloudflared
# process running on success; on failure the caller is responsible for
# killing it (we still hold its PID in pid_file).
_quick_tunnel_attempt() {
    local cf_bin="$1" port="$2" pid_file="$3" log_file="$4"

    rm -f "$log_file"
    timeout 600 "$cf_bin" tunnel --url "http://localhost:${port}" --no-autoupdate 2>"$log_file" &
    local cf_pid=$!
    echo "$cf_pid" > "$pid_file"

    # Wait up to 30s for the URL to appear in cloudflared's stderr.
    # `kill -0 $cf_pid` fails fast if cloudflared exited (DNS handshake
    # failure, edge handshake failure, etc.) instead of probing a log
    # that will never grow.
    PUBLIC_URL=""
    for _i in $(seq 1 30); do
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            return 1
        fi
        PUBLIC_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$log_file" 2>/dev/null | head -1)
        [[ -n "$PUBLIC_URL" ]] && break
        sleep 1
    done
    [[ -z "$PUBLIC_URL" ]] && return 1

    # Routing probe -- INFORMATIONAL, not gating. cloudflared prints the
    # public URL to its log a few seconds before its edge fleet starts
    # routing requests through it; a user who scans the QR in that
    # window sees "This site can't be reached" / "Error 1033" until
    # propagation finishes (typically 5-15s).
    #
    # PR #284 originally gated tunnel success on this probe -- if the
    # probe never got 200, _quick_tunnel_attempt failed and telegram.sh
    # silently skipped the entire QR-display block (no QR, no URL, just
    # the manual-paste fallback). That hides a working URL whenever
    # propagation runs slow, container egress is constrained, or the
    # 2-second curl timeout clips a successful response. Strictly
    # worse than showing the QR with a retry hint.
    #
    # Now: the probe sets TUNNEL_PROBE_OK so callers can render a
    # one-line "wait 5-15s and retry if first scan fails" hint above
    # the QR. A failed probe (no 200 within ~45s) does NOT fail the
    # attempt -- as long as cloudflared is still alive and the URL
    # was advertised, return success. cloudflared dying mid-probe
    # still fails (dead client = URL will never route).
    TUNNEL_PROBE_OK=false
    for _i in $(seq 1 15); do
        if ! kill -0 "$cf_pid" 2>/dev/null; then
            return 1
        fi
        if curl -sf -o /dev/null --max-time 2 "$PUBLIC_URL"; then
            TUNNEL_PROBE_OK=true
            return 0
        fi
        sleep 1
    done

    # Final liveness check before declaring soft success. The probe loop
    # checks kill -0 at the TOP of each iteration, so cloudflared dying
    # during the last `sleep 1` would otherwise slip past as a soft
    # success with a dead client (URL guaranteed not to route). Caught
    # by gemini-code-assist on PR #297.
    kill -0 "$cf_pid" 2>/dev/null || return 1
    return 0
}

# start_quick_tunnel <local_port> <pid_file> <log_file>
# Starts a cloudflared quick tunnel pointing to localhost:<port>.
# Sets PUBLIC_URL on success; also sets TUNNEL_PROBE_OK ("true"/"false")
# so callers can render a propagation-retry hint above the QR. Returns
# 1 only on hard failure (no URL advertised, or cloudflared died).
#
# Tries up to twice — when cloudflared dies during URL-wait or never
# advertises a URL, killing and reconnecting often lands on a healthy
# edge. Each attempt is bounded at ~75s (30s URL-wait + up to 45s of
# informational routing-probe), so worst-case wall time is ~150s. In
# practice the retry only fires on hard failures: a "URL advertised
# but probe didn't confirm routing" outcome returns success on the
# first attempt and lets the user retry the scan themselves. Each
# failed attempt dumps cloudflared's log tail into $LOG_FILE for
# postmortem.
start_quick_tunnel() {
    local port="$1"
    local pid_file="$2"
    local log_file="$3"

    # Resolve cloudflared binary
    local cf_bin="${CLOUDFLARED_BIN:-}"
    if [[ -z "$cf_bin" && -f "${CLAUDE_HOME:-.}/.env" ]]; then
        cf_bin=$(grep '^CLOUDFLARED_BIN=' "${CLAUDE_HOME:-.}/.env" 2>/dev/null | head -1 | cut -d= -f2-)
        [[ -n "$cf_bin" ]] && cf_bin="$(eval echo "$cf_bin")"
    fi
    cf_bin="${cf_bin:-cloudflared}"

    if [[ ! -x "$cf_bin" ]] && ! command -v "$cf_bin" >/dev/null 2>&1; then
        return 1
    fi

    # Kill any existing tunnel on this pid file
    [[ -f "$pid_file" ]] && kill "$(cat "$pid_file")" 2>/dev/null || true
    rm -f "$pid_file"

    local max_attempts=2
    local attempt
    for attempt in $(seq 1 $max_attempts); do
        if _quick_tunnel_attempt "$cf_bin" "$port" "$pid_file" "$log_file"; then
            return 0
        fi

        local cf_pid
        cf_pid=$(cat "$pid_file" 2>/dev/null || echo "")
        _quick_tunnel_log_failure "$attempt" "${cf_pid:-0}" "$log_file"

        # Kill this attempt's tunnel before retrying (if it's still up).
        [[ -n "$cf_pid" ]] && kill "$cf_pid" 2>/dev/null || true
        rm -f "$pid_file"
    done

    PUBLIC_URL=""
    return 1
}

# stop_quick_tunnel <pid_file>
# Stops a running cloudflared tunnel and cleans up.
stop_quick_tunnel() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
    fi
}
