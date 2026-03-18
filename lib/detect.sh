#!/usr/bin/env bash
# lib/detect.sh — auto-detection of root partition, filesystem, bootloader, subvolumes
# Part of: arch-system-recovery
set -euo pipefail

# ── Root partition auto-detection ─────────────────────────────────────────────
# Searches block devices for a likely Arch Linux root partition.
# Heuristics (in order):
#   1. Partition with PARTLABEL="root" or LABEL="arch" / "archlinux"
#   2. First ext4 or BTRFS partition ≥ 4 GiB that is not an EFI partition
# Returns the device path (e.g. /dev/sda2) or exits with an error.
auto_detect_root() {
    log "Auto-detecting root partition..."

    local dev
    # Priority 1: explicit labels
    for label in arch archlinux root; do
        dev="$(blkid -L "${label}" 2>/dev/null || true)"
        if [[ -n "${dev}" ]]; then
            log "  Found root via label '${label}': ${dev}"
            echo "${dev}"
            return 0
        fi
    done

    # Priority 2: PARTLABEL=root
    dev="$(blkid -t PARTLABEL=root -o device 2>/dev/null | head -n1 || true)"
    if [[ -n "${dev}" ]]; then
        log "  Found root via PARTLABEL=root: ${dev}"
        echo "${dev}"
        return 0
    fi

    # Priority 3: first ext4 / BTRFS partition that is NOT type EF00 (EFI)
    while IFS= read -r candidate; do
        local fstype
        fstype="$(blkid -s TYPE -o value "${candidate}" 2>/dev/null || true)"
        if [[ "${fstype}" == "ext4" || "${fstype}" == "btrfs" ]]; then
            local parttype
            parttype="$(blkid -s PART_ENTRY_TYPE -o value "${candidate}" 2>/dev/null || true)"
            # Skip EFI System Partition (type GUID)
            if [[ "${parttype}" != "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                log "  Auto-detected root (heuristic): ${candidate} [${fstype}]"
                echo "${candidate}"
                return 0
            fi
        fi
    done < <(lsblk -dpno NAME,TYPE | awk '$2=="part"{print $1}' | sort)

    die "Could not auto-detect root partition. Use --root <device> to specify it."
}

# ── Filesystem detection ──────────────────────────────────────────────────────
# Accepts a block device; returns "btrfs", "ext4", or exits with error.
detect_filesystem() {
    local dev="${1:?detect_filesystem requires a device}"
    local fstype
    fstype="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"

    case "${fstype}" in
        btrfs|ext4)
            log "Detected filesystem: ${fstype} on ${dev}"
            echo "${fstype}"
            ;;
        "")
            die "Could not determine filesystem on ${dev}. Is the device correct?"
            ;;
        *)
            die "Unsupported filesystem '${fstype}' on ${dev}. Supported: btrfs, ext4."
            ;;
    esac
}

# ── Bootloader detection ──────────────────────────────────────────────────────
# Examines the mounted system (at MOUNT_ROOT) to determine whether GRUB or
# systemd-boot was in use.  Returns "grub", "systemd-boot", or "unknown".
detect_bootloader() {
    # Optional $1 overrides MOUNT_ROOT — used by tests and diagnose module
    local root="${1:-${MOUNT_ROOT}}"
    local efi_dir="${root}/boot/efi"
    local boot_dir="${root}/boot"

    # systemd-boot leaves a loader/loader.conf
    if [[ -f "${efi_dir}/loader/loader.conf" || -f "${boot_dir}/loader/loader.conf" ]]; then
        log "Detected bootloader: systemd-boot"
        echo "systemd-boot"
        return 0
    fi

    # GRUB leaves /boot/grub or /boot/grub2 directories
    if [[ -d "${boot_dir}/grub" || -d "${boot_dir}/grub2" ]]; then
        log "Detected bootloader: grub"
        echo "grub"
        return 0
    fi

    log "Bootloader detection inconclusive; defaulting to unknown"
    echo "unknown"
}

# ── BTRFS subvolume detection ─────────────────────────────────────────────────
# Given a mounted BTRFS filesystem, attempts to find the root subvolume.
# Tries common names: @, @root, then falls back to top-level (subvolid=5).
# Returns the subvolume name suitable for -o subvol=<name> mount option.
detect_btrfs_subvol() {
    local dev="${1:?detect_btrfs_subvol requires a device}"
    local tmpdir
    tmpdir="$(mktemp -d /tmp/btrfs-probe.XXXXXX)"

    # Mount top-level to inspect subvolumes
    mount -o subvolid=5,ro "${dev}" "${tmpdir}" 2>/dev/null || {
        err "Cannot mount ${dev} at top level for subvolume probe."
        rmdir "${tmpdir}"
        echo ""
        return 1
    }

    local subvol=""
    for candidate in @ @root; do
        if [[ -d "${tmpdir}/${candidate}" ]]; then
            subvol="${candidate}"
            log "Found BTRFS root subvolume: ${subvol}"
            break
        fi
    done

    umount "${tmpdir}" 2>/dev/null || true
    rmdir "${tmpdir}"  2>/dev/null || true

    if [[ -z "${subvol}" ]]; then
        log "No named BTRFS subvolume found; will mount default (subvolid=5)"
    fi

    echo "${subvol}"
}

# ── EFI partition auto-detection ──────────────────────────────────────────────
# Finds the first partition with filesystem type vfat and the EFI System
# Partition GUID.  Returns device path or empty string if not found.
auto_detect_efi() {
    log "Auto-detecting EFI partition..."

    local dev
    dev="$(blkid -t TYPE=vfat -o device 2>/dev/null \
           | while read -r candidate; do
               pt="$(blkid -s PART_ENTRY_TYPE -o value "${candidate}" 2>/dev/null || true)"
               if [[ "${pt}" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
                   echo "${candidate}"
                   break
               fi
             done || true)"

    if [[ -n "${dev}" ]]; then
        log "  Auto-detected EFI partition: ${dev}"
    else
        log "  No EFI partition detected."
    fi
    echo "${dev}"
}

# ── LVM detection and activation ─────────────────────────────────────────────
# If the given device is an LVM Physical Volume, activates all volume groups
# and returns the path to the root logical volume.
# If no LVM is found, returns the original device path unchanged.
detect_lvm() {
    local dev="${1:?detect_lvm requires a device}"

    if ! command -v pvs &>/dev/null; then
        dlog "LVM tools not available — skipping LVM detection"
        echo "${dev}"
        return 0
    fi

    # Check if device is an LVM PV
    if ! pvs "${dev}" &>/dev/null; then
        dlog "${dev} is not an LVM PV"
        echo "${dev}"
        return 0
    fi

    log "LVM Physical Volume detected on ${dev}"

    # Activate all volume groups
    vgchange -ay >> "${LOG_FILE}" 2>&1 || warn "vgchange -ay failed (non-fatal)"

    # Find the root LV: look for one named 'root' or mounted at /
    local root_lv
    root_lv="$(lvs --noheadings -o lv_path 2>/dev/null \
        | tr -d ' ' \
        | grep -E '[-/]root$' \
        | head -1 || true)"

    if [[ -n "${root_lv}" ]]; then
        log "  LVM root logical volume: ${root_lv}"
        echo "${root_lv}"
    else
        warn "LVM PV found but no 'root' logical volume detected — using ${dev}"
        echo "${dev}"
    fi
}
