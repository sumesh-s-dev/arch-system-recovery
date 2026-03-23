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

_tui_exec_cli() {
    log "TUI handoff to CLI: $*"
    exec bash "${REPO_ROOT}/bin/arch-recovery" "$@"
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
    _tui_infobox "${backend}" "Handing off to the standard diagnose flow..." 5 56
    _tui_exec_cli --diagnose
}

# ── Full auto flow ────────────────────────────────────────────────────────────
_tui_run_full_auto() {
    local backend="$1"
    if _tui_yesno "${backend}" "Auto Repair" \
        "This will automatically detect and repair your system.\n\nAll default repairs will run:\n  • Rebuild initramfs\n  • Reinstall bootloader\n  • Validate fstab\n\nProceed?" 14 60; then
        _tui_infobox "${backend}" "Handing off to the standard auto-repair flow..." 5 58
        _tui_exec_cli --auto
    else
        tui_main
    fi
}

# ── Guided flow ───────────────────────────────────────────────────────────────
_tui_guided_flow() {
    local backend="$1"

    # Pick root partition
    local root_dev
    root_dev="$(_tui_inputbox "${backend}" "Root Partition" \
        "Enter your root partition device:\n(e.g. /dev/sda2, /dev/nvme0n1p2)\n\nAvailable:\n$(lsblk -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null | head -20)" \
        12 65 "/dev/")"

    [[ -z "${root_dev}" || ! -b "${root_dev}" ]] && {
        _tui_msgbox "${backend}" "Error" "Invalid device: ${root_dev}" 7 45
        tui_main; return
    }

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

    # Select what to repair
    local choices
    choices="$(_tui_checklist "${backend}" "Select Repairs" \
        "Choose what to repair:" \
        "INITRAMFS" "Rebuild initramfs (mkinitcpio -P)" ON \
        "BOOTLOADER" "Reinstall the detected bootloader" ON \
        "FSTAB" "Validate and repair /etc/fstab" ON \
        "KEYRING" "Repair pacman keyring + mirrorlist" OFF)"

    local -a args=("--root" "${root_dev}")
    [[ -n "${efi_dev}" ]] && args+=("--efi" "${efi_dev}")
    [[ "${choices}" == *"INITRAMFS"* ]]  || args+=("--no-initramfs")
    [[ "${choices}" == *"BOOTLOADER"* ]] || args+=("--no-bootloader")
    [[ "${choices}" == *"FSTAB"* ]]      || args+=("--no-fstab")
    [[ "${choices}" == *"KEYRING"* ]]    && args+=("--repair-keyring")

    _tui_infobox "${backend}" "Handing off to the standard guided repair flow..." 5 60
    _tui_exec_cli "${args[@]}"
}

# ── Snapshots menu ────────────────────────────────────────────────────────────
_tui_snapshots_menu() {
    local backend="$1"
    local root_dev
    root_dev="$(_tui_inputbox "${backend}" "Root Partition" \
        "Enter your BTRFS root partition:" 8 55 "/dev/")"
    [[ -z "${root_dev}" || ! -b "${root_dev}" ]] && { tui_main; return; }

    if _tui_yesno "${backend}" "Snapshots" \
        "List snapshots first?\n\nChoose 'No' if you already know which snapshot to roll back to." 10 60; then
        _tui_infobox "${backend}" "Handing off to the snapshot listing flow..." 5 54
        _tui_exec_cli --list-snapshots --root "${root_dev}"
    else
        local snap
        snap="$(_tui_inputbox "${backend}" "Rollback" \
            "Enter snapshot name to roll back to:" 8 55 "@")"
        [[ -n "${snap}" ]] && {
            _tui_infobox "${backend}" "Handing off to the snapshot rollback flow..." 5 56
            _tui_exec_cli --rollback "${snap}" --root "${root_dev}"
        }
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
        _tui_infobox "${backend}" "Handing off to the standard keyring repair flow..." 5 60
        _tui_exec_cli --repair-keyring --no-initramfs --no-bootloader --no-fstab
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
            local items=("$@") i=1
            local tags=() states=()
            while [[ $# -ge 3 ]]; do
                local tag="$1" desc="$2" state="$3"; shift 3
                tags+=("${tag}")
                states+=("${state}")
                echo "  $((i++)). [${state}] ${tag}: ${desc}"
            done
            echo ""
            echo "  Enter numbers to toggle (space-separated), then Enter."
            echo "  Leave blank to keep defaults."
            read -r -p "  > " choices
            local selected=()
            for (( j=0; j<${#tags[@]}; j++ )); do
                [[ "${states[j]}" == "ON" ]] && selected+=("${tags[j]}")
            done

            for choice in ${choices:-}; do
                [[ "${choice}" =~ ^[0-9]+$ ]] || continue
                (( choice >= 1 && choice <= ${#tags[@]} )) || continue
                local idx=$(( choice - 1 ))
                local tag="${tags[idx]}"
                local present=false
                local updated=()
                for item in "${selected[@]}"; do
                    if [[ "${item}" == "${tag}" ]]; then
                        present=true
                    else
                        updated+=("${item}")
                    fi
                done
                if ${present}; then
                    selected=("${updated[@]}")
                else
                    selected+=("${tag}")
                fi
            done

            for item in "${selected[@]}"; do
                echo "${item}"
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
