# arch-system-recovery

A modular recovery toolkit for Arch-based Linux systems.
Designed to be run from a live USB — it repairs the most common reasons an
Arch installation will not boot, with zero knowledge required from the user.

[![CI](https://github.com/sumesh-s-dev/arch-system-recovery/actions/workflows/ci.yml/badge.svg)](https://github.com/sumesh-s-dev/arch-system-recovery/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash%2FShell%2FFish-brightgreen)](https://www.gnu.org/software/bash/)
[![GitHub Release](https://img.shields.io/github/v/release/sumesh-s-dev/arch-system-recovery?include_prereleases&label=Release)](https://github.com/sumesh-s-dev/arch-system-recovery/releases)

---

## The problem it solves

Recovering a broken Arch installation requires knowing the exact right
commands in the exact right order: unlocking LUKS, mounting BTRFS with the
correct subvolume flags, bind-mounting virtual filesystems, chrooting, running
`mkinitcpio`, reinstalling a bootloader. Miss one step and you're back where
you started. Do it under pressure and the risk of mistakes is high.

`arch-recovery` automates all of it. It detects your hardware layout, handles
the edge cases, and walks you through everything — or does it entirely
hands-free with `--auto`.

---

## Feature overview

| Capability | Detail |
|---|---|
| **Filesystems** | BTRFS (auto subvolume detection: `@`, `@root`, fallback), ext4 |
| **Encryption** | LUKS single-layer via `cryptsetup` |
| **LVM** | Volume group detection and activation |
| **Bootloaders** | GRUB (UEFI x86\_64), systemd-boot |
| **Diagnose mode** | Scan-only report — zero changes made |
| **TUI mode** | Full-screen menu (whiptail / dialog / pure-bash fallback) |
| **fstab repair** | UUID validation, stale-entry commenting, backup |
| **Pacman keyring** | Re-init, re-populate, optional keyserver refresh |
| **Network setup** | nmcli / iwctl / wpa\_supplicant / dhclient from live USB |
| **BTRFS snapshots** | List and roll back to any snapshot |
| **Health check** | Post-repair verification — kernel, initramfs, bootloader, fstab |
| **Self-update** | `--update` pulls the latest release from GitHub |
| **Shell support** | bash, zsh, fish, POSIX sh — launchers and tab-completions for all |
| **Logging** | Private per-session log under `/tmp/arch-recovery-session.*/recovery-toolkit.log` |
| **Safety** | Explicit confirmation, dry-run mode, rollback plan saved to log |

---

## Requirements

- A live **Arch Linux ISO** (all tools pre-installed)
- Root (`sudo`)
- Bash 4.2+

The following tools are used (all present on the Arch ISO):

```
blkid  lsblk  mount  arch-chroot  mkinitcpio
grub-install  grub-mkconfig  bootctl  cryptsetup  findmnt
```

---

## Quick start

```bash
# Boot the Arch live ISO, then:
git clone https://github.com/sumesh-s-dev/arch-system-recovery.git
cd arch-system-recovery
chmod +x bin/arch-recovery

# Guided interactive mode (recommended for first-time users)
sudo ./bin/arch-recovery

# Full-screen menu
sudo ./bin/arch-recovery --tui

# Scan only — find out what is broken before touching anything
sudo ./bin/arch-recovery --diagnose

# Fully automated repair
sudo ./bin/arch-recovery --auto

# Systems with a separate /boot partition
sudo ./bin/arch-recovery --root /dev/sda2 --boot /dev/sda1 --efi /dev/sda3
```

---

## All modes

### Interactive (default)
Prompts for each decision. Shows a confirmation summary before doing anything.
Safest for users who are not sure about their partition layout.

```bash
sudo arch-recovery
```

### TUI — full-screen menu
Whiptail or dialog if available; falls back to a numbered bash menu if neither
is installed (always works from the Arch live ISO).

```bash
sudo arch-recovery --tui
```

### Diagnose — scan without changing anything
Mounts read-only, inspects kernel images, initramfs, bootloader, fstab UUIDs,
EFI entries, and BTRFS snapshots. Colour-coded pass/warn/fail output.

```bash
sudo arch-recovery --diagnose
sudo arch-recovery --diagnose --root /dev/sda2
```

### Auto — no prompts
Auto-detects everything. Skips confirmation. Suitable for scripts.

```bash
sudo arch-recovery --auto
sudo arch-recovery --auto --root /dev/nvme0n1p2 --efi /dev/nvme0n1p1
sudo arch-recovery --auto --root /dev/sda2 --boot /dev/sda1 --efi /dev/sda3
```

### Dry run — preview without writing anything
Logs every planned action. Safe to run on any system at any time.

```bash
sudo arch-recovery --dry-run --verbose
```

---

## Selective repairs

All repair steps are enabled by default. Opt individual steps out:

```bash
# Only rebuild initramfs, skip bootloader reinstall
sudo arch-recovery --auto --no-bootloader

# Only reinstall bootloader, skip initramfs
sudo arch-recovery --auto --no-initramfs

# Skip fstab validation
sudo arch-recovery --auto --no-fstab

# Repair pacman keyring too (off by default, requires network)
sudo arch-recovery --auto --repair-keyring

# Set up network connection first (WiFi or ethernet)
sudo arch-recovery --setup-network --auto
```

---

## BTRFS snapshots

```bash
# List all subvolumes on your root partition
sudo arch-recovery --list-snapshots --root /dev/sda2

# Roll back to a snapshot
# The current @ subvolume is renamed to @.broken-TIMESTAMP (never deleted)
sudo arch-recovery --rollback @pre-update-2024-01-15 --root /dev/sda2
```

---

## Post-repair health check

Verifies the system looks bootable after repairs. Never modifies anything.

```bash
sudo arch-recovery --health-check
```

Checks: kernel images, initramfs size and pairing, GRUB config / systemd-boot
loader.conf, EFI boot entries, fstab UUID validity, mkinitcpio.conf hooks,
locale, timezone, pacman database presence.

---

## Self-update

```bash
# Check if a newer release exists
sudo arch-recovery --check-update

# Download and install the latest verified release bundle
sudo arch-recovery --update
```

Build release assets with `make dist`, then generate a signed manifest with `make release-manifest`.
Authenticated releases publish four files:
- `arch-system-recovery-vX.Y.Z.tar.gz`
- `arch-system-recovery-vX.Y.Z.tar.gz.sha256`
- `arch-system-recovery-vX.Y.Z.manifest`
- `arch-system-recovery-vX.Y.Z.manifest.sig`

---

## Shell support

| Shell | How to run |
|---|---|
| bash / zsh | `sudo arch-recovery` |
| fish | `sudo arch-recovery.fish` |
| dash / sh | `sudo arch-recovery.sh` |

### Tab completion

```bash
# Bash (system-wide)
sudo cp completions/arch-recovery.bash /etc/bash_completion.d/arch-recovery

# Bash (per-user)
cp completions/arch-recovery.bash ~/.local/share/bash-completion/completions/arch-recovery

# Zsh
sudo cp completions/_arch-recovery /usr/share/zsh/site-functions/_arch-recovery

# Fish
cp completions/arch-recovery.fish ~/.config/fish/completions/arch-recovery.fish

# Or install everything at once:
sudo make install-completions
```

---

## Installation

```bash
# Install to /usr/local (adds to PATH, installs manpage + completions)
sudo make install

# Custom prefix
sudo make install PREFIX=/opt/recovery

# Uninstall
sudo make uninstall
```

After installation:

```bash
arch-recovery --help
man arch-recovery
```

---

## Verbosity levels

| Flag | Output |
|---|---|
| `-q` / `--silent` | Errors only |
| *(default)* | Normal progress messages |
| `-v` / `--verbose` | Extra detail on each step |
| `--debug` | Every command traced as it runs |
| `--log-level silent\|normal\|verbose\|debug` | Explicit control |

All levels write the full log to a private per-session path under `/tmp`.
The exact path is printed at startup.

---

## Repository layout

```
arch-system-recovery/
├── bin/
│   ├── arch-recovery          # Main entry point (bash)
│   ├── arch-recovery.fish     # Fish shell launcher
│   └── arch-recovery.sh       # POSIX sh launcher
├── lib/
│   ├── core.sh                # Logging, die/warn, run_cmd, spinner
│   ├── ui.sh                  # Prompts, banner, confirm_repair
│   ├── tui.sh                 # Full-screen whiptail/dialog/bash menu
│   ├── detect.sh              # Root/EFI/FS/bootloader/BTRFS/LVM detection
│   ├── luks.sh                # LUKS open/close
│   ├── mount.sh               # mount_root, mount_efi, bind-mounts, cleanup
│   ├── repair.sh              # mkinitcpio, GRUB, systemd-boot
│   ├── preflight.sh           # Pre-repair sanity checks
│   ├── diagnose.sh            # Scan-only mode
│   ├── fstab.sh               # /etc/fstab validation and repair
│   ├── pacman.sh              # Keyring re-init and mirrorlist refresh
│   ├── network.sh             # Live USB network setup
│   ├── snapshot.sh            # BTRFS snapshot listing and rollback
│   └── health.sh              # Post-repair verification
├── completions/
│   ├── arch-recovery.bash     # Bash tab-completion
│   ├── _arch-recovery         # Zsh tab-completion
│   └── arch-recovery.fish     # Fish tab-completion
├── tests/
│   ├── helpers.sh             # assert_eq, assert_true, assert_exits_ok…
│   ├── run_tests.sh           # Test runner (discovery + reporting)
│   ├── test_cli.sh
│   ├── test_core.sh
│   ├── test_detect.sh
│   ├── test_fstab.sh
│   ├── test_health.sh
│   ├── test_luks.sh
│   └── test_snapshot.sh
├── docs/
│   ├── architecture.md
│   ├── releases/              # Versioned release notes + signed manifests
│   ├── scope.md
│   └── usage.md
├── keys/
│   └── release_signers.allowed # Trusted SSH signers for authenticated releases
├── man/
│   └── arch-recovery.1        # Manpage (groff/troff)
├── .github/workflows/ci.yml   # CI: syntax, shellcheck, tests, manpage
├── .github/workflows/release.yml   # Signed release publishing
├── Makefile
├── install.sh
└── README.md
```

---

## Running the tests

```bash
# Run the full test suite (no root required)
bash tests/run_tests.sh

# Or via Make
make test
sudo make integration-test

# Syntax check all scripts
make check

# ShellCheck (requires shellcheck package)
make shellcheck
```

---

## Limitations

- UEFI systems only — no legacy BIOS/MBR GRUB
- x86\_64 only
- LUKS single-layer only (no LUKS-on-LVM)
- Does not repair filesystem corruption (run `fsck` manually)
- Does not install kernels or packages inside the chroot
- No Secure Boot re-enrollment

---

## License

MIT — see [LICENSE](LICENSE).
