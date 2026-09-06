#!/bin/bash

# TaskRamen.ai
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jobs Jolt Private Limited (TaskRamen.ai)

# install/ui.sh — Terminal UI helpers: colors, boxes, spinners, progress bars, step counter

# ── Colors ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_DIM='\033[2m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_CYAN='\033[0;36m'
    C_RED='\033[0;31m'
    C_WHITE='\033[0;37m'
    C_BRIGHT_WHITE='\033[1;37m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_GREEN='' C_YELLOW=''
    C_BLUE='' C_CYAN='' C_RED='' C_WHITE='' C_BRIGHT_WHITE=''
fi

WIDTH=64   # inner width of the box (between ║ characters)

# ── Box drawing ───────────────────────────────────────────────────────────────

ui_banner() {
    local title="$1"
    local subtitle="$2"
    echo
    printf "${C_CYAN}╔%s╗${C_RESET}\n" "$(printf '═%.0s' $(seq 1 $WIDTH))"
    # Center the title
    local pad=$(( (WIDTH - ${#title}) / 2 ))
    printf "${C_CYAN}║${C_RESET}${C_BOLD}%*s%s%*s${C_RESET}${C_CYAN}║${C_RESET}\n" \
        $pad "" "$title" $(( WIDTH - pad - ${#title} )) ""
    if [[ -n "$subtitle" ]]; then
        local spad=$(( (WIDTH - ${#subtitle}) / 2 ))
        printf "${C_CYAN}║${C_RESET}${C_DIM}%*s%s%*s${C_RESET}${C_CYAN}║${C_RESET}\n" \
            $spad "" "$subtitle" $(( WIDTH - spad - ${#subtitle} )) ""
    fi
    printf "${C_CYAN}╚%s╝${C_RESET}\n" "$(printf '═%.0s' $(seq 1 $WIDTH))"
    echo
}

ui_divider() {
    local label="$1"
    if [[ -n "$label" ]]; then
        printf "${C_DIM}━━  %s  %s${C_RESET}\n" "$label" \
            "$(printf '━%.0s' $(seq 1 $(( WIDTH - 6 - ${#label} )) ))"
    else
        printf "${C_DIM}%s${C_RESET}\n" "$(printf '━%.0s' $(seq 1 $((WIDTH + 2)) ))"
    fi
    echo
}

# ui_step <current> <total> <label>
ui_step() {
    local current="$1"
    local total="$2"
    local label="$3"
    echo
    ui_divider "Step $current of $total  ·  $label"
}

# ── Messages ──────────────────────────────────────────────────────────────────

ui_info() {
    printf "  ${C_WHITE}%s${C_RESET}\n" "$1"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*" >> "$LOG_FILE"
}

ui_ok() {
    printf "  ${C_GREEN}✓${C_RESET}  %s\n" "$1"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $*" >> "$LOG_FILE"
}

ui_warn() {
    printf "  ${C_YELLOW}⚠${C_RESET}  %s\n" "$1"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >> "$LOG_FILE"
}

ui_error() {
    printf "  ${C_RED}✗${C_RESET}  %s\n" "$1"
    [[ -n "${LOG_FILE:-}" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >> "$LOG_FILE"
}

ui_bullet() {
    printf "    ${C_DIM}◦${C_RESET}  %s\n" "$1"
}

ui_blank() {
    echo
}

# ── Progress bar ──────────────────────────────────────────────────────────────
# Usage: ui_progress_bar <label> <status>
# status: "running" | "done" | "skip"
# Call with "running" first (overwrites in place), then "done"/"skip" to finalise.

_PROGRESS_LINE=0

ui_progress_bar() {
    local label="$1"
    local status="$2"
    local bar_width=20
    local filled="$(printf '█%.0s' $(seq 1 $bar_width))"

    case "$status" in
        running)
            printf "  %-30s ${C_DIM}%s${C_RESET}  working...\n" "$label" "$filled"
            _PROGRESS_LINE=1
            ;;
        done)
            if [[ $_PROGRESS_LINE -eq 1 ]]; then
                # Move cursor up one line and overwrite
                printf '\033[1A\033[2K'
            fi
            printf "  %-30s ${C_GREEN}%s${C_RESET}  ${C_GREEN}done ✓${C_RESET}\n" "$label" "$filled"
            _PROGRESS_LINE=0
            ;;
        skip)
            if [[ $_PROGRESS_LINE -eq 1 ]]; then
                printf '\033[1A\033[2K'
            fi
            printf "  %-30s ${C_DIM}%s${C_RESET}  ${C_DIM}skipped${C_RESET}\n" "$label" "$filled"
            _PROGRESS_LINE=0
            ;;
        fail)
            if [[ $_PROGRESS_LINE -eq 1 ]]; then
                printf '\033[1A\033[2K'
            fi
            printf "  %-30s ${C_RED}%s${C_RESET}  ${C_RED}failed ✗${C_RESET}\n" "$label" "$filled"
            _PROGRESS_LINE=0
            ;;
    esac
}

# ── Spinner ───────────────────────────────────────────────────────────────────
# Usage:
#   ui_spinner_start "Waiting for your message"
#   ... (blocking work in same shell, or poll loop calling ui_spinner_tick)
#   ui_spinner_stop

_SPINNER_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPINNER_IDX=0
_SPINNER_LABEL=""

ui_spinner_tick() {
    local frame="${_SPINNER_FRAMES[$_SPINNER_IDX]}"
    printf "\r  ${C_CYAN}%s${C_RESET}  %s  " "$frame" "$_SPINNER_LABEL"
    _SPINNER_IDX=$(( (_SPINNER_IDX + 1) % ${#_SPINNER_FRAMES[@]} ))
}

ui_spinner_start() {
    _SPINNER_LABEL="$1"
    _SPINNER_IDX=0
    ui_spinner_tick
}

ui_spinner_stop() {
    printf '\r\033[2K'   # clear the spinner line
}

# ui_run_with_spinner <label> <command...>
# Runs <command> in the background, showing an animated spinner until it finishes.
# Logs command output to LOG_FILE. Returns the command's exit code.
ui_run_with_spinner() {
    local label="$1"
    shift
    local log_target="${LOG_FILE:-/dev/null}"

    # Run the command in background, output goes to log
    "$@" >>"$log_target" 2>&1 &
    local pid=$!

    # Animate spinner until command finishes
    _SPINNER_LABEL="$label"
    _SPINNER_IDX=0
    while kill -0 "$pid" 2>/dev/null; do
        ui_spinner_tick
        sleep 0.12
    done

    # Get exit code
    wait "$pid"
    local exit_code=$?
    ui_spinner_stop
    return "$exit_code"
}

# ── Prompt ────────────────────────────────────────────────────────────────────
# ui_prompt <variable_name> <prompt_text>
# Reads input into the named variable. Input is echoed (visible) as per plan.
ui_prompt() {
    local varname="$1"
    local prompt_text="$2"
    printf "\n  ${C_BRIGHT_WHITE}%s${C_RESET}  " "$prompt_text"
    read -r "$varname"
}

# ui_prompt_secret <variable_name> <prompt_text>
# Same but with hidden input (for passwords)
ui_prompt_secret() {
    local varname="$1"
    local prompt_text="$2"
    printf "\n  ${C_BRIGHT_WHITE}%s${C_RESET}  " "$prompt_text"
    read -rs "$varname"
    echo
}
