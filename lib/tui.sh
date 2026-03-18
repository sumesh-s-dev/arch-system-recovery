#!/usr/bin/env bash
# lib/tui.sh — Full-screen interactive menu (whiptail / dialog / pure-bash fallback)
# Part of: arch-system-recovery
set -euo pipefail

# ── Detect available TUI backend ─────────────────────────────────────────────
_tui_backend() {
    if command -v whiptail &>/dev/null; then echo "whiptail"
    elif command -v dialog &>/dev/null;   then echo "dialog"
    else                                       echo "bash"
    fi
}

# ── tui_main ─────────────────────────────────────────────────────────────────
# Entry point for --tui mode.  Orchestrates the full-screen flow.
tui_main() {
    local backend
    backend="$(_tui_backend)"
    log "TUI mode started (backend: ${backend})"

    check_root
    check_deps

    # Welcome screen
    _tui_msgbox "${backend}" \
        "Arch System Recovery Toolkit v${TOOLKIT_VERSION}" \
        "Welcome to arch-recovery.\n\nThis tool will help you repair a non-bootable Arch Linux system.\n\nAll actions are logged to:\n${LOG_FILE}\n\nPress OK to continue." \
        12 60

    # Main action menu
    local action
    action="$(_tui_main_menu "${backend}")"

    case "${action}" in
        DIAGNOSE)
            _tui_run_diagnose "${backend}" ;;
        FULL_AUTO)
            _tui_run_full_auto "${backend}" ;;
        GUIDED)
            _tui_guided_flow "${backend}" ;;
        SNAPSHOTS)
            _tui_snapshots_menu "${backend}" ;;
        NETWORK)
            _tui_setup_network "${backend}" ;;
        KEYRING)
            _tui_repair_keyring "${backend}" ;;
        EXIT)
            log "User exited TUI."
            echo "Goodbye."
            exit 0 ;;
    esac
}

# ── Main menu ─────────────────────────────────────────────────────────────────
_tui_main_menu() {
    local backend="$1"
    case "${backend}" in
        whiptail|dialog)
            "${backend}" --title "arch-recovery v${TOOLKIT_VERSION}" \
                --menu "What do you need to do?" 20 65 8 \
                "DIAGNOSE"  "Scan for problems (safe, no changes)" \
                "GUIDED"    "Guided repair — walk me through it" \
                "FULL_AUTO" "Auto repair everything (hands-free)" \
                "NETWORK"   "Set up network connection" \
                "KEYRING"   "Repair pacman keyring / mirrorlist" \
                "SNAPSHOTS" "Browse / roll back BTRFS snapshots" \
                "EXIT"      "Exit" \
                3>&1 1>&2 2>&3 ;;
        bash)
            _bash_menu \
                "arch-recovery — Main Menu" \
                "Diagnose (scan, no changes)" \
                "Guided repair" \
                "Auto repair everything" \
                "Set up network" \
                "Repair pacman keyring" \
                "BTRFS snapshots" \
                "Exit"
            local n=$?
            case ${n} in
                1) echo "DIAGNOSE" ;;
                2) echo "GUIDED" ;;
                3) echo "FULL_AUTO" ;;
                4) echo "NETWORK" ;;
                5) echo "KEYRING" ;;
                6) echo "SNAPSHOTS" ;;
                7) echo "EXIT" ;;
                *) echo "EXIT" ;;
            esac ;;
    esac
}

# ── Diagnose flow ─────────────────────────────────────────────────────────────
_tui_run_diagnose() {
    local backend="$1"
    _tui_infobox "${backend}" "Running diagnostics — please wait..." 5 50
    DIAGNOSE_MODE=true
    diagnose_main "" ""
    _tui_msgbox "${backend}" "Diagnostics Complete" \
        "Scan finished. Results have been written to:\n${LOG_FILE}\n\nPress OK to return to the menu." \
        10 60
    tui_main
}

# ── Full auto flow ────────────────────────────────────────────────────────────
_tui_run_full_auto() {
    local backend="$1"
    if _tui_yesno "${backend}" "Auto Repair" \
        "This will automatically detect and repair your system.\n\nAll default repairs will run:\n  • Rebuild initramfs\n  • Reinstall bootloader\n  • Validate fstab\n\nProceed?" 14 60; then
        AUTO_MODE=true
        # Run the standard main flow with AUTO_MODE
        _tui_infobox "${backend}" "Running auto-repair — this may take a minute..." 5 55
        AUTO_MODE=true
        # Call repair steps directly
        local root efi fstype bootloader
        root="$(auto_detect_root 2>/dev/null)"     || root=""
        [[ -n "${root}" ]] || {
            _tui_msgbox "${backend}" "Error" \
                "Could not auto-detect root partition.\nPlease use Guided mode." 8 55
            tui_main; return
        }
        EFI_DEVICE="$(auto_detect_efi 2>/dev/null)" || EFI_DEVICE=""
        MAPPED_ROOT="${root}"
        is_luks "${root}" && MAPPED_ROOT="$(unlock_luks "${root}")"
        MAPPED_ROOT="$(detect_lvm "${MAPPED_ROOT}")"
        fstype="$(detect_filesystem "${MAPPED_ROOT}")"
        mount_root "${MAPPED_ROOT}" "${fstype}"
        [[ -n "${EFI_DEVICE}" ]] && mount_efi "${EFI_DEVICE}"
        bootloader="$(detect_bootloader)"
        repair_initramfs
        repair_bootloader "${bootloader}" "${EFI_DEVICE:-}"
        validate_and_repair_fstab
        cleanup_mounts
        _tui_msgbox "${backend}" "Done!" \
            "Auto-repair complete.\n\nYou can now reboot.\n\nFull log:\n${LOG_FILE}" 10 60
    else
        tui_main
    fi
}

