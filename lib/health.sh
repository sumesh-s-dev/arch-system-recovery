#!/usr/bin/env bash
# lib/health.sh — post-repair system health verification
#
# Runs inside arch-chroot to verify the repaired system looks ready to boot.
# Produces a colour-coded pass/warn/fail summary with actionable hints.
# Never modifies the target system — read-only checks only.
#
# Triggered by: arch-recovery --health-check
# Part of: arch-system-recovery
set -euo pipefail

# ── run_health_check ──────────────────────────────────────────────────────────
# Entry point. Root must already be mounted at MOUNT_ROOT.
run_health_check() {
    local pass=0 warn=0 fail=0

    _hc_header "Post-Repair Health Check"
    _hc_info "Read-only — no changes made."
    echo "" >&2

    if ! mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
        die "Root filesystem not mounted at ${MOUNT_ROOT}. Mount it first."
    fi

    local boot_dev
    boot_dev="$(detect_boot_device "${MOUNT_ROOT}" 2>/dev/null || true)"
    if [[ -n "${boot_dev}" ]] && ! mountpoint -q "${MOUNT_ROOT}/boot" 2>/dev/null; then
        _hc_fail "Separate /boot partition is expected but not mounted" \
                 "Mount ${boot_dev} at ${MOUNT_ROOT}/boot and re-run the health check"
        (( fail++ )) || true
    fi

    # ── Kernel images ──────────────────────────────────────────────────────────
    _hc_section "Kernel"
    local kernels
    mapfile -t kernels < <(find "${MOUNT_ROOT}/boot" -maxdepth 1 \
        -name 'vmlinuz-*' 2>/dev/null | sort)

    if [[ ${#kernels[@]} -eq 0 ]]; then
        _hc_fail "No kernel images in /boot" \
                 "pacman -S linux    or    pacman -S linux-lts"
        (( fail++ )) || true
    else
        for k in "${kernels[@]}"; do
            _hc_pass "Kernel: $(basename "${k}")"
            (( pass++ )) || true
        done
    fi

    # ── initramfs images ──────────────────────────────────────────────────────
    _hc_section "initramfs"
    local initrds
    mapfile -t initrds < <(find "${MOUNT_ROOT}/boot" -maxdepth 1 \
        -name 'initramfs-*.img' 2>/dev/null | sort)

    if [[ ${#initrds[@]} -eq 0 ]]; then
        _hc_fail "No initramfs images in /boot" \
                 "arch-chroot /mnt mkinitcpio -P"
        (( fail++ )) || true
    else
        for img in "${initrds[@]}"; do
            # Check size is non-trivial (broken mkinitcpio can produce 0-byte files)
            local size
            size="$(stat -c '%s' "${img}" 2>/dev/null || echo 0)"
            if (( size < 1024 )); then
                _hc_fail "initramfs too small (${size} bytes): $(basename "${img}")" \
                         "Rebuild: arch-chroot /mnt mkinitcpio -P"
                (( fail++ )) || true
            else
                _hc_pass "initramfs: $(basename "${img}") ($(( size / 1024 )) KiB)"
                (( pass++ )) || true
            fi
        done
    fi

    # ── Each kernel has a matching initramfs ──────────────────────────────────
    _hc_section "Kernel / initramfs pairing"
    local missing_pairs=0
    for k in "${kernels[@]}"; do
        local kname="${k##*/vmlinuz-}"   # strip path + vmlinuz- prefix
        local matching_initrd="${MOUNT_ROOT}/boot/initramfs-${kname}.img"
        if [[ -f "${matching_initrd}" ]]; then
            _hc_pass "Pair OK: ${kname}"
            (( pass++ )) || true
        else
            _hc_warn "No matching initramfs for vmlinuz-${kname}"
            _hc_hint "mkinitcpio -p ${kname}"
            (( warn++ )) || true
        fi
    done
    [[ ${#kernels[@]} -eq 0 ]] && missing_pairs=1

    # ── Bootloader ────────────────────────────────────────────────────────────
    _hc_section "Bootloader"
    local bl
    bl="$(detect_bootloader "${MOUNT_ROOT}" 2>/dev/null || echo "unknown")"

    case "${bl}" in
        grub)
            if [[ -f "${MOUNT_ROOT}/boot/grub/grub.cfg" ]]; then
                _hc_pass "GRUB config: /boot/grub/grub.cfg present"
                (( pass++ )) || true
                # Sanity: grub.cfg should reference at least one kernel
                if grep -q 'linux\|linuxefi' "${MOUNT_ROOT}/boot/grub/grub.cfg" \
                        2>/dev/null; then
                    _hc_pass "GRUB config references a kernel entry"
                    (( pass++ )) || true
                else
                    _hc_warn "GRUB config has no kernel entries"
                    _hc_hint "arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg"
                    (( warn++ )) || true
                fi
            else
                _hc_fail "GRUB config missing: /boot/grub/grub.cfg" \
                         "arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg"
                (( fail++ )) || true
            fi
            ;;
        systemd-boot)
            local loader_conf=""
            for p in "${MOUNT_ROOT}/boot/loader/loader.conf" \
                     "${MOUNT_ROOT}/boot/efi/loader/loader.conf" \
                     "${MOUNT_ROOT}/efi/loader/loader.conf"; do
                [[ -f "${p}" ]] && { loader_conf="${p}"; break; }
            done
            if [[ -n "${loader_conf}" ]]; then
                _hc_pass "systemd-boot loader.conf: ${loader_conf#"${MOUNT_ROOT}"}"
                (( pass++ )) || true
            else
                _hc_fail "systemd-boot loader.conf not found" \
                         "arch-chroot /mnt bootctl install"
                (( fail++ )) || true
            fi
            ;;
        unknown)
            _hc_warn "No bootloader detected"
            _hc_hint "Run: arch-recovery --auto --no-initramfs"
            (( warn++ )) || true
            ;;
    esac

    # ── EFI boot entries ──────────────────────────────────────────────────────
    _hc_section "EFI Boot Entries"
    if command -v efibootmgr &>/dev/null; then
        local boot_entries
        boot_entries="$(efibootmgr 2>/dev/null | grep -cE '^Boot[0-9]{4}\*' || echo 0)"
        if (( boot_entries > 0 )); then
            _hc_pass "${boot_entries} active EFI boot entry/entries"
            (( pass++ )) || true
        else
            _hc_warn "No active EFI boot entries"
            _hc_hint "Reinstall bootloader to create EFI entry"
            (( warn++ )) || true
        fi
    else
        _hc_info "efibootmgr not available — skip EFI entry check"
    fi

    # ── /etc/fstab ────────────────────────────────────────────────────────────
    _hc_section "/etc/fstab"
    if [[ -f "${MOUNT_ROOT}/etc/fstab" ]]; then
        local stale=0
        while IFS= read -r line; do
            [[ "${line}" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }"              ]] && continue
            local dev_field
            dev_field="$(awk '{print $1}' <<< "${line}")"
            if [[ "${dev_field}" =~ ^UUID= ]]; then
                local uuid="${dev_field#UUID=}"
                blkid -U "${uuid}" &>/dev/null || {
                    _hc_warn "Stale UUID in fstab: ${uuid}"
                    (( stale++ )) || true
                    (( warn++ ))  || true
                }
            fi
        done < "${MOUNT_ROOT}/etc/fstab"
        [[ ${stale} -eq 0 ]] && {
            _hc_pass "/etc/fstab UUIDs all valid"
            (( pass++ )) || true
        }
    else
        _hc_fail "/etc/fstab missing" \
                 "Restore from backup or recreate manually"
        (( fail++ )) || true
    fi

    # ── mkinitcpio.conf ───────────────────────────────────────────────────────
    _hc_section "mkinitcpio.conf"
    if [[ -f "${MOUNT_ROOT}/etc/mkinitcpio.conf" ]]; then
        _hc_pass "/etc/mkinitcpio.conf present"
        (( pass++ )) || true
        # Warn on missing encrypt hook for LUKS systems
        local hooks_line
        hooks_line="$(grep '^HOOKS=' "${MOUNT_ROOT}/etc/mkinitcpio.conf" \
                      2>/dev/null | head -1 || true)"
        if [[ -n "${hooks_line}" ]]; then
            _hc_pass "HOOKS defined: ${hooks_line}"
            (( pass++ )) || true
        else
            _hc_warn "No HOOKS line in mkinitcpio.conf"
            (( warn++ )) || true
        fi
    else
        _hc_fail "/etc/mkinitcpio.conf missing" \
                 "pacman -S mkinitcpio  (inside chroot)"
        (( fail++ )) || true
    fi

    # ── locale and timezone ───────────────────────────────────────────────────
    _hc_section "Locale & Timezone"
    [[ -f "${MOUNT_ROOT}/etc/locale.conf" ]] \
        && { _hc_pass "/etc/locale.conf present"; (( pass++ )) || true; } \
        || { _hc_warn "/etc/locale.conf missing (system may boot with broken locale)"; \
             (( warn++ )) || true; }

    [[ -L "${MOUNT_ROOT}/etc/localtime" || -f "${MOUNT_ROOT}/etc/localtime" ]] \
        && { _hc_pass "/etc/localtime set"; (( pass++ )) || true; } \
        || { _hc_warn "/etc/localtime not set"; (( warn++ )) || true; }

    # ── Pacman database ───────────────────────────────────────────────────────
    _hc_section "Pacman"
    if [[ -d "${MOUNT_ROOT}/var/lib/pacman/local" ]]; then
        local pkg_count
        pkg_count="$(ls "${MOUNT_ROOT}/var/lib/pacman/local" 2>/dev/null | wc -l)"
        _hc_pass "Pacman database present (${pkg_count} packages)"
        (( pass++ )) || true
    else
        _hc_fail "Pacman database missing" \
                 "System may be severely corrupted — reinstall may be needed"
        (( fail++ )) || true
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    _hc_summary "${pass}" "${warn}" "${fail}"
    log "[health-check] pass=${pass} warn=${warn} fail=${fail}"

    # Return non-zero if any hard failures found
    [[ ${fail} -eq 0 ]]
}

# ── Health check output helpers ───────────────────────────────────────────────
_hc_header() {
    echo "" >&2
    _c_bold; _c_cyan
    printf "  ════════════════════════════════════════════\n" >&2
    printf "   %s\n" "$1" >&2
    printf "  ════════════════════════════════════════════\n" >&2
    _c_reset
}

_hc_section() {
    echo "" >&2
    _c_bold; printf "  ── %s\n" "$1" >&2; _c_reset
    log "  [health] ── $1"
}

_hc_pass() {
    _c_green; printf "    ✓  %s\n" "$1" >&2; _c_reset
    log "  [health] PASS: $1"
}

_hc_warn() {
    _c_yellow; printf "    ⚠  %s\n" "$1" >&2; _c_reset
    log "  [health] WARN: $1"
}

_hc_fail() {
    local msg="$1" hint="${2:-}"
    _c_red; _c_bold; printf "    ✗  %s\n" "${msg}" >&2; _c_reset
    [[ -n "${hint}" ]] && { _c_yellow; printf "       Fix: %s\n" "${hint}" >&2; _c_reset; }
    log "  [health] FAIL: ${msg}"
    [[ -n "${hint}" ]] && log "  [health] FIX:  ${hint}"
}

_hc_hint() {
    _c_yellow; printf "       → %s\n" "$1" >&2; _c_reset
}

_hc_info() {
    printf "  %s\n" "$1" >&2
}

_hc_summary() {
    local pass="$1" warn="$2" fail="$3"
    local total=$(( pass + warn + fail ))
    echo "" >&2
    _c_bold
    printf "  ════════════════════════════════════════════\n" >&2
    printf "   Health Check Results  (%d checks)\n" "${total}" >&2
    printf "  ════════════════════════════════════════════\n" >&2
    _c_reset
    _c_green;  printf "    ✓  Pass   : %d\n" "${pass}"  >&2; _c_reset
    _c_yellow; printf "    ⚠  Warn   : %d\n" "${warn}"  >&2; _c_reset
    _c_red;    printf "    ✗  Fail   : %d\n" "${fail}"  >&2; _c_reset
    printf "  ────────────────────────────────────────────\n" >&2

    if [[ ${fail} -eq 0 && ${warn} -eq 0 ]]; then
        _c_green; _c_bold
        printf "   System looks ready to boot.\n" >&2
    elif [[ ${fail} -eq 0 ]]; then
        _c_yellow; _c_bold
        printf "   System should boot but has %d warning(s).\n" "${warn}" >&2
        printf "   Review warnings above before rebooting.\n" >&2
    else
        _c_red; _c_bold
        printf "   %d critical issue(s) found — do not reboot yet.\n" "${fail}" >&2
        printf "   Fix errors above, then re-run: arch-recovery --health-check\n" >&2
    fi
    _c_reset
    printf "   Full log: %s\n" "${LOG_FILE}" >&2
    printf "  ════════════════════════════════════════════\n" >&2
    echo "" >&2
}
