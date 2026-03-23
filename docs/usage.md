# Usage Guide

## Prerequisites

1. Boot the [Arch Linux ISO](https://archlinux.org/download/) from USB
2. Clone or copy this repository:

```bash
git clone https://github.com/sumesh-s-dev/arch-system-recovery.git
cd arch-system-recovery
chmod +x bin/arch-recovery
```

---

## I don't know what's wrong — start here

```bash
sudo ./bin/arch-recovery --diagnose
```

This scans your system read-only and prints a colour-coded report of every
problem it finds, along with the exact command that fixes each one. Nothing
is changed.

---

## Fully interactive — walk me through it

```bash
sudo ./bin/arch-recovery
```

The tool detects your hardware, lists your block devices, asks a few
questions, shows you a repair plan, waits for you to type `yes`, then
performs all repairs.

---

## Full-screen menu — I prefer a GUI-style interface

```bash
sudo ./bin/arch-recovery --tui
```

Uses `whiptail` or `dialog` if installed (both available on the Arch ISO).
Falls back to a numbered bash menu if neither is found.

---

## Automatic — just fix everything

```bash
sudo ./bin/arch-recovery --auto
```

No prompts. Auto-detects root partition, EFI partition, filesystem type,
and bootloader, then performs all repairs.

---

## Preview — what would happen?

```bash
sudo ./bin/arch-recovery --dry-run --verbose
```

Logs every planned action in full detail. Nothing is written to disk.

---

## Manual partition specification

When auto-detection gets it wrong, or on unusual partition layouts:

```bash
# Root only (EFI will be prompted interactively)
sudo ./bin/arch-recovery --root /dev/sda2

# Root + separate /boot + EFI
sudo ./bin/arch-recovery --root /dev/sda2 --boot /dev/sda1 --efi /dev/sda3

# Both root and EFI
sudo ./bin/arch-recovery --root /dev/sda2 --efi /dev/sda1

# NVMe
sudo ./bin/arch-recovery --root /dev/nvme0n1p2 --efi /dev/nvme0n1p1

# Auto mode with explicit devices (no prompts at all)
sudo ./bin/arch-recovery --auto --root /dev/sda2 --efi /dev/sda1
```

---

## Encrypted systems (LUKS)

No special flags needed. When LUKS is detected:

```
LUKS encryption detected on /dev/sda2
Enter passphrase for /dev/sda2:
```

The unlocked mapper device is used for all subsequent steps. It is closed
automatically when the tool exits.

---

## Selective repairs

By default, all repair steps run. Disable individual steps:

```bash
# Only rebuild initramfs — skip bootloader
sudo ./bin/arch-recovery --auto --no-bootloader

# Only reinstall bootloader — skip initramfs rebuild
sudo ./bin/arch-recovery --auto --no-initramfs

# Skip fstab validation
sudo ./bin/arch-recovery --auto --no-fstab

# Add pacman keyring repair (requires internet)
sudo ./bin/arch-recovery --auto --repair-keyring

# Set up WiFi first, then auto-repair
sudo ./bin/arch-recovery --setup-network --auto
```

---

## BTRFS snapshot management

```bash
# List all subvolumes on the root partition
sudo ./bin/arch-recovery --list-snapshots --root /dev/sda2

# Roll back to a snapshot
# The current @ is preserved as @.broken-TIMESTAMP — never deleted
sudo ./bin/arch-recovery --rollback @pre-update --root /dev/sda2
sudo ./bin/arch-recovery --rollback @snapshots/2024-01-15 --root /dev/sda2
```

---

## Post-repair health check

After repairs complete, verify the system is ready to boot:

```bash
sudo ./bin/arch-recovery --health-check
```

Or run it as part of the full flow:

```bash
sudo ./bin/arch-recovery --auto --health-check
```

---

## Shell launchers

```bash
# bash (default)
sudo arch-recovery

# fish
sudo arch-recovery.fish

# POSIX sh / dash / zsh wrapper
sudo arch-recovery.sh
```

---

## Verbosity

```bash
# Errors only
sudo ./bin/arch-recovery --auto --silent

# Extra detail
sudo ./bin/arch-recovery --auto --verbose

# Trace every command (best for debugging)
sudo ./bin/arch-recovery --auto --debug

# Explicit level
sudo ./bin/arch-recovery --log-level verbose
```

---

## Log file

All operations are logged regardless of verbosity level. By default,
`arch-recovery` creates a private per-session log under `/tmp` and prints the
exact path at startup:

```bash
# Example live path
tail -f /tmp/arch-recovery-session.XXXXXX/recovery-toolkit.log

# View after
cat /tmp/arch-recovery-session.XXXXXX/recovery-toolkit.log

# Save before rebooting (the session dir is in /tmp — lost on reboot)
cp /tmp/arch-recovery-session.XXXXXX/recovery-toolkit.log ~/recovery-$(date +%F_%H%M).log
```

The log also contains a **rollback plan** written before any repair — a list
of manual commands to undo the changes if something goes wrong.

---

## Self-update

```bash
# Check if a newer version is available
sudo ./bin/arch-recovery --check-update

# Download and install the latest verified release bundle
sudo ./bin/arch-recovery --update
```

Release maintainers should publish both `make dist` assets and the signed manifest:
- `arch-system-recovery-vX.Y.Z.tar.gz`
- `arch-system-recovery-vX.Y.Z.tar.gz.sha256`
- `arch-system-recovery-vX.Y.Z.manifest`
- `arch-system-recovery-vX.Y.Z.manifest.sig`

---

## Common scenarios

### System won't boot after a partial upgrade

```bash
sudo arch-recovery --auto
```

Rebuilds initramfs and reinstalls the bootloader.

### GRUB overwritten by Windows (dual-boot)

```bash
sudo arch-recovery --root /dev/nvme0n1p3 --efi /dev/nvme0n1p1 --no-initramfs
```

Skips initramfs (it's fine) and reinstalls GRUB to the EFI partition.

### `invalid or corrupted package (PGP signature)` errors

```bash
sudo arch-recovery --setup-network --repair-keyring --no-initramfs --no-bootloader
```

Sets up network, fixes the keyring, refreshes the mirrorlist. Skips
initramfs and bootloader (they're not broken).

### BTRFS system won't mount — missing subvolume

```bash
# First, see what subvolumes exist
sudo arch-recovery --list-snapshots --root /dev/sda2
# Then run normal recovery — subvolume detection is automatic
sudo arch-recovery --root /dev/sda2
```

### Roll back after a bad update broke the system

```bash
sudo arch-recovery --list-snapshots --root /dev/sda2
sudo arch-recovery --rollback @pre-update-2024-06-01 --root /dev/sda2
```

### Encrypted root, unknown what is broken

```bash
sudo arch-recovery --diagnose
# Enter LUKS passphrase when prompted — diagnose mounts read-only
```
