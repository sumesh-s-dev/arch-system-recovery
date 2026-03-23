#!/usr/bin/env bash
# lib/preflight.sh — pre-repair sanity checks
# Checks are non-destructive; failures warn but only critical ones abort.
set -euo pipefail

# ── run_preflight ─────────────────────────────────────────────────────────────
# Runs all preflight checks and reports results.
# Arguments: $1=mapped_root_dev  $2=efi_dev_or_empty  $3=fstype
run_preflight() {
    local root="${1}"
    local efi="${2:-}"
    local fstype="${3}"
    local boot_dev=""
    local efi_mountpoint=""
    local warnings=0 errors=0

    log "Running pre-flight checks..."
    echo "" >&2

    # ── Check: mount point exists ─────────────────────────────────────────────
    _pf_check "Mount point exists" \
        "[ -d '${MOUNT_ROOT}' ] || mkdir -p '${MOUNT_ROOT}'" \
        "non-fatal"

    # ── Check: root is mounted ────────────────────────────────────────────────
    if mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
        _pf_ok  "Root filesystem is mounted at ${MOUNT_ROOT}"
    else
        _pf_warn "Root filesystem not yet mounted — will mount in next step"
        (( warnings++ )) || true
    fi

    # ── Check: separate /boot mounted when expected ───────────────────────────
    boot_dev="$(detect_boot_device "${MOUNT_ROOT}" 2>/dev/null || true)"
    if [[ -n "${boot_dev}" ]]; then
        if mountpoint -q "${MOUNT_ROOT}/boot" 2>/dev/null; then
            _pf_ok "Separate /boot partition mounted"
        else
            _pf_err "/boot exists in /etc/fstab but is not mounted" \
                    "Mount the /boot device before rebuilding initramfs or the bootloader"
            (( errors++ )) || true
        fi
    fi

    # ── Check: EFI partition mounted (if UEFI) ────────────────────────────────
    efi_mountpoint="$(detect_fstab_efi_mountpoint "${MOUNT_ROOT}" 2>/dev/null || true)"
    if [[ -n "${efi}" || -n "${efi_mountpoint}" ]]; then
        if [[ -z "${efi_mountpoint}" ]]; then
            if mountpoint -q "${MOUNT_ROOT}/boot/efi" 2>/dev/null || \
               mountpoint -q "${MOUNT_ROOT}/efi"      2>/dev/null || \
               [[ "$(findmnt -n -o FSTYPE "${MOUNT_ROOT}/boot" 2>/dev/null || true)" == "vfat" ]]; then
                _pf_ok "EFI partition mounted"
            else
                _pf_warn "EFI partition not yet mounted"
                (( warnings++ )) || true
            fi
        elif mountpoint -q "${MOUNT_ROOT}${efi_mountpoint}" 2>/dev/null; then
            _pf_ok  "EFI partition mounted"
        else
            _pf_warn "EFI partition not yet mounted"
            (( warnings++ )) || true
        fi
    fi

    # ── Check: kernel image present ───────────────────────────────────────────
    if mountpoint -q "${MOUNT_ROOT}" 2>/dev/null; then
        local kernel_count
        kernel_count="$(find "${MOUNT_ROOT}/boot" -maxdepth 1 \
            -name 'vmlinuz-*' 2>/dev/null | wc -l)"
        if [[ "${kernel_count}" -ge 1 ]]; then
            _pf_ok  "Kernel image found in /boot (${kernel_count} present)"
        else
            _pf_err "No kernel image found in ${MOUNT_ROOT}/boot" \
                    "Install a kernel: pacman -S linux linux-lts"
            (( errors++ )) || true
        fi

        # ── Check: mkinitcpio.conf exists ─────────────────────────────────────
        if [[ -f "${MOUNT_ROOT}/etc/mkinitcpio.conf" ]]; then
            _pf_ok  "/etc/mkinitcpio.conf exists"
        else
            _pf_err "/etc/mkinitcpio.conf missing" \
                    "Reinstall mkinitcpio: pacman -S mkinitcpio"
            (( errors++ )) || true
        fi

        # ── Check: required hooks in mkinitcpio.conf ──────────────────────────
        if [[ -f "${MOUNT_ROOT}/etc/mkinitcpio.conf" ]]; then
            if grep -q 'HOOKS=' "${MOUNT_ROOT}/etc/mkinitcpio.conf"; then
                _pf_ok  "mkinitcpio HOOKS line found"
            else
                _pf_warn "mkinitcpio.conf has no HOOKS line — may be malformed"
                (( warnings++ )) || true
            fi
        fi

        # ── Check: /etc/locale.gen exists ─────────────────────────────────────
        [[ -f "${MOUNT_ROOT}/etc/locale.gen" ]] \
            && _pf_ok  "/etc/locale.gen found" \
            || _pf_warn "/etc/locale.gen not found — locale may be unconfigured"

        # ── Check: /etc/hostname ──────────────────────────────────────────────
        [[ -f "${MOUNT_ROOT}/etc/hostname" ]] \
            && _pf_ok  "Hostname: $(cat "${MOUNT_ROOT}/etc/hostname" 2>/dev/null)" \
            || _pf_warn "/etc/hostname missing — system may have no hostname set"
    fi

    # ── Check: BTRFS tools available for BTRFS systems ────────────────────────
    if [[ "${fstype}" == "btrfs" ]]; then
        if command -v btrfs &>/dev/null; then
            _pf_ok  "btrfs-progs found"
        else
            _pf_warn "btrfs-progs not found — BTRFS operations may fail"
            echo "     Install: pacman -S btrfs-progs" >&2
            (( warnings++ )) || true
        fi
    fi

    # ── Check: disk space on live system ─────────────────────────────────────
    local free_mb
    free_mb="$(df -m /tmp 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "${free_mb}" ]] && (( free_mb >= 100 )); then
        _pf_ok  "Sufficient free space in /tmp (${free_mb} MiB)"
    else
        _pf_warn "Low disk space in /tmp (${free_mb:-unknown} MiB)"
        (( warnings++ )) || true
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo "" >&2
    if [[ ${errors} -gt 0 ]]; then
        _c_red; log "Pre-flight: ${errors} error(s), ${warnings} warning(s)"; _c_reset
        die "Pre-flight checks failed. Resolve errors above before continuing."
    elif [[ ${warnings} -gt 0 ]]; then
        _c_yellow; log "Pre-flight: ${warnings} warning(s) — proceeding with caution"; _c_reset
    else
        _c_green; log "Pre-flight: all checks passed"; _c_reset
    fi
}

# ── Preflight output helpers ──────────────────────────────────────────────────
_pf_ok() {
    local msg="$1"
    log "  [preflight] ✓ ${msg}"
    _tty && { _c_green; printf "    ✓  %s\n" "${msg}" >&2; _c_reset; } || true
}

_pf_warn() {
    local msg="$1"
    log "  [preflight] ⚠ WARN: ${msg}"
    _tty && { _c_yellow; printf "    ⚠  %s\n" "${msg}" >&2; _c_reset; } || true
}

_pf_err() {
    local msg="$1"
    local hint="${2:-}"
    log "  [preflight] ✗ ERROR: ${msg}"
    _tty && { _c_red; printf "    ✗  %s\n" "${msg}" >&2; _c_reset; } || true
    [[ -n "${hint}" ]] && printf "       Hint: %s\n" "${hint}" >&2 || true
}

_pf_check() {
    local label="$1" cmd="$2"
    if eval "${cmd}" &>/dev/null; then
        _pf_ok "${label}"
    else
        _pf_warn "${label} — check failed (non-critical)"
    fi
}
