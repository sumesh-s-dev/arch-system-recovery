#!/usr/bin/env bash
# lib/detect.sh — auto-detection of root partition, filesystem, bootloader, subvolumes
# Part of: arch-system-recovery
set -euo pipefail

# ── Root partition auto-detection ─────────────────────────────────────────────
# Searches block devices for a likely Arch Linux root partition.
# Heuristics (weighted):
#   1. PARTLABEL/LABEL hints such as root / arch / archlinux
#   2. Read-only probe that looks like an Arch-style installed system
#   3. Supported filesystem/container type and plausible disk size
# Returns the device path (e.g. /dev/sda2) or exits with an error.
auto_detect_root() {
    log "Auto-detecting root partition..."

    local -a candidates=()
    local candidate
    local best_dev=""
    local best_fstype=""
    local best_score=-1
    local container_candidates=0
    local best_tied=false

    while IFS= read -r candidate; do
        local seen=false
        local existing
        [[ -n "${candidate}" ]] || continue
        for existing in "${candidates[@]:-}"; do
            if [[ "${existing}" == "${candidate}" ]]; then
                seen=true
                break
            fi
        done
        ${seen} || candidates+=("${candidate}")
    done < <(
        for label in arch archlinux root; do
            blkid -L "${label}" 2>/dev/null || true
        done
        blkid -t PARTLABEL=root -o device 2>/dev/null || true
        lsblk -dpno NAME,TYPE | awk '$2=="part"{print $1}' | sort
    )

    for candidate in "${candidates[@]}"; do
        local score fstype
        score="$(_score_root_candidate "${candidate}")"
        fstype="$(blkid -s TYPE -o value "${candidate}" 2>/dev/null || true)"
        _is_container_fstype "${fstype}" && (( container_candidates++ )) || true
        vlog "  Candidate ${candidate}: type=${fstype:-unknown} score=${score}"
        if (( score > best_score )); then
            best_score="${score}"
            best_dev="${candidate}"
            best_fstype="${fstype}"
            best_tied=false
        elif (( score == best_score )) && [[ -n "${best_dev}" ]] && [[ "${candidate}" != "${best_dev}" ]]; then
            best_tied=true
        fi
    done

    if [[ -n "${best_dev}" ]] && \
       _should_accept_auto_detect_root "${best_score}" "${best_fstype}" "${container_candidates}" "${best_tied}"; then
        log "  Auto-detected root: ${best_dev} (score=${best_score})"
        echo "${best_dev}"
        return 0
    fi

    die "Could not auto-detect root partition. Use --root <device> to specify it."
}

_is_container_fstype() {
    case "${1:-}" in
        crypto_LUKS|LVM2_member)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

_should_accept_auto_detect_root() {
    local best_score="${1:-0}"
    local best_fstype="${2:-}"
    local container_candidates="${3:-0}"
    local best_tied="${4:-false}"

    ${best_tied} && return 1
    (( best_score >= 6 )) && return 0

    _is_container_fstype "${best_fstype}" || return 1
    [[ "${container_candidates}" -eq 1 ]] || return 1
    (( best_score >= 3 ))
}

_score_root_candidate() {
    local dev="${1:?_score_root_candidate requires a device}"
    local fstype parttype label partlabel size score=0 probe_score=0

    [[ -b "${dev}" ]] || { echo 0; return 0; }

    fstype="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"
    parttype="$(blkid -s PART_ENTRY_TYPE -o value "${dev}" 2>/dev/null || true)"
    label="$(blkid -s LABEL -o value "${dev}" 2>/dev/null || true)"
    partlabel="$(blkid -s PARTLABEL -o value "${dev}" 2>/dev/null || true)"
    size="$(lsblk -bdno SIZE "${dev}" 2>/dev/null || echo 0)"

    # Skip obvious EFI partitions unless they are mislabeled containers.
    if [[ "${parttype}" == "$(_efi_parttype_guid)" && "${fstype}" != "crypto_LUKS" ]]; then
        echo 0
        return 0
    fi

    case "${fstype}" in
        btrfs|ext4)
            score=$(( score + 5 ))
            probe_score="$(_probe_root_candidate "${dev}" "${fstype}")"
            score=$(( score + probe_score ))
            ;;
        crypto_LUKS|LVM2_member)
            score=$(( score + 3 ))
            ;;
        *)
            echo 0
            return 0
            ;;
    esac

    case "${label,,}:${partlabel,,}" in
        arch:*|archlinux:*|root:*|*:arch|*:archlinux|*:root)
            score=$(( score + 8 ))
            ;;
        *)
            ;;
    esac

    if [[ "${size}" =~ ^[0-9]+$ ]]; then
        (( size >= 8 * 1024 * 1024 * 1024 )) && score=$(( score + 1 ))
        (( size >= 32 * 1024 * 1024 * 1024 )) && score=$(( score + 1 ))
    fi

    echo "${score}"
}