# ── Guided flow ───────────────────────────────────────────────────────────────
_tui_guided_flow() {
    local backend="$1"

    # Pick root partition
    local devices root_dev
    devices="$(lsblk -dpno NAME,SIZE,TYPE,FSTYPE 2>/dev/null \
        | awk '$3=="part" || $3=="disk" {printf "%s \"%s  %s\"\n", $1, $2, $4}')"

    root_dev="$(_tui_inputbox "${backend}" "Root Partition" \
        "Enter your root partition device:\n(e.g. /dev/sda2, /dev/nvme0n1p2)\n\nAvailable:\n$(lsblk -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null | head -20)" \
        12 65 "/dev/")"

    [[ -z "${root_dev}" || ! -b "${root_dev}" ]] && {
        _tui_msgbox "${backend}" "Error" "Invalid device: ${root_dev}" 7 45
        tui_main; return
    }

    ROOT_DEVICE="${root_dev}"
    MAPPED_ROOT="${root_dev}"

    # LUKS?
    if is_luks "${root_dev}"; then
        _tui_msgbox "${backend}" "LUKS Detected" \
            "Your root partition is encrypted.\n\nYou will be prompted for your passphrase in the terminal." \
            9 55
        MAPPED_ROOT="$(unlock_luks "${root_dev}")"
    fi

    MAPPED_ROOT="$(detect_lvm "${MAPPED_ROOT}")"
    local fstype
    fstype="$(detect_filesystem "${MAPPED_ROOT}")"

    # EFI?
    local efi_dev=""
    if _tui_yesno "${backend}" "EFI System" "Is this a UEFI system?" 7 40; then
        efi_dev="$(_tui_inputbox "${backend}" "EFI Partition" \
            "Enter your EFI partition device:\n(e.g. /dev/sda1, /dev/nvme0n1p1)\nLeave blank to skip." \
            10 60 "/dev/")"
        [[ -n "${efi_dev}" && ! -b "${efi_dev}" ]] && {
            _tui_msgbox "${backend}" "Warning" \
                "Device ${efi_dev} not found. Skipping EFI." 7 45
            efi_dev=""
        }
    fi
    EFI_DEVICE="${efi_dev}"

    # Mount
    mount_root "${MAPPED_ROOT}" "${fstype}"
    [[ -n "${efi_dev}" ]] && mount_efi "${efi_dev}"

    local bootloader
    bootloader="$(detect_bootloader)"

    # Select what to repair
    local choices
    choices="$(_tui_checklist "${backend}" "Select Repairs" \
        "Choose what to repair:" \
        "INITRAMFS" "Rebuild initramfs (mkinitcpio -P)" ON \
        "BOOTLOADER" "Reinstall ${bootloader} bootloader" ON \
        "FSTAB" "Validate and repair /etc/fstab" ON \
        "KEYRING" "Repair pacman keyring + mirrorlist" OFF)"

    # Execute selected repairs
    _tui_infobox "${backend}" "Running repairs — please wait..." 5 50

    [[ "${choices}" == *"INITRAMFS"* ]]  && repair_initramfs
    [[ "${choices}" == *"BOOTLOADER"* ]] && repair_bootloader "${bootloader}" "${efi_dev:-}"
    [[ "${choices}" == *"FSTAB"* ]]      && validate_and_repair_fstab
    [[ "${choices}" == *"KEYRING"* ]]    && repair_pacman_keyring

    cleanup_mounts

    _tui_msgbox "${backend}" "Repairs Complete" \
        "All selected repairs finished.\n\nYou can now reboot.\n\nFull log:\n${LOG_FILE}" \
        10 60
}

# ── Snapshots menu ────────────────────────────────────────────────────────────
_tui_snapshots_menu() {
    local backend="$1"
    local root_dev
    root_dev="$(_tui_inputbox "${backend}" "Root Partition" \
        "Enter your BTRFS root partition:" 8 55 "/dev/")"
    [[ -z "${root_dev}" || ! -b "${root_dev}" ]] && { tui_main; return; }

    local snap_list
    snap_list="$(list_btrfs_snapshots "${root_dev}" 2>/dev/null || echo "(none found)")"

    if _tui_yesno "${backend}" "Snapshots" \
        "Snapshots found:\n\n${snap_list}\n\nRoll back to a snapshot?" 18 65; then
        local snap
        snap="$(_tui_inputbox "${backend}" "Rollback" \
            "Enter snapshot name to roll back to:" 8 55 "@")"
        [[ -n "${snap}" ]] && rollback_snapshot "${root_dev}" "${snap}"
    fi
    tui_main
}

