#!/usr/bin/env bash
# completions/arch-recovery.bash — bash tab-completion for arch-recovery
#
# Installation (choose one):
#   # System-wide (requires root):
#   sudo cp arch-recovery.bash /etc/bash_completion.d/arch-recovery
#
#   # Per-user:
#   cp arch-recovery.bash ~/.local/share/bash-completion/completions/arch-recovery
#
#   # One-liner in ~/.bashrc:
#   source /path/to/completions/arch-recovery.bash

_arch_recovery_complete() {
    local cur prev words cword
    # Use _init_completion if available (bash-completion package), else manual
    if declare -f _init_completion &>/dev/null; then
        _init_completion || return
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    fi

    # Flags that take a device argument
    local device_flags="--root --efi"
    # Flags that take a string argument
    local arg_flags="--log-level --rollback"

    # If previous word expects a device, complete block devices
    if [[ "${device_flags}" == *"${prev}"* ]]; then
        local devices
        devices="$(lsblk -dpno NAME 2>/dev/null)"
        # Also include /dev/mapper/* for LUKS
        mapfile -t COMPREPLY < <(compgen -W "${devices} $(ls /dev/mapper/ 2>/dev/null \
            | sed 's|^|/dev/mapper/|')" -- "${cur}")
        return 0
    fi

    # --log-level completion
    if [[ "${prev}" == "--log-level" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "silent normal verbose debug" -- "${cur}")
        return 0
    fi

    # --rollback: we can't easily complete snapshot names without mounting,
    # so offer a helpful placeholder
    if [[ "${prev}" == "--rollback" ]]; then
        mapfile -t COMPREPLY < <(compgen -W "@snapshots @pre-update @backup" -- "${cur}")
        return 0
    fi

    # All available flags
    local all_flags="
        --auto
        --dry-run
        --tui
        --diagnose
        --root
        --efi
        --no-initramfs
        --no-bootloader
        --no-fstab
        --repair-keyring
        --setup-network
        --list-snapshots
        --rollback
        --log-level
        --verbose
        --debug
        --silent
        --help
        --version
        --changelog
    "

    # Filter already-used flags (avoid duplicates)
    local used_flags=" ${COMP_WORDS[*]} "
    local available_flags=""
    for flag in ${all_flags}; do
        if [[ "${used_flags}" != *" ${flag} "* ]]; then
            available_flags+=" ${flag}"
        fi
    done

    mapfile -t COMPREPLY < <(compgen -W "${available_flags}" -- "${cur}")
    return 0
}

complete -F _arch_recovery_complete arch-recovery
