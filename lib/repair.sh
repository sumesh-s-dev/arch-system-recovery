#!/usr/bin/env bash
# lib/repair.sh — initramfs rebuild and bootloader reinstallation via arch-chroot
# Part of: arch-system-recovery
set -euo pipefail

# ── repair_initramfs ──────────────────────────────────────────────────────────
# Rebuilds all initramfs presets inside the chroot.
# Bind mounts must already be in place before calling this function.
repair_initramfs() {
    log "Rebuilding initramfs (mkinitcpio -P)..."

    mount_bind  # Ensure virtual filesystems are mounted

    arch-chroot "${MOUNT_ROOT}" /bin/bash -c "mkinitcpio -P" \
        >> "${LOG_FILE}" 2>&1 \
        || die "mkinitcpio failed inside chroot. See log: ${LOG_FILE}"

    log "initramfs rebuild complete."
}

# ── repair_bootloader ─────────────────────────────────────────────────────────
# Dispatches to the appropriate bootloader repair function.
# Arguments:
#   $1 — bootloader name: "grub", "systemd-boot", or "unknown"
#   $2 — EFI device path (may be empty for BIOS-mode GRUB)
repair_bootloader() {
    local bootloader="${1:-unknown}"
    local efi_dev="${2:-}"

    case "${bootloader}" in
        grub)
            repair_grub "${efi_dev}"
            ;;
        systemd-boot)
            repair_systemd_boot
            ;;
        unknown)
            log "Bootloader unknown. Attempting to determine from user input..."
            local choice
            choice="$(prompt_bootloader_choice)"
            repair_bootloader "${choice}" "${efi_dev}"
            ;;
        *)
            die "Unsupported bootloader: ${bootloader}"
            ;;
    esac
}

# ── repair_grub ───────────────────────────────────────────────────────────────
# Reinstalls GRUB (UEFI) and regenerates the GRUB configuration.
repair_grub() {
    local efi_dev="${1:-}"

    log "Repairing GRUB (UEFI)..."

    # Determine EFI directory: prefer /boot/efi, fall back to /boot
    local efi_dir
    efi_dir="$(_find_efi_dir)"
    log "  EFI directory: ${efi_dir}"

    # grub-install inside the chroot
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
        "grub-install \
            --target=x86_64-efi \
            --efi-directory=${efi_dir} \
            --bootloader-id=GRUB \
            --recheck" \
        >> "${LOG_FILE}" 2>&1 \
        || die "grub-install failed. See log: ${LOG_FILE}"

    log "  grub-install successful."

    # Regenerate GRUB config
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
        "grub-mkconfig -o /boot/grub/grub.cfg" \
        >> "${LOG_FILE}" 2>&1 \
        || die "grub-mkconfig failed. See log: ${LOG_FILE}"

    log "  GRUB configuration regenerated."
    log "GRUB repair complete."
}

# ── repair_systemd_boot ───────────────────────────────────────────────────────
# Reinstalls systemd-boot into the ESP.
repair_systemd_boot() {
    log "Repairing systemd-boot..."

    arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
        "bootctl install" \
        >> "${LOG_FILE}" 2>&1 \
        || die "bootctl install failed. See log: ${LOG_FILE}"

    log "  bootctl install successful."

    # Update if already installed (idempotent for newer systemd)
    arch-chroot "${MOUNT_ROOT}" /bin/bash -c \
        "bootctl update 2>/dev/null || true" \
        >> "${LOG_FILE}" 2>&1

    log "systemd-boot repair complete."
}

# ── _find_efi_dir ─────────────────────────────────────────────────────────────
# Returns the EFI directory path relative to the chroot root (e.g. /boot/efi).
# Used for grub-install --efi-directory=<dir>.
_find_efi_dir() {
    # Check whether /boot/efi is mounted inside the chroot
    if mountpoint -q "${MOUNT_ROOT}/boot/efi" 2>/dev/null; then
        echo "/boot/efi"
        return 0
    fi
    # Some systems mount the ESP directly at /boot
    if mountpoint -q "${MOUNT_ROOT}/boot" 2>/dev/null; then
        local fstype
        fstype="$(findmnt -n -o FSTYPE "${MOUNT_ROOT}/boot" 2>/dev/null || true)"
        if [[ "${fstype}" == "vfat" ]]; then
            echo "/boot"
            return 0
        fi
    fi
    # /efi is also used occasionally
    if mountpoint -q "${MOUNT_ROOT}/efi" 2>/dev/null; then
        echo "/efi"
        return 0
    fi
    # Default safe fallback
    echo "/boot/efi"
}
