#!/usr/bin/env bash
# lib/luks.sh — LUKS detection and unlock
# Part of: arch-system-recovery
set -euo pipefail

# ── Mapper name used for the unlocked LUKS device ────────────────────────────
[[ -v LUKS_MAPPER_NAME ]] || readonly LUKS_MAPPER_NAME="recovery_crypt"
[[ -v LUKS_MAPPED_PATH ]] || readonly LUKS_MAPPED_PATH="/dev/mapper/${LUKS_MAPPER_NAME}"

# ── is_luks ───────────────────────────────────────────────────────────────────
# Returns 0 (true) if the given device is a LUKS container, 1 otherwise.
is_luks() {
    local dev="${1:?is_luks requires a device}"
    if cryptsetup isLuks "${dev}" &>/dev/null; then
        return 0
    fi
    return 1
}

# ── unlock_luks ───────────────────────────────────────────────────────────────
# Opens the LUKS container at <dev> and returns the mapped device path.
# Prompts the user for the passphrase (cryptsetup handles this natively).
# Exits with an error if unlocking fails.
unlock_luks() {
    local dev="${1:?unlock_luks requires a device}"

    log "Opening LUKS container: ${dev}"
    log "  Mapped name will be: ${LUKS_MAPPER_NAME}"

    # If already open (e.g. re-run), skip re-opening
    if [[ -e "${LUKS_MAPPED_PATH}" ]]; then
        log "  LUKS mapper '${LUKS_MAPPER_NAME}' already exists; reusing."
        echo "${LUKS_MAPPED_PATH}"
        return 0
    fi

    # cryptsetup open prompts for the passphrase interactively.
    # We intentionally do NOT pass --batch-mode so the user is prompted.
    if ! cryptsetup open --type luks "${dev}" "${LUKS_MAPPER_NAME}"; then
        die "Failed to unlock LUKS container on ${dev}. Wrong passphrase?"
    fi

    log "  LUKS container unlocked → ${LUKS_MAPPED_PATH}"
    echo "${LUKS_MAPPED_PATH}"
}

# ── close_luks ────────────────────────────────────────────────────────────────
# Closes the LUKS mapper created by unlock_luks (called during cleanup).
# Silently succeeds if the mapper does not exist.
close_luks() {
    if [[ -e "${LUKS_MAPPED_PATH}" ]]; then
        log "Closing LUKS mapper: ${LUKS_MAPPER_NAME}"
        cryptsetup close "${LUKS_MAPPER_NAME}" >> "${LOG_FILE}" 2>&1 || \
            err "Could not close LUKS mapper '${LUKS_MAPPER_NAME}'. Close it manually."
    fi
}
