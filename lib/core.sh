#!/usr/bin/env bash
# lib/core.sh — logging, versioning, dependency checks, root validation
# Part of: arch-system-recovery
set -euo pipefail

# ── Version ───────────────────────────────────────────────────────────────────
[[ -v TOOLKIT_VERSION ]] || readonly TOOLKIT_VERSION="1.1.0"

# ── Log file ──────────────────────────────────────────────────────────────────
[[ -v LOG_FILE ]]    || readonly LOG_FILE="/tmp/recovery-toolkit.log"

# ── Mount root ────────────────────────────────────────────────────────────────
[[ -v MOUNT_ROOT ]]  || readonly MOUNT_ROOT="/mnt/recovery"

# ── Log level (may be overridden by entry point before sourcing) ──────────────
# Levels: silent | normal | verbose | debug
LOG_LEVEL="${LOG_LEVEL:-normal}"

# ── Required tools ────────────────────────────────────────────────────────────
[[ -v REQUIRED_DEPS ]] || readonly REQUIRED_DEPS=(
    blkid lsblk mount umount findmnt arch-chroot mkinitcpio
)

# ── Colour helpers ────────────────────────────────────────────────────────────
# All output functions use stderr so command substitution captures return values
_tty() { [[ -t 2 ]]; }
_c_bold()  { _tty && printf '\033[1m'    >&2 || true; }
_c_reset() { _tty && printf '\033[0m'    >&2 || true; }
_c_red()   { _tty && printf '\033[0;31m' >&2 || true; }
_c_green() { _tty && printf '\033[0;32m' >&2 || true; }
_c_yellow(){ _tty && printf '\033[0;33m' >&2 || true; }
_c_cyan()  { _tty && printf '\033[0;36m' >&2 || true; }
_c_blue()  { _tty && printf '\033[0;34m' >&2 || true; }

# ── Logging ───────────────────────────────────────────────────────────────────
# All log functions write to stderr (keeps stdout clean for return values)
# and to LOG_FILE.

_ts() { date '+%H:%M:%S'; }

# log — normal informational message (suppressed in silent mode)
log() {
    local msg
    msg="[$(_ts)] $*"
    echo "${msg}" >> "${LOG_FILE}"
    [[ "${LOG_LEVEL}" != "silent" ]] && echo "${msg}" >&2 || true
}

# vlog — verbose message (only shown in verbose/debug)
vlog() {
    local msg
    msg="[$(_ts)] [verbose] $*"
    echo "${msg}" >> "${LOG_FILE}"
    [[ "${LOG_LEVEL}" == "verbose" || "${LOG_LEVEL}" == "debug" ]] \
        && echo "${msg}" >&2 || true
}

# dlog — debug message (only shown in debug)
dlog() {
    local msg
    msg="[$(_ts)] [debug] $*"
    echo "${msg}" >> "${LOG_FILE}"
    [[ "${LOG_LEVEL}" == "debug" ]] && echo "${msg}" >&2 || true
}

# err — error message (always shown, even in silent)
err() {
    local msg
    msg="[$(_ts)] ERROR: $*"
    echo "${msg}" >> "${LOG_FILE}"
    _c_red; _c_bold
    echo "${msg}" >&2
    _c_reset
}

# warn — warning (suppressed in silent)
warn() {
    local msg
    msg="[$(_ts)] WARN: $*"
    echo "${msg}" >> "${LOG_FILE}"
    if [[ "${LOG_LEVEL}" != "silent" ]]; then
        _c_yellow; echo "${msg}" >&2; _c_reset
    fi
}

# die — fatal: log, print, exit 1
die() {
    err "$*"
    echo "" >&2
    echo "  ✗ Fatal error. See full log: ${LOG_FILE}" >&2
    exit 1
}

# ── init_log ──────────────────────────────────────────────────────────────────
init_log() {
    mkdir -p "$(dirname "${LOG_FILE}")"
    {
        echo "════════════════════════════════════════════════════"
        echo " arch-recovery ${TOOLKIT_VERSION} — $(date '+%Y-%m-%d %H:%M:%S')"
        echo " PID: $$  PPID: ${PPID}"
        echo " Shell: ${SHELL:-unknown}  Bash: ${BASH_VERSION}"
        echo " User: $(id -un 2>/dev/null || echo unknown)"
        echo " Kernel: $(uname -r 2>/dev/null || echo unknown)"
        echo "════════════════════════════════════════════════════"
    } > "${LOG_FILE}"
}

# ── check_root ────────────────────────────────────────────────────────────────
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "Must run as root.

  Try one of:
    sudo arch-recovery
    sudo bash bin/arch-recovery
    su -c 'bash bin/arch-recovery'"
    fi
    log "Running as root (EUID=${EUID})"
}

# ── check_deps ────────────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for dep in "${REQUIRED_DEPS[@]}"; do
        command -v "${dep}" &>/dev/null || missing+=("${dep}")
    done

    # At least one bootloader tool required
    if ! command -v grub-install &>/dev/null && ! command -v bootctl &>/dev/null; then
        missing+=("grub-install OR bootctl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing required tools: ${missing[*]}"
        echo "" >&2
        echo "  On Arch live ISO these are all pre-installed." >&2
        echo "  To install manually:" >&2
        echo "    pacman -S arch-install-scripts grub efibootmgr" >&2
        die "Install missing tools before running arch-recovery."
    fi
    vlog "All required tools found."
}

# ── run_cmd ───────────────────────────────────────────────────────────────────
# Wraps command execution. Logs the command. Respects DRY_RUN.
# In debug mode, streams stdout/stderr to terminal as well.
run_cmd() {
    dlog "CMD: $*"
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        log "  [dry-run] $*"
        return 0
    fi
    if [[ "${LOG_LEVEL}" == "debug" ]]; then
        "$@" 2>&1 | tee -a "${LOG_FILE}" >&2 \
            || die "Command failed: $*"
    else
        "$@" >> "${LOG_FILE}" 2>&1 \
            || die "Command failed: $*"
    fi
}

# ── spinner ───────────────────────────────────────────────────────────────────
# Show an animated spinner while a background job is running.
# Usage: spin_while <pid>
spin_while() {
    local pid="${1}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    _tty || { wait "${pid}"; return $?; }
    while kill -0 "${pid}" 2>/dev/null; do
        local c="${spin:$(( i % ${#spin} )):1}"
        printf "  %s\r" "${c}" >&2
        sleep 0.1
        (( i++ )) || true
    done
    printf "    \r" >&2
    wait "${pid}"
}
