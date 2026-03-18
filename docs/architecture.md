# Architecture

## Module map

```
bin/arch-recovery              Entry point, flag parsing, orchestration
│
├── lib/core.sh                Foundation: logging, die/warn/vlog/dlog,
│                              run_cmd, spin_while, check_root, check_deps
│
├── lib/ui.sh                  Terminal I/O: banner, prompts, confirm_repair
├── lib/tui.sh                 Full-screen menus (whiptail/dialog/bash fallback)
│
├── lib/detect.sh              Detection: root, EFI, filesystem, bootloader,
│                              BTRFS subvolume, LVM
├── lib/luks.sh                LUKS: is_luks, unlock_luks, close_luks
├── lib/mount.sh               Mounting: root, EFI, bind-mounts, cleanup
│
├── lib/preflight.sh           Pre-repair health checks (non-destructive)
├── lib/diagnose.sh            Scan-only mode (never writes anything)
│
├── lib/repair.sh              Repairs: mkinitcpio, GRUB, systemd-boot
├── lib/fstab.sh               /etc/fstab validation and conservative repair
├── lib/pacman.sh              Pacman keyring re-init, mirrorlist refresh
├── lib/network.sh             Live USB network setup
├── lib/snapshot.sh            BTRFS snapshot listing and rollback
└── lib/health.sh              Post-repair verification (read-only)
```

---

## Data flow — standard repair

```
CLI args
    │
    ▼
parse_args()
    │
    ├── --tui ──────────────────► tui_main()          (full-screen flow)
    ├── --diagnose ─────────────► diagnose_main()     (read-only scan)
    ├── --list-snapshots ───────► list_btrfs_snapshots()
    ├── --rollback <n> ─────────► rollback_snapshot()
    ├── --check-update ─────────► _check_for_update()
    └── --update ───────────────► _self_update()
    │
    ▼  (standard path)
check_root()  check_deps()
    │
    ▼
[--setup-network]  setup_network()
    │
    ▼
auto_detect_root() OR prompt_root_device()
    │
    ROOT_DEVICE
    │
    ▼
is_luks(ROOT_DEVICE) ──yes──► unlock_luks() ──► MAPPED_ROOT
    │ no                                              │
    ▼                                                 │
MAPPED_ROOT = ROOT_DEVICE ◄───────────────────────────┘
    │
    ▼
detect_lvm(MAPPED_ROOT)  →  MAPPED_ROOT (may be /dev/vg/lv)
    │
    ▼
detect_filesystem(MAPPED_ROOT)  →  FS_TYPE (btrfs | ext4)
    │
    ▼
mount_root(MAPPED_ROOT, FS_TYPE)
    │   └─ btrfs: detect_btrfs_subvol() → mount -o subvol=@
    │   └─ ext4:  mount -t ext4
    │
    ▼
auto_detect_efi() OR prompt_efi_device()  →  EFI_DEVICE
mount_efi(EFI_DEVICE)   →  resolves /boot/efi | /boot | /efi from fstab
    │
    ▼
detect_bootloader(MOUNT_ROOT)  →  BOOTLOADER (grub | systemd-boot | unknown)
    │
    ▼
run_preflight(MAPPED_ROOT, EFI_DEVICE, FS_TYPE)
    │   checks: mount points, kernel, mkinitcpio.conf, HOOKS, disk space
    │
    ▼
[DO_FSTAB]  validate_and_repair_fstab()
    │   UUID / PARTUUID / /dev/ cross-check against blkid
    │   stale entries commented out; backup saved
    │
    ▼
confirm_repair()   ← user types "yes" (skipped in --auto)
_save_rollback_plan()  ← written to LOG_FILE before any changes
    │
    ▼
[DO_KEYRING]  repair_pacman_keyring()
    │   rm -rf gnupg; pacman-key --init; pacman-key --populate archlinux
    │   optional: --refresh-keys; mirrorlist refresh via reflector or curl
    │
    ▼
[DO_INITRAMFS]  repair_initramfs()
    │   mount_bind()  ← /dev /proc /sys /run
    │   arch-chroot MOUNT_ROOT mkinitcpio -P
    │
    ▼
[DO_BOOTLOADER]  repair_bootloader(BOOTLOADER, EFI_DEVICE)
    │   grub:         grub-install --target=x86_64-efi + grub-mkconfig
    │   systemd-boot: bootctl install + bootctl update
    │
    ▼
[DO_HEALTH_CHECK]  run_health_check()
    │   kernel images, initramfs size+pairing, bootloader config,
    │   EFI entries, fstab UUIDs, mkinitcpio.conf, locale, pacman db
    │
    ▼
cleanup_mounts()   ← reverse-order unmount + close_luks()
    │
    ▼
EXIT trap (_on_exit) always fires — safe even on crash/SIGINT
```