_probe_root_candidate() {
    local dev="${1:?_probe_root_candidate requires a device}"
    local fstype="${2:?_probe_root_candidate requires a filesystem type}"
    local tmpdir score=0 os_id=""
    tmpdir="$(mktemp -d /tmp/root-probe.XXXXXX)"

    if ! _mount_probe_root "${dev}" "${fstype}" "${tmpdir}"; then
        rmdir "${tmpdir}" 2>/dev/null || true
        echo 0
        return 0
    fi

    [[ -d "${tmpdir}/etc" ]] && score=$(( score + 2 ))
    [[ -f "${tmpdir}/etc/fstab" ]] && score=$(( score + 4 ))
    [[ -d "${tmpdir}/var/lib/pacman" ]] && score=$(( score + 2 ))
    [[ -d "${tmpdir}/boot" ]] && score=$(( score + 1 ))

    if [[ -f "${tmpdir}/etc/os-release" ]]; then
        os_id="$(
            awk -F= '$1=="ID"{gsub(/"/, "", $2); print tolower($2)}' \
                "${tmpdir}/etc/os-release" 2>/dev/null | head -1
        )"
        case "${os_id}" in
            arch|manjaro|endeavouros)
                score=$(( score + 4 ))
                ;;
        esac
    fi

    umount -l "${tmpdir}" 2>/dev/null || true
    rmdir "${tmpdir}" 2>/dev/null || true
    echo "${score}"
}

_mount_probe_root() {
    local dev="${1:?_mount_probe_root requires a device}"
    local fstype="${2:?_mount_probe_root requires a filesystem type}"
    local target="${3:?_mount_probe_root requires a target}"
    local subvol

    case "${fstype}" in
        btrfs)
            subvol="$(detect_btrfs_subvol "${dev}")"
            if [[ -n "${subvol}" ]]; then
                mount -t btrfs -o "subvol=${subvol},ro,compress=zstd,noatime" \
                    "${dev}" "${target}" 2>/dev/null
            else
                mount -t btrfs -o "subvolid=5,ro,compress=zstd,noatime" \
                    "${dev}" "${target}" 2>/dev/null
            fi
            ;;
        ext4)
            mount -t ext4 -o ro,relatime "${dev}" "${target}" 2>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

_efi_parttype_guid() {
    echo "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
}

_fstab_spec_for_mountpoint() {
    local root="${1:?_fstab_spec_for_mountpoint requires a root path}"
    local mountpoint="${2:?_fstab_spec_for_mountpoint requires a mountpoint}"
    local fstab="${root}/etc/fstab"

    [[ -f "${fstab}" ]] || return 1
    awk -v mp="${mountpoint}" '
        /^[[:space:]]*#/ {next}
        NF >= 2 && $2 == mp {print $1; exit}
    ' "${fstab}"
}

