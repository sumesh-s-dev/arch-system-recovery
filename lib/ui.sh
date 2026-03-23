#!/usr/bin/env bash
# lib/ui.sh — interactive prompts, confirmation dialogs, banner
# Part of: arch-system-recovery
# Note: colour helpers (_c_bold, _c_reset, etc.) are defined in core.sh
set -euo pipefail

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    [[ "${LOG_LEVEL:-normal}" == "silent" ]] && return 0
    echo "" >&2
    _c_bold; _c_cyan
    cat >&2 <<'BANNER'
   ___              __       ___                                    
  / _ | _________  / /  __  / _ \___ _______  _  _____ ______ __  
 / __ |/ __/ __/ _ \ / _ \/ , _/ -_) __/ _ \| |/ / -_) __/ // /  
/_/ |_/_/  \__/_//_/\___/_/|_|\__/\__/\___/|___/\__/_/  \_, /   
                                                         /___/    
BANNER
    _c_reset
    _c_bold
    printf "  Arch System Recovery Toolkit v%s\n" "${TOOLKIT_VERSION}" >&2
    _c_reset
    printf "  Log: %s\n\n" "${LOG_FILE}" >&2
}

# ── print_step ────────────────────────────────────────────────────────────────
print_step() {
    local num="$1" desc="$2"
    [[ "${LOG_LEVEL:-normal}" == "silent" ]] && return 0
    echo "" >&2
    _c_bold; _c_cyan; printf "  ── Step %-3s %s\n" "${num}" "${desc}" >&2; _c_reset
    log "Step ${num}: ${desc}"
}

# ── prompt_root_device ────────────────────────────────────────────────────────
prompt_root_device() {
    echo "" >&2
    _c_bold; echo "  Available block devices:" >&2; _c_reset
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID,MOUNTPOINT 2>/dev/null >&2 || true
    echo "" >&2
    _c_yellow; printf "  Root partition (e.g. /dev/sda2): " >&2; _c_reset

    local dev
    read -r dev

    [[ -z "${dev}" ]] && die "No root partition entered."
    [[ ! -b "${dev}" ]] && die "Device '${dev}' does not exist or is not a block device."
    echo "${dev}"
}

# ── prompt_efi_device ─────────────────────────────────────────────────────────
prompt_efi_device() {
    echo "" >&2
    _c_yellow; printf "  UEFI system? [Y/n]: " >&2; _c_reset
    local ans; read -r ans; ans="${ans:-Y}"
    [[ "${ans}" =~ ^[Nn]$ ]] && { echo ""; return 0; }

    _c_yellow; printf "  EFI partition (leave blank to skip): " >&2; _c_reset
    local dev; read -r dev

    if [[ -n "${dev}" && ! -b "${dev}" ]]; then
        warn "Device '${dev}' not found — skipping EFI mount"
        echo ""; return 0
    fi
    echo "${dev}"
}

# ── prompt_bootloader_choice ──────────────────────────────────────────────────
prompt_bootloader_choice() {
    echo "" >&2
    _c_yellow; echo "  Could not detect bootloader automatically." >&2; _c_reset
    echo "  1) GRUB (UEFI)" >&2
    echo "  2) systemd-boot" >&2
    _c_yellow; printf "  Select [1/2]: " >&2; _c_reset
    local c; read -r c
    case "${c}" in
        1) echo "grub" ;;
        2) echo "systemd-boot" ;;
        *) die "Invalid selection: ${c}" ;;
    esac
}

# ── confirm_repair ────────────────────────────────────────────────────────────
# Extended signature:
#   $1 root_dev  $2 efi_dev  $3 fstype  $4 bootloader
#   $5 do_initramfs  $6 do_bootloader  $7 do_fstab  $8 do_keyring
confirm_repair() {
    local root="${1}" efi="${2}" fs="${3}" bl="${4}"
    local do_ini="${5:-true}" do_bl="${6:-true}"
    local do_fs="${7:-true}" do_kr="${8:-false}"

    echo "" >&2
    _c_bold; printf "  ══ RECOVERY PLAN ══════════════════════════════\n" >&2; _c_reset
    printf "  Root device    : %s\n" "${root}" >&2
    printf "  EFI device     : %s\n" "${efi}"  >&2
    printf "  Filesystem     : %s\n" "${fs}"   >&2
    printf "  Bootloader     : %s\n" "${bl}"   >&2
    echo "" >&2
    _c_bold; printf "  Actions:\n" >&2; _c_reset

    local step=1
    printf "    %d. Mount root at %s\n" $((step++)) "${MOUNT_ROOT}" >&2
    [[ "${efi}" != "none" && -n "${efi}" ]] && \
        printf "    %d. Mount EFI partition\n" $((step++)) >&2
    printf "    %d. Bind-mount /dev /proc /sys /run\n" $((step++)) >&2
    ${do_fs}  && printf "    %d. Validate /etc/fstab\n"         $((step++)) >&2
    ${do_kr}  && printf "    %d. Repair pacman keyring\n"       $((step++)) >&2
    ${do_ini} && printf "    %d. Rebuild initramfs (mkinitcpio -P)\n" $((step++)) >&2
    ${do_bl}  && printf "    %d. Reinstall %s bootloader\n"    $((step++)) "${bl}" >&2

    _c_bold; printf "  ═══════════════════════════════════════════════\n" >&2; _c_reset
    echo "" >&2
    _c_red; _c_bold
    printf "  ⚠  This will modify your system. Type 'yes' to proceed: " >&2
    _c_reset

    local ans; read -r ans
    if [[ "${ans}" != "yes" ]]; then
        log "User aborted at confirmation prompt."
        echo "" >&2; echo "  Aborted — no changes made." >&2
        exit 0
    fi
    log "User confirmed recovery plan."
}

confirm_snapshot_rollback() {
    local root="${1}" mapped_root="${2}" snapshot="${3}"

    echo "" >&2
    _c_bold; printf "  ══ SNAPSHOT ROLLBACK ═══════════════════════════\n" >&2; _c_reset
    printf "  Root device    : %s\n" "${root}" >&2
    printf "  Working device : %s\n" "${mapped_root}" >&2
    printf "  Snapshot       : %s\n" "${snapshot}" >&2
    echo "" >&2
    echo "  This will rename the current BTRFS root subvolume and replace it" >&2
    echo "  with a writable copy of the selected snapshot." >&2
    echo "" >&2
    _c_red; _c_bold
    printf "  Type 'rollback' to proceed: " >&2
    _c_reset

    local ans; read -r ans
    if [[ "${ans}" != "rollback" ]]; then
        log "User aborted snapshot rollback."
        echo "" >&2
        echo "  Aborted — no changes made." >&2
        exit 0
    fi
    log "User confirmed snapshot rollback to ${snapshot}."
}
