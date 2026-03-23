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
    local mode="${3:-rw}"

    mount_root_at "${MOUNT_ROOT}" "${dev}" "${fstype}" "${mode}"
}

# ── mount_root_at ─────────────────────────────────────────────────────────────
# Mounts <dev> of type <fstype> at an explicit target directory.
mount_root_at() {
    local target="${1:?mount_root_at requires a target}"
    local dev="${2:?mount_root_at requires a device}"
    local fstype="${3:?mount_root_at requires a filesystem type}"
    local mode="${4:-rw}"

    log "Preparing mount point: ${target}"
    mkdir -p "${target}"

    # Unmount if already mounted (idempotent re-run)
    if mountpoint -q "${target}" 2>/dev/null; then
        log "  ${target} already mounted; skipping."
        return 0
    fi

    case "${fstype}" in
        btrfs)
            _mount_btrfs "${dev}" "${target}" "${mode}"
            ;;
        ext4)
            _mount_ext4 "${dev}" "${target}" "${mode}"
            ;;
        *)
            die "mount_root_at: unsupported filesystem '${fstype}'"
            ;;
    esac

    log "Root filesystem mounted at ${target}"
}

# ── _mount_btrfs ──────────────────────────────────────────────────────────────
_mount_btrfs() {
    local dev="$1"
    local target="$2"
    local mode="${3:-rw}"
    local subvol
    local opts
    subvol="$(detect_btrfs_subvol "${dev}")"

    opts="${mode},compress=zstd,noatime"
    if [[ -n "${subvol}" ]]; then
        log "  Mounting BTRFS subvolume '${subvol}' from ${dev}"
        mount -t btrfs -o "subvol=${subvol},${opts}" \
              "${dev}" "${target}" \
              >> "${LOG_FILE}" 2>&1 \
              || die "Failed to mount BTRFS subvolume '${subvol}' on ${dev}"
    else
        log "  Mounting BTRFS top-level (no named subvolume) from ${dev}"
        mount -t btrfs -o "subvolid=5,${opts}" \
              "${dev}" "${target}" \
              >> "${LOG_FILE}" 2>&1 \
              || die "Failed to mount BTRFS top-level on ${dev}"
    fi
}

# ── _mount_ext4 ───────────────────────────────────────────────────────────────
_mount_ext4() {
    local dev="$1"
    local target="$2"
    local mode="${3:-rw}"
    log "  Mounting ext4 partition ${dev}"
    mount -t ext4 -o "${mode},relatime" \
          "${dev}" "${target}" \
          >> "${LOG_FILE}" 2>&1 \
          || die "Failed to mount ext4 partition ${dev}"
}

# ── mount_efi ─────────────────────────────────────────────────────────────────
# Mounts <efi_dev> at the EFI location inside the chroot.
# Detects whether the system uses /boot/efi or /boot as the EFI mountpoint.
mount_boot() {
    local boot_dev="${1:?mount_boot requires a boot device}"
    local mode="${2:-rw}"
    mount_boot_at "${MOUNT_ROOT}" "${boot_dev}" "${mode}"
}

# ── mount_boot_at ─────────────────────────────────────────────────────────────
# Mounts a separate /boot partition inside the specified root.
mount_boot_at() {
    local root="${1:?mount_boot_at requires a root}"
    local boot_dev="${2:?mount_boot_at requires a boot device}"
    local mode="${3:-rw}"
    local target="${root}/boot"
    local fstype

    log "Mounting /boot partition ${boot_dev} → ${target}"
    mkdir -p "${target}"

    if mountpoint -q "${target}" 2>/dev/null; then
        log "  ${target} already mounted; skipping."
        return 0
    fi

    fstype="$(blkid -s TYPE -o value "${boot_dev}" 2>/dev/null || true)"
    case "${fstype}" in
        btrfs)
            mount -t btrfs -o "${mode},compress=zstd,noatime" \
                "${boot_dev}" "${target}" \
                >> "${LOG_FILE}" 2>&1 \
                || die "Failed to mount /boot BTRFS partition ${boot_dev}"
            ;;
        *)
            mount -t auto -o "${mode},relatime" \
                "${boot_dev}" "${target}" \
                >> "${LOG_FILE}" 2>&1 \
                || die "Failed to mount /boot partition ${boot_dev}"
            ;;
    esac

    log "/boot partition mounted at ${target}"
}

# ── mount_efi ─────────────────────────────────────────────────────────────────
# Mounts <efi_dev> at the EFI location inside the chroot.
# Detects whether the system uses /boot/efi or /boot as the EFI mountpoint.
mount_efi() {
    local efi_dev="${1:?mount_efi requires an EFI device}"
    local mode="${2:-rw}"
    mount_efi_at "${MOUNT_ROOT}" "${efi_dev}" "${mode}"
}

# ── mount_efi_at ──────────────────────────────────────────────────────────────
# Mounts <efi_dev> at the EFI location inside the specified root.
mount_efi_at() {
    local root="${1:?mount_efi_at requires a root}"
    local efi_dev="${2:?mount_efi_at requires an EFI device}"
    local mode="${3:-rw}"
    local efi_target
    local mount_opts=()
    efi_target="$(_resolve_efi_target "${root}")"

    log "Mounting EFI partition ${efi_dev} → ${efi_target}"
    mkdir -p "${efi_target}"

    if mountpoint -q "${efi_target}" 2>/dev/null; then
        log "  ${efi_target} already mounted; skipping."
        return 0
    fi

    [[ "${mode}" == "ro" ]] && mount_opts=(-o ro)
    mount -t vfat "${mount_opts[@]}" "${efi_dev}" "${efi_target}" \
          >> "${LOG_FILE}" 2>&1 \
          || die "Failed to mount EFI partition ${efi_dev} at ${efi_target}"

    log "EFI partition mounted at ${efi_target}"
}

# ── _resolve_efi_target ───────────────────────────────────────────────────────
# Determines the correct EFI mount target by inspecting the chrooted fstab.
# Falls back to /boot/efi (most common Arch layout) if unclear.
_resolve_efi_target() {
    local root="${1:-${MOUNT_ROOT}}"
    local fstab="${root}/etc/fstab"

    if [[ -f "${fstab}" ]]; then
        # Look for a line that mounts /boot/efi or /efi
        if grep -qE '^\s*[^#].*\s/boot/efi\s' "${fstab}"; then
            echo "${root}/boot/efi"
            return 0
        fi
        if grep -qE '^\s*[^#].*\s/efi\s' "${fstab}"; then
            echo "${root}/efi"
            return 0
        fi
        if grep -qE '^\s*[^#].*\s/boot\s' "${fstab}" && \
           [[ "$(blkid -s TYPE -o value "$(findmnt -n -o SOURCE "${root}/boot" 2>/dev/null || true)" 2>/dev/null || true)" == "vfat" ]]; then
            echo "${root}/boot"
            return 0
        fi
    fi

    # Safe default
    echo "${root}/boot/efi"
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