resolve_device_spec() {
    local spec="${1:?resolve_device_spec requires a device spec}"

    case "${spec}" in
        UUID=*)
            blkid -U "${spec#UUID=}" 2>/dev/null || true
            ;;
        PARTUUID=*)
            blkid -t "PARTUUID=${spec#PARTUUID=}" -o device 2>/dev/null | head -n1 || true
            ;;
        LABEL=*)
            blkid -L "${spec#LABEL=}" 2>/dev/null || true
            ;;
        PARTLABEL=*)
            blkid -t "PARTLABEL=${spec#PARTLABEL=}" -o device 2>/dev/null | head -n1 || true
            ;;
        /dev/*)
            [[ -e "${spec}" ]] && echo "${spec}" || true
            ;;
        *)
            true
            ;;
    esac
}

device_matches_spec() {
    local dev="${1:?device_matches_spec requires a device}"
    local spec="${2:?device_matches_spec requires a spec}"
    local expected resolved_dev uuid partuuid label partlabel

    expected="$(resolve_device_spec "${spec}")"
    if [[ -n "${expected}" ]]; then
        [[ "$(readlink -f "${dev}" 2>/dev/null || echo "${dev}")" == \
           "$(readlink -f "${expected}" 2>/dev/null || echo "${expected}")" ]] && return 0
    fi

    case "${spec}" in
        UUID=*)
            uuid="$(blkid -s UUID -o value "${dev}" 2>/dev/null || true)"
            [[ "${uuid}" == "${spec#UUID=}" ]]
            ;;
        PARTUUID=*)
            partuuid="$(blkid -s PARTUUID -o value "${dev}" 2>/dev/null || true)"
            [[ "${partuuid}" == "${spec#PARTUUID=}" ]]
            ;;
        LABEL=*)
            label="$(blkid -s LABEL -o value "${dev}" 2>/dev/null || true)"
            [[ "${label}" == "${spec#LABEL=}" ]]
            ;;
        PARTLABEL=*)
            partlabel="$(blkid -s PARTLABEL -o value "${dev}" 2>/dev/null || true)"
            [[ "${partlabel}" == "${spec#PARTLABEL=}" ]]
            ;;
        /dev/*)
            [[ "$(readlink -f "${dev}" 2>/dev/null || echo "${dev}")" == \
               "$(readlink -f "${spec}" 2>/dev/null || echo "${spec}")" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

detect_boot_device() {
    local root="${1:-${MOUNT_ROOT}}"
    local spec dev fstype parttype

    spec="$(_fstab_spec_for_mountpoint "${root}" "/boot" 2>/dev/null || true)"
    [[ -n "${spec}" ]] || { echo ""; return 0; }

    dev="$(resolve_device_spec "${spec}")"
    [[ -n "${dev}" ]] || { echo ""; return 0; }

    fstype="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"
    parttype="$(blkid -s PART_ENTRY_TYPE -o value "${dev}" 2>/dev/null || true)"

    # If /boot is actually the ESP, let EFI detection handle it.
    if [[ "${fstype}" == "vfat" || "${parttype}" == "$(_efi_parttype_guid)" ]]; then
        echo ""
        return 0
    fi

    log "Detected /boot device from fstab: ${dev}"
    echo "${dev}"
}

detect_fstab_efi_device() {
    local root="${1:-${MOUNT_ROOT}}"
    local spec dev candidate mp

    mp="$(detect_fstab_efi_mountpoint "${root}")"
    [[ -n "${mp}" ]] || { echo ""; return 0; }

    spec="$(_fstab_spec_for_mountpoint "${root}" "${mp}" 2>/dev/null || true)"
    dev="$(resolve_device_spec "${spec}")"
    [[ -n "${dev}" ]] || { echo ""; return 0; }

    log "Detected EFI device from fstab (${mp}): ${dev}"
    echo "${dev}"
}

detect_fstab_efi_mountpoint() {
    local root="${1:-${MOUNT_ROOT}}"
    local spec dev candidate mp

    for mp in /boot/efi /efi /boot; do
        spec="$(_fstab_spec_for_mountpoint "${root}" "${mp}" 2>/dev/null || true)"
        [[ -n "${spec}" ]] || continue

        dev="$(resolve_device_spec "${spec}")"
        [[ -n "${dev}" ]] || {
            [[ "${mp}" != "/boot" ]] && { echo "${mp}"; return 0; }
            continue
        }

        if [[ "${mp}" == "/boot" ]]; then
            candidate="$(blkid -s TYPE -o value "${dev}" 2>/dev/null || true)"
            [[ "${candidate}" == "vfat" || \
               "$(blkid -s PART_ENTRY_TYPE -o value "${dev}" 2>/dev/null || true)" == "$(_efi_parttype_guid)" ]] || continue
        fi

        echo "${mp}"
        return 0
    done

    echo ""
}

validate_mounted_root() {
    local root="${1:-${MOUNT_ROOT}}"
    local mapped_root="${2:-}"
    local strict="${3:-false}"
    local root_spec

    [[ -d "${root}/etc" ]] || die "Mounted root at ${root} does not contain /etc."

    if [[ ! -f "${root}/etc/fstab" ]]; then
        ${strict} && die "Mounted root at ${root} does not contain /etc/fstab. Use --root to specify the correct device."
        warn "Mounted root at ${root} does not contain /etc/fstab."
        return 0
    fi

    root_spec="$(_fstab_spec_for_mountpoint "${root}" "/" 2>/dev/null || true)"
    if [[ -n "${mapped_root}" && -n "${root_spec}" ]] && ! device_matches_spec "${mapped_root}" "${root_spec}"; then
        die "Mounted root does not match the / entry in /etc/fstab (${root_spec})."
    fi
}

validate_mountpoint_device() {
    local root="${1:-${MOUNT_ROOT}}"
    local mountpoint="${2:?validate_mountpoint_device requires a mountpoint}"
    local selected_dev="${3:-}"
    local label="${4:-device}"
    local expected_spec expected_dev

    expected_spec="$(_fstab_spec_for_mountpoint "${root}" "${mountpoint}" 2>/dev/null || true)"
    [[ -n "${expected_spec}" ]] || return 0

    expected_dev="$(resolve_device_spec "${expected_spec}")"
    [[ -n "${expected_dev}" ]] || return 0

    [[ -n "${selected_dev}" ]] || \
        die "The mounted system expects ${mountpoint} to use ${expected_spec}, but no ${label} was selected."

    device_matches_spec "${selected_dev}" "${expected_spec}" || \
        die "Selected ${label} ${selected_dev} does not match ${mountpoint} in /etc/fstab (${expected_spec})."
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
    local root="${1:-}"
    log "Auto-detecting EFI partition..."

    if [[ -n "${root}" && -f "${root}/etc/fstab" ]]; then
        local fstab_dev
        fstab_dev="$(detect_fstab_efi_device "${root}")"
        if [[ -n "${fstab_dev}" ]]; then
            echo "${fstab_dev}"
            return 0
        fi
    fi

    local dev
    dev="$(blkid -t TYPE=vfat -o device 2>/dev/null \
           | while read -r candidate; do
               pt="$(blkid -s PART_ENTRY_TYPE -o value "${candidate}" 2>/dev/null || true)"
               if [[ "${pt}" == "$(_efi_parttype_guid)" ]]; then
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
