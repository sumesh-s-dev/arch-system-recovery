#!/usr/bin/env bash
# lib/mount.sh — safe mounting of root filesystem, EFI partition, and bind mounts
# Part of: arch-system-recovery
set -euo pipefail

# Virtual filesystems to bind-mount into the chroot
readonly BIND_MOUNTS=(/dev /proc /sys /run)

# ── mount_root ────────────────────────────────────────────────────────────────
# Mounts <dev> of type <fstype> at MOUNT_ROOT.
# For BTRFS, probes for a root subvolume automatically.
mount_root() {
    local dev="${1:?mount_root requires a device}"
    local fstype="${2:?mount_root requires a filesystem type}"

    log "Preparing mount point: ${MOUNT_ROOT}"
    mkdir -p "${MOUNT_ROOT}"

    # Unmount if already mounted (idempotent re-run)
    if mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
        log "  ${MOUNT_ROOT} already mounted; skipping."
        return 0
    fi

    case "${fstype}" in
        btrfs)
            _mount_btrfs "${dev}"
            ;;
        ext4)
            _mount_ext4 "${dev}"
            ;;
        *)
            die "mount_root: unsupported filesystem '${fstype}'"
            ;;
    esac

    log "Root filesystem mounted at ${MOUNT_ROOT}"
}

# ── _mount_btrfs ──────────────────────────────────────────────────────────────
_mount_btrfs() {
    local dev="$1"
    local subvol
    subvol="$(detect_btrfs_subvol "${dev}")"

    if [[ -n "${subvol}" ]]; then
        log "  Mounting BTRFS subvolume '${subvol}' from ${dev}"
        mount -t btrfs -o "subvol=${subvol},compress=zstd,noatime" \
              "${dev}" "${MOUNT_ROOT}" \
              >> "${LOG_FILE}" 2>&1 \
              || die "Failed to mount BTRFS subvolume '${subvol}' on ${dev}"
    else
        log "  Mounting BTRFS top-level (no named subvolume) from ${dev}"
        mount -t btrfs -o "subvolid=5,compress=zstd,noatime" \
              "${dev}" "${MOUNT_ROOT}" \
              >> "${LOG_FILE}" 2>&1 \
              || die "Failed to mount BTRFS top-level on ${dev}"
    fi
}

# ── _mount_ext4 ───────────────────────────────────────────────────────────────
_mount_ext4() {
    local dev="$1"
    log "  Mounting ext4 partition ${dev}"
    mount -t ext4 -o rw,relatime \
          "${dev}" "${MOUNT_ROOT}" \
          >> "${LOG_FILE}" 2>&1 \
          || die "Failed to mount ext4 partition ${dev}"
}

# ── mount_efi ─────────────────────────────────────────────────────────────────
# Mounts <efi_dev> at the EFI location inside the chroot.
# Detects whether the system uses /boot/efi or /boot as the EFI mountpoint.
mount_efi() {
    local efi_dev="${1:?mount_efi requires an EFI device}"
    local efi_target
    efi_target="$(_resolve_efi_target)"

    log "Mounting EFI partition ${efi_dev} → ${efi_target}"
    mkdir -p "${efi_target}"

    if mountpoint -q "${efi_target}" 2>/dev/null; then
        log "  ${efi_target} already mounted; skipping."
        return 0
    fi

    mount -t vfat "${efi_dev}" "${efi_target}" \
          >> "${LOG_FILE}" 2>&1 \
          || die "Failed to mount EFI partition ${efi_dev} at ${efi_target}"

    log "EFI partition mounted at ${efi_target}"
}

# ── _resolve_efi_target ───────────────────────────────────────────────────────
# Determines the correct EFI mount target by inspecting the chrooted fstab.
# Falls back to /boot/efi (most common Arch layout) if unclear.
_resolve_efi_target() {
    local fstab="${MOUNT_ROOT}/etc/fstab"

    if [[ -f "${fstab}" ]]; then
        # Look for a line that mounts /boot/efi or /efi
        if grep -qE '^\s*[^#].*\s/boot/efi\s' "${fstab}"; then
            echo "${MOUNT_ROOT}/boot/efi"
            return 0
        fi
        if grep -qE '^\s*[^#].*\s/efi\s' "${fstab}"; then
            echo "${MOUNT_ROOT}/efi"
            return 0
        fi
        if grep -qE '^\s*[^#].*\s/boot\s' "${fstab}" && \
           [[ "$(blkid -s TYPE -o value "$(findmnt -n -o SOURCE "${MOUNT_ROOT}/boot" 2>/dev/null || true)" 2>/dev/null || true)" == "vfat" ]]; then
            echo "${MOUNT_ROOT}/boot"
            return 0
        fi
    fi

    # Safe default
    echo "${MOUNT_ROOT}/boot/efi"
}

# ── mount_bind ────────────────────────────────────────────────────────────────
# Bind-mounts the virtual filesystems (/dev, /proc, /sys, /run) into MOUNT_ROOT.
# Required before entering the chroot with arch-chroot.
mount_bind() {
    log "Bind-mounting virtual filesystems into chroot..."
    for fs in "${BIND_MOUNTS[@]}"; do
        local target="${MOUNT_ROOT}${fs}"
        if mountpoint -q "${target}" 2>/dev/null; then
            log "  ${target} already mounted; skipping."
            continue
        fi
        mkdir -p "${target}"
        mount --bind "${fs}" "${target}" \
              >> "${LOG_FILE}" 2>&1 \
              || die "Failed to bind-mount ${fs} → ${target}"
        log "  Bind-mounted: ${fs} → ${target}"
    done
}

# ── cleanup_mounts ────────────────────────────────────────────────────────────
# Unmounts all bind mounts and then the root/EFI in reverse order.
# Called at the end of recovery (success or failure via trap in main).
cleanup_mounts() {
    log "Cleaning up mounts..."

    # Unmount virtual filesystems first (reverse order)
    for fs in "${BIND_MOUNTS[@]}"; do
        local target="${MOUNT_ROOT}${fs}"
        if mountpoint -q "${target}" 2>/dev/null; then
            umount -l "${target}" >> "${LOG_FILE}" 2>&1 \
                || err "Could not unmount ${target}"
            log "  Unmounted: ${target}"
        fi
    done

    # Unmount EFI sub-mounts
    for subdir in boot/efi efi boot; do
        local target="${MOUNT_ROOT}/${subdir}"
        if mountpoint -q "${target}" 2>/dev/null; then
            umount -l "${target}" >> "${LOG_FILE}" 2>&1 \
                || err "Could not unmount ${target}"
            log "  Unmounted: ${target}"
        fi
    done

    # Unmount root
    if mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
        umount -l "${MOUNT_ROOT}" >> "${LOG_FILE}" 2>&1 \
            || err "Could not unmount ${MOUNT_ROOT}"
        log "  Unmounted: ${MOUNT_ROOT}"
    fi

    # Close LUKS if open
    close_luks

    log "Cleanup complete."
}
