#!/usr/bin/env bash
# lib/pacman.sh — pacman keyring initialization and mirrorlist refresh
# Part of: arch-system-recovery
set -euo pipefail

# ── repair_pacman_keyring ─────────────────────────────────────────────────────
# Reinitializes the pacman keyring inside the chroot and refreshes keys.
# This is the standard fix for "invalid or corrupted package (PGP signature)"
# errors that block system updates after a partial upgrade or time drift.
repair_pacman_keyring() {
    log "Repairing pacman keyring..."

    # Ensure bind mounts are up (needed for internet access from chroot)
    mount_bind

    # ── Step 1: Remove and re-initialize the keyring ──────────────────────────
    log "  Removing existing keyring..."
    run_cmd rm -rf "${MOUNT_ROOT}/etc/pacman.d/gnupg"

    log "  Initializing fresh keyring..."
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
        "pacman-key --init" \
        >> "${LOG_FILE}" 2>&1 \
        || die "pacman-key --init failed. See log: ${LOG_FILE}"

    # ── Step 2: Populate with Arch Linux keys ─────────────────────────────────
    log "  Populating Arch Linux keys..."
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
        "pacman-key --populate archlinux" \
        >> "${LOG_FILE}" 2>&1 \
        || die "pacman-key --populate failed. See log: ${LOG_FILE}"

    # ── Step 3: Optionally update keys (needs internet) ───────────────────────
    if _network_available; then
        log "  Refreshing keys from keyserver..."
        arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
            "pacman-key --refresh-keys" \
            >> "${LOG_FILE}" 2>&1 \
            || warn "pacman-key --refresh-keys failed (non-fatal; network may be slow)"
    else
        warn "No network detected — skipping keyserver refresh"
        echo "     Connect first: arch-recovery --setup-network" >&2
    fi

    # ── Step 4: Refresh mirrorlist ────────────────────────────────────────────
    _refresh_mirrorlist

    log "Pacman keyring repair complete."
}

# ── _refresh_mirrorlist ───────────────────────────────────────────────────────
# Writes a fast, geo-located mirrorlist using reflector (if available)
# or falls back to the static Arch bootstrap mirror.
_refresh_mirrorlist() {
    local ml_target="${MOUNT_ROOT}/etc/pacman.d/mirrorlist"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    local ml_backup="${ml_target}.bak.${ts}"
    local staged="${ml_target}.new"

    [[ -f "${ml_target}" ]] && cp "${ml_target}" "${ml_backup}"
    vlog "Mirrorlist backup: ${ml_backup}"

    if ! _network_available; then
        warn "No network — skipping mirrorlist refresh"
        return 0
    fi

    rm -f "${staged}"
    if _write_mirrorlist_file "${staged}" && [[ -s "${staged}" ]]; then
        mv "${staged}" "${ml_target}"
        log "  Mirrorlist updated: ${ml_target}"
    else
        rm -f "${staged}"
        warn "Failed to refresh mirrorlist — keeping existing mirrorlist"
    fi
}

_write_mirrorlist_file() {
    local target="${1:?_write_mirrorlist_file requires a target path}"

    if command -v reflector &>/dev/null; then
        log "  Refreshing mirrorlist with reflector..."
        _write_reflector_mirrorlist "${target}"
    elif command -v curl &>/dev/null; then
        log "  reflector not found — fetching mirrorlist from archlinux.org via curl..."
        _write_curl_mirrorlist "${target}"
    elif command -v wget &>/dev/null; then
        log "  reflector not found — fetching mirrorlist from archlinux.org via wget..."
        _write_wget_mirrorlist "${target}"
    else
        warn "Neither reflector, curl, nor wget available — skipping mirrorlist refresh"
        return 1
    fi
}

_write_reflector_mirrorlist() {
    local target="${1:?_write_reflector_mirrorlist requires a target path}"
    reflector \
        --country "${REFLECTOR_COUNTRY:-}" \
        --latest 20 \
        --sort rate \
        --protocol https \
        --save "${target}" \
        >> "${LOG_FILE}" 2>&1
}

_write_curl_mirrorlist() {
    local target="${1:?_write_curl_mirrorlist requires a target path}"
    curl -s "https://archlinux.org/mirrorlist/?protocol=https&use_mirror_status=on&country=all" \
        | sed 's/^#Server/Server/' \
        > "${target}"
}

_write_wget_mirrorlist() {
    local target="${1:?_write_wget_mirrorlist requires a target path}"
    wget -qO- "https://archlinux.org/mirrorlist/?protocol=https&use_mirror_status=on&country=all" \
        | sed 's/^#Server/Server/' \
        > "${target}"
}

# ── _network_available ────────────────────────────────────────────────────────
# Returns 0 if internet is reachable, 1 otherwise.
_network_available() {
    ping -c1 -W2 archlinux.org &>/dev/null || \
    ping -c1 -W2 8.8.8.8       &>/dev/null || \
    return 1
}
