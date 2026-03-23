#!/usr/bin/env bash
# lib/diagnose.sh — scan system and report issues, zero modifications
# Designed to be the first thing a user runs when they don't know what's wrong.
set -euo pipefail

# ── diagnose_main ─────────────────────────────────────────────────────────────
# Runs a full system scan. Never writes to the target system.
# Arguments: $1=root_device_or_empty  $2=efi_device_or_empty
diagnose_main() {
    local root_dev="${1:-}"
    local efi_dev="${2:-}"
    local mapped_root
    local issues=0

    _d_header "Arch System Recovery — Diagnostic Scan"
    _d_info "This mode makes NO changes to your system."
    _d_info "Log: ${LOG_FILE}"
    echo "" >&2

    # ── Discover root ─────────────────────────────────────────────────────────
    _d_section "Block Devices"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT 2>/dev/null >&2 || true
    echo "" >&2

    _d_section "Root Partition"
    if [[ -z "${root_dev}" ]]; then
        root_dev="$(auto_detect_root 2>/dev/null || true)"
    fi
    if [[ -n "${root_dev}" && -b "${root_dev}" ]]; then
        _d_ok "Root device: ${root_dev}"
    else
        _d_issue "Could not auto-detect root partition"
        _d_hint  "Use: arch-recovery --root /dev/sdXN"
        (( issues++ )) || true
        _d_footer "${issues}"
        return 0
    fi

    # ── LUKS ──────────────────────────────────────────────────────────────────
    _d_section "Encryption"
    mapped_root="${root_dev}"
    if is_luks "${root_dev}"; then
        _d_ok "LUKS encryption detected on ${root_dev}"
        _d_hint "Passphrase will be required to unlock"
        mapped_root="$(unlock_luks "${root_dev}")"
        _d_ok "Unlocked mapper: ${mapped_root}"
    else
        _d_ok "No LUKS encryption on ${root_dev}"
    fi

    # ── LVM ───────────────────────────────────────────────────────────────────
    _d_section "LVM"
    local lvm_vgs
    lvm_vgs="$(vgs --noheadings -o vg_name 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "${lvm_vgs}" ]]; then
        _d_ok "LVM volume groups found: ${lvm_vgs}"
        mapped_root="$(detect_lvm "${mapped_root}" 2>/dev/null || echo "${mapped_root}")"
        [[ "${mapped_root}" != "${root_dev}" ]] && \
            _d_ok "Using mapped root device: ${mapped_root}"
    else
        _d_ok "No LVM volume groups detected"
    fi

    # ── Filesystem ────────────────────────────────────────────────────────────
    _d_section "Filesystem"
    local fstype
    fstype="$(detect_filesystem "${mapped_root}" 2>/dev/null || echo "unknown")"
    if [[ "${fstype}" != "unknown" ]]; then
        _d_ok "Filesystem: ${fstype}"
    else
        _d_issue "Could not determine filesystem type"
        (( issues++ )) || true
    fi

    # ── Try mounting temporarily ──────────────────────────────────────────────
    _d_section "Mount Test"
    local tmp_mount
    tmp_mount="$(mktemp -d /tmp/diag-mount.XXXXXX)"
    local mounted=false

    if [[ "${fstype}" == "unknown" ]]; then
        _d_issue "Skipping mount test because filesystem detection failed"
        (( issues++ )) || true
    elif mount_root_at "${tmp_mount}" "${mapped_root}" "${fstype}" ro 2>/dev/null; then
        _d_ok "Root partition mounts successfully (read-only)"
        mounted=true
    else
        _d_issue "Root partition failed to mount — filesystem may be corrupted"
        _d_hint  "Run: fsck ${mapped_root}   (unmount first)"
        (( issues++ )) || true
    fi

    if ${mounted}; then
        # ── Kernel check ──────────────────────────────────────────────────────
        _d_section "Kernel Images"
        local kernels
        kernels="$(find "${tmp_mount}/boot" -maxdepth 1 -name 'vmlinuz-*' \
                   2>/dev/null | sort || true)"
        if [[ -n "${kernels}" ]]; then
            _d_ok "Kernel images found:"
            echo "${kernels}" | sed 's|.*/boot/|          |' >&2
        else
            _d_issue "No kernel images found in /boot"
            _d_hint  "Install a kernel: pacman -S linux"
            (( issues++ )) || true
        fi

        # ── initramfs check ───────────────────────────────────────────────────
        _d_section "initramfs Images"
        local initrds
        initrds="$(find "${tmp_mount}/boot" -maxdepth 1 \
                   \( -name 'initramfs-*.img' -o -name 'initrd.img-*' \) \
                   2>/dev/null | sort || true)"
        if [[ -n "${initrds}" ]]; then
            _d_ok "initramfs found:"
            echo "${initrds}" | sed 's|.*/boot/|          |' >&2
        else
            _d_issue "No initramfs images found — mkinitcpio rebuild needed"
            _d_hint  "Fix: arch-recovery (will rebuild automatically)"
            (( issues++ )) || true
        fi

        # ── mkinitcpio.conf check ─────────────────────────────────────────────
        _d_section "mkinitcpio"
        if [[ -f "${tmp_mount}/etc/mkinitcpio.conf" ]]; then
            _d_ok "/etc/mkinitcpio.conf present"
            local hooks
            hooks="$(grep '^HOOKS=' "${tmp_mount}/etc/mkinitcpio.conf" \
                     2>/dev/null | head -1 || true)"
            [[ -n "${hooks}" ]] && _d_ok "HOOKS: ${hooks}" \
                                || _d_issue "No HOOKS line found in mkinitcpio.conf"
        else
            _d_issue "/etc/mkinitcpio.conf missing"
            (( issues++ )) || true
        fi

        # ── Bootloader check ──────────────────────────────────────────────────
        _d_section "Bootloader"
        local tmp_efi=""
        if [[ -n "${efi_dev}" ]] && [[ -b "${efi_dev}" ]]; then
            tmp_efi="$(_resolve_efi_target "${tmp_mount}")"
            mount_efi_at "${tmp_mount}" "${efi_dev}" ro 2>/dev/null || tmp_efi=""
        fi

        local bl
        bl="$(detect_bootloader "${tmp_mount}" 2>/dev/null || echo "unknown")"

        if [[ "${bl}" != "unknown" ]]; then
            _d_ok "Bootloader detected: ${bl}"
        else
            _d_issue "No bootloader detected (GRUB or systemd-boot)"
            _d_hint  "Fix: arch-recovery (will reinstall automatically)"
            (( issues++ )) || true
        fi

        [[ -n "${tmp_efi}" ]] && umount "${tmp_efi}" 2>/dev/null || true

        # ── EFI entries ───────────────────────────────────────────────────────
        _d_section "EFI Boot Entries"
        if command -v efibootmgr &>/dev/null; then
            local efi_entries
            efi_entries="$(efibootmgr 2>/dev/null | grep -E '^Boot[0-9]' || true)"
            if [[ -n "${efi_entries}" ]]; then
                _d_ok "EFI boot entries:"
                echo "${efi_entries}" | sed 's/^/          /' >&2
            else
                _d_issue "No EFI boot entries found"
                _d_hint  "Fix: arch-recovery (will reinstall bootloader)"
                (( issues++ )) || true
            fi
        else
            _d_ok "efibootmgr not available — skip EFI entry check"
        fi

        # ── fstab check ───────────────────────────────────────────────────────
        _d_section "/etc/fstab"
        if [[ -f "${tmp_mount}/etc/fstab" ]]; then
            local fstab_errors=0
            while IFS= read -r line; do
                [[ "${line}" =~ ^#  ]] && continue
                [[ -z "${line}"     ]] && continue
                local dev_field
                dev_field="$(echo "${line}" | awk '{print $1}')"
                # Check UUID entries exist
                if [[ "${dev_field}" =~ ^UUID= ]]; then
                    local uuid="${dev_field#UUID=}"
                    if ! blkid -U "${uuid}" &>/dev/null; then
                        _d_issue "fstab: UUID ${uuid} not found on any device"
                        (( fstab_errors++ )) || true
                        (( issues++ )) || true
                    fi
                fi
            done < "${tmp_mount}/etc/fstab"
            [[ ${fstab_errors} -eq 0 ]] && _d_ok "/etc/fstab looks valid"
        else
            _d_issue "/etc/fstab not found"
            (( issues++ )) || true
        fi

        # ── pacman database ───────────────────────────────────────────────────
        _d_section "Pacman"
        if [[ -d "${tmp_mount}/var/lib/pacman/local" ]]; then
            local pkg_count
            pkg_count="$(ls "${tmp_mount}/var/lib/pacman/local" 2>/dev/null | wc -l)"
            _d_ok "Pacman database present (${pkg_count} packages)"
        else
            _d_issue "Pacman database not found — system may be corrupted"
            (( issues++ )) || true
        fi

        # ── BTRFS snapshots ───────────────────────────────────────────────────
        if [[ "${fstype}" == "btrfs" ]]; then
            _d_section "BTRFS Snapshots"
            local snaps
            snaps="$(btrfs subvolume list "${tmp_mount}" 2>/dev/null \
                     | awk '{print $NF}' | grep -v '^@$\|^@root$' | head -10 \
                     || true)"
            if [[ -n "${snaps}" ]]; then
                _d_ok "Available snapshots:"
                echo "${snaps}" | sed 's/^/          /' >&2
                _d_hint "Roll back: arch-recovery --rollback <snapshot-name>"
            else
                _d_ok "No snapshots found"
            fi
        fi

        umount -l "${tmp_mount}" 2>/dev/null || true
    fi
    rmdir "${tmp_mount}" 2>/dev/null || true

    # ── Summary ───────────────────────────────────────────────────────────────
    _d_footer "${issues}"
}

# ── Diagnose output helpers ───────────────────────────────────────────────────
_d_header() {
    echo "" >&2
    _c_bold; _c_cyan
    printf "  ════════════════════════════════════════════\n" >&2
    printf "   %s\n" "$1" >&2
    printf "  ════════════════════════════════════════════\n" >&2
    _c_reset
}

_d_section() {
    echo "" >&2
    _c_bold; printf "  ── %s\n" "$1" >&2; _c_reset
    log "  [diagnose] ── $1"
}

_d_ok() {
    _c_green; printf "    ✓  %s\n" "$1" >&2; _c_reset
    log "  [diagnose] OK: $1"
}

_d_issue() {
    _c_red; _c_bold; printf "    ✗  %s\n" "$1" >&2; _c_reset
    log "  [diagnose] ISSUE: $1"
}

_d_hint() {
    _c_yellow; printf "       → %s\n" "$1" >&2; _c_reset
    log "  [diagnose] HINT: $1"
}

_d_info() {
    printf "  %s\n" "$1" >&2
    log "  [diagnose] INFO: $1"
}

_d_footer() {
    local issues="${1}"
    echo "" >&2
    _c_bold
    printf "  ════════════════════════════════════════════\n" >&2
    if [[ "${issues}" -eq 0 ]]; then
        _c_green
        printf "   ✓  No issues found. Your system looks healthy.\n" >&2
        printf "      If it still won't boot, check EFI settings in firmware.\n" >&2
    else
        _c_red
        printf "   ✗  Found %d issue(s) that need attention.\n" "${issues}" >&2
        _c_reset; _c_bold
        printf "      Run: sudo arch-recovery    to fix automatically.\n" >&2
        printf "      Run: sudo arch-recovery --tui   for guided menu.\n" >&2
    fi
    _c_reset
    printf "  ════════════════════════════════════════════\n" >&2
    echo "" >&2
    log "  [diagnose] Scan complete. Issues found: ${issues}"
}