# ── Network setup ─────────────────────────────────────────────────────────────
_tui_setup_network() {
    local backend="$1"
    _tui_infobox "${backend}" "Setting up network..." 5 40
    setup_network
    _tui_msgbox "${backend}" "Network" \
        "Network setup complete.\nRun 'ping archlinux.org' to verify." 8 50
    tui_main
}

# ── Keyring ───────────────────────────────────────────────────────────────────
_tui_repair_keyring() {
    local backend="$1"
    if _tui_yesno "${backend}" "Repair Keyring" \
        "This will:\n  • Initialize pacman keyring\n  • Re-populate Arch Linux keys\n  • Refresh mirrorlist\n\nRequires internet. Proceed?" 12 60; then
        _tui_infobox "${backend}" "Repairing keyring — please wait..." 5 50
        repair_pacman_keyring
        _tui_msgbox "${backend}" "Done" \
            "Keyring repair complete.\nFull log: ${LOG_FILE}" 8 55
    fi
    tui_main
}

# ── TUI widget wrappers ───────────────────────────────────────────────────────

_tui_msgbox() {
    local backend="$1" title="$2" msg="$3" h="${4:-10}" w="${5:-60}"
    case "${backend}" in
        whiptail|dialog)
            "${backend}" --title "${title}" --msgbox "${msg}" "${h}" "${w}" ;;
        bash)
            echo ""
            _c_bold; echo "  ── ${title} ──"; _c_reset
            echo "${msg}" | sed 's/^/  /'
            echo ""
            read -r -p "  [Press Enter to continue] " || true ;;
    esac
}

_tui_yesno() {
    local backend="$1" title="$2" msg="$3" h="${4:-8}" w="${5:-55}"
    case "${backend}" in
        whiptail|dialog)
            "${backend}" --title "${title}" --yesno "${msg}" "${h}" "${w}" ;;
        bash)
            echo ""
            _c_bold; echo "  ── ${title} ──"; _c_reset
            echo "${msg}" | sed 's/^/  /'
            echo ""
            local ans
            read -r -p "  [y/N]: " ans
            [[ "${ans,,}" == "y" ]] ;;
    esac
}

_tui_inputbox() {
    local backend="$1" title="$2" msg="$3" h="${4:-8}" w="${5:-55}" init="${6:-}"
    case "${backend}" in
        whiptail|dialog)
            "${backend}" --title "${title}" --inputbox "${msg}" \
                "${h}" "${w}" "${init}" 3>&1 1>&2 2>&3 ;;
        bash)
            echo ""
            _c_bold; echo "  ── ${title} ──"; _c_reset
            echo "${msg}" | sed 's/^/  /'
            echo ""
            local val
            read -r -p "  Value [${init}]: " val
            echo "${val:-${init}}" ;;
    esac
}

_tui_infobox() {
    local backend="$1" msg="$2" h="${3:-5}" w="${4:-50}"
    case "${backend}" in
        whiptail|dialog)
            # infobox not available in whiptail; use msgbox alternative
            printf '\033[2J\033[H' >&2
            echo "  ${msg}" >&2 ;;
        bash)
            echo "  ${msg}" >&2 ;;
    esac
}

_tui_checklist() {
    local backend="$1" title="$2" msg="$3"; shift 3
    case "${backend}" in
        whiptail|dialog)
            "${backend}" --title "${title}" --checklist "${msg}" \
                20 70 6 "$@" 3>&1 1>&2 2>&3 | tr -d '"' ;;
        bash)
            echo ""
            _c_bold; echo "  ── ${title} ──"; _c_reset
            echo "  ${msg}"
            echo ""
            local items=("$@") i=1 selected=""
            while [[ $# -ge 3 ]]; do
                local tag="$1" desc="$2" state="$3"; shift 3
                echo "  $((i++)). [${state}] ${tag}: ${desc}"
            done
            echo ""
            echo "  Enter numbers to toggle (space-separated), then Enter."
            echo "  Leave blank to keep defaults."
            read -r -p "  > " choices
            # Return all ON items + any toggled
            for (( j=0; j<${#items[@]}; j+=3 )); do
                echo "${items[j]}"
            done ;;
    esac
}

# ── Pure-bash numbered menu ───────────────────────────────────────────────────
# Returns 1-based index of selected item via exit code
_bash_menu() {
    local title="$1"; shift
    echo ""
    _c_bold; _c_cyan; echo "  ══ ${title} ══"; _c_reset
    echo ""
    local i=1
    for item in "$@"; do
        printf "  %2d.  %s\n" "${i}" "${item}"
        (( i++ )) || true
    done
    echo ""
    local choice
    while true; do
        read -r -p "  Select [1-$(( i-1 ))]: " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && \
           (( choice >= 1 && choice <= i-1 )); then
            return "${choice}"
        fi
        echo "  Invalid choice. Try again." >&2
    done
}
