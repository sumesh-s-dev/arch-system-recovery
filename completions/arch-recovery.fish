# completions/arch-recovery.fish — fish shell tab-completion for arch-recovery
#
# Installation:
#   cp arch-recovery.fish ~/.config/fish/completions/arch-recovery.fish
#   # Fish loads it automatically on next shell start

# Disable file completion for this command by default
complete -c arch-recovery -f

# ── Helper: generate block device list ────────────────────────────────────────
function __arch_recovery_devices
    lsblk -dpno NAME 2>/dev/null
    ls /dev/mapper/ 2>/dev/null | sed 's|^|/dev/mapper/|'
end

# ── Mode flags ────────────────────────────────────────────────────────────────
complete -c arch-recovery -l auto       -d "Non-interactive: auto-detect and repair"
complete -c arch-recovery -l dry-run    -d "Simulate all actions; nothing written"
complete -c arch-recovery -l tui        -d "Full-screen menu (whiptail/dialog)"
complete -c arch-recovery -l diagnose   -d "Scan only; zero changes made"

# ── Device flags ──────────────────────────────────────────────────────────────
complete -c arch-recovery -l root -r \
    -d "Root partition" \
    -a "(__arch_recovery_devices)"

complete -c arch-recovery -l boot -r \
    -d "Separate /boot partition" \
    -a "(__arch_recovery_devices)"

complete -c arch-recovery -l efi -r \
    -d "EFI partition" \
    -a "(__arch_recovery_devices)"

# ── Selective repair flags ────────────────────────────────────────────────────
complete -c arch-recovery -l no-initramfs   -d "Skip mkinitcpio rebuild"
complete -c arch-recovery -l no-bootloader  -d "Skip bootloader reinstall"
complete -c arch-recovery -l no-fstab       -d "Skip fstab validation"
complete -c arch-recovery -l repair-keyring -d "Repair pacman keyring + mirrorlist"
complete -c arch-recovery -l setup-network  -d "Configure network first"

# ── BTRFS snapshot flags ──────────────────────────────────────────────────────
complete -c arch-recovery -l list-snapshots -d "List BTRFS snapshots"
complete -c arch-recovery -l rollback -r    -d "Roll back to named BTRFS snapshot"
complete -c arch-recovery -l health-check   -d "Verify system readiness without repairing"
complete -c arch-recovery -l update         -d "Install the latest verified release bundle"
complete -c arch-recovery -l check-update   -d "Check for a newer release"

# ── Verbosity flags ───────────────────────────────────────────────────────────
complete -c arch-recovery -l log-level -r \
    -d "Verbosity level" \
    -a "silent\t'Errors only' normal\t'Default' verbose\t'Extra detail' debug\t'Trace all commands'"

complete -c arch-recovery -s v -l verbose   -d "Extra detail"
complete -c arch-recovery -l debug          -d "Trace every command"
complete -c arch-recovery -s q -l silent    -d "Errors only"

# ── Info flags ────────────────────────────────────────────────────────────────
complete -c arch-recovery -s h -l help      -d "Show help message"
complete -c arch-recovery -l version        -d "Show version number"
complete -c arch-recovery -l changelog      -d "Show changelog"