---

## Design decisions

### Why all output goes to stderr
Every function that returns a value uses `echo` to stdout (e.g.
`detect_filesystem` echoes `"btrfs"`). If `log()` also wrote to stdout,
command substitution like `FS_TYPE="$(detect_filesystem ...)"` would capture
log lines alongside the real return value. All `log/err/warn/vlog/dlog`
functions write to **stderr + LOG_FILE** only. Stdout is exclusively for
function return values.

### Why `[[ -v VAR ]] || readonly VAR=...` instead of bare `readonly`
The test suite sources modules multiple times in the same shell to swap out
mock implementations. Bare `readonly` on first source locks the variable
permanently — re-sourcing with a different `LOG_FILE` would crash. The
`[[ -v ]]` guard makes every constant idempotent: set once on first source,
silently skipped on all subsequent sources.

### Why `detect_bootloader` accepts an optional path argument
Originally it relied on the global `MOUNT_ROOT`. Tests can't reassign a
`readonly` global even in subshells (bash propagates `readonly` into child
processes). Accepting `${1:-${MOUNT_ROOT}}` makes the function directly
testable without any global mutation.

### Why `run_cmd` is the single execution chokepoint
Every command that modifies the system passes through `run_cmd`. It:
- Logs the command at debug level before running it
- In `--dry-run` mode, logs `[dry-run]` and returns 0 without running
- In `--debug` mode, tees output to the terminal in real time
- On failure, calls `die` with the full command for easy log searching

This means dry-run is guaranteed to be complete — no command can
accidentally bypass it.

### Why the EXIT trap instead of explicit cleanup calls
The `_on_exit` trap fires on every exit path: normal return, `set -e` error,
`die`, SIGINT, SIGTERM. Relying only on explicit cleanup calls at the end of
`main()` would leave mounts dangling if any earlier step crashed. The trap
calls `cleanup_mounts` and `close_luks` unconditionally — both are no-ops
when nothing is mounted.

### Why BTRFS rollback renames rather than deletes
`rollback_snapshot` renames the current root subvolume to
`@.broken-TIMESTAMP` before creating the new one from the target snapshot.
This means:
- The rollback itself can be undone (rename back)
- If `btrfs subvolume snapshot` fails, the original is still present and
  the tool restores it before exiting
- No data is ever destroyed by the recovery tool

### TUI backend selection
`whiptail` is preferred over `dialog` because it is present on the Arch live
ISO by default (`libnewt` package). `dialog` is a valid fallback. If neither
exists — common in minimal containers or unusual live environments — the tool
falls back to a pure-bash numbered menu (`_bash_menu`). The user always gets
a functional interface regardless of what is installed.

---

## Module responsibilities (quick reference)

| Module | Reads globals | Writes globals | Side effects |
|---|---|---|---|
| `core.sh` | — | `LOG_FILE`, `MOUNT_ROOT`, `TOOLKIT_VERSION` | Creates log file |
| `ui.sh` | `LOG_LEVEL`, `MOUNT_ROOT` | — | Terminal I/O |
| `tui.sh` | All recovery globals | Sets `AUTO_MODE` etc. | Runs full recovery |
| `detect.sh` | `MOUNT_ROOT` | — | Reads block devices |
| `luks.sh` | `LOG_FILE`, `DRY_RUN` | — | Opens/closes LUKS mapper |
| `mount.sh` | `MOUNT_ROOT`, `DRY_RUN` | — | mounts, bind-mounts, umounts |
| `preflight.sh` | `MOUNT_ROOT` | — | Read-only filesystem checks |
| `diagnose.sh` | `MOUNT_ROOT` | — | Read-only; mounts at ro |
| `repair.sh` | `MOUNT_ROOT`, `DRY_RUN` | — | mkinitcpio, bootloader install |
| `fstab.sh` | `MOUNT_ROOT` | — | Edits `/etc/fstab` (with backup) |
| `pacman.sh` | `MOUNT_ROOT` | — | Keyring, mirrorlist |
| `network.sh` | — | — | Network configuration |
| `snapshot.sh` | — | — | BTRFS subvolume ops |
| `health.sh` | `MOUNT_ROOT` | — | Read-only verification |
