# Scope

## Supported scenarios

| Scenario | How it's handled |
|---|---|
| Broken / missing initramfs | `mkinitcpio -P` inside arch-chroot |
| GRUB missing / corrupt (UEFI) | `grub-install` + `grub-mkconfig` |
| systemd-boot missing / corrupt | `bootctl install` + `bootctl update` |
| BTRFS root with `@` subvolume | Auto-detected and mounted with `subvol=@` |
| BTRFS root with `@root` subvolume | Auto-detected |
| BTRFS root at top-level (no subvolume) | Falls back to `subvolid=5` |
| BTRFS snapshot rollback | Rename current `@` → `@.broken-TS`, snapshot target → `@` |
| ext4 root partition | Standard `mount -t ext4` |
| LUKS encrypted root | `cryptsetup open` before mounting |
| LVM volume groups | `vgchange -ay` + auto-detection of root LV |
| LUKS root with LVM inside | Unlock container first, then activate VG and select root LV |
| Stale `/etc/fstab` UUID entries | Detected, commented out, backup saved |
| Corrupt pacman keyring | `pacman-key --init` + `--populate archlinux` |
| No network on live USB | nmcli / iwctl / wpa\_supplicant / dhclient |
| Unknown what is broken | `--diagnose` scans everything read-only |
| Post-repair verification | `--health-check` validates before reboot |

---

## Explicitly not supported

| Scenario | Reason |
|---|---|
| Legacy BIOS / MBR GRUB | Modern Arch installs use UEFI; MBR adds significant complexity for a shrinking user base |
| Arbitrary multi-layer block stacks beyond the built-in LUKS/LVM paths | Unusual layering can require manual assembly before a safe mount is possible |
| ZFS root | Requires out-of-tree kernel modules not present on the stock ISO |
| Multi-device BTRFS RAID | Devices must be assembled manually before this tool can see a single mountable path |
| Filesystem corruption repair | `fsck.ext4` or `btrfs check` must be run before mounting; this tool does not know which is needed |
| Kernel installation | Package selection is user-specific; installing the wrong kernel can cause new problems |
| Full system reinstall | Out of scope — use `archinstall` or the wiki |
| Secure Boot key enrollment | Requires vendor firmware tooling |
| ARM / 32-bit | Only x86\_64 is tested |
| Encrypted `/boot` (detached header LUKS) | Uncommon and requires manual header specification |

---

## Risk considerations

**`mkinitcpio -P`** rebuilds all presets. If a custom preset references a
missing module or hook, the rebuild will fail inside the chroot. The full
error is captured in the per-session log path printed at startup.

**`grub-install`** writes to the EFI System Partition. Running it against the
wrong device can overwrite a different OS's bootloader. Always verify the EFI
partition device before confirming.

**LUKS passphrase** is entered interactively via `cryptsetup open`. It is
never logged, never passed on the command line, and never stored anywhere.

**BTRFS rollback** renames the current root subvolume rather than deleting it.
If the rolled-back snapshot has issues, the original can be recovered:

```bash
# Undo a rollback manually
mount -o subvolid=5 /dev/sdXN /mnt/top
mv /mnt/top/@.broken-TIMESTAMP /mnt/top/@
umount /mnt/top
```

**Bind mounts** (`/dev`, `/proc`, `/sys`, `/run`) are cleaned up by the EXIT
trap even if the tool is killed mid-run. If you kill it with SIGKILL (`kill -9`)
the trap will not fire — unmount manually:

```bash
umount -R /mnt/recovery
```

**fstab edits** always create a timestamped backup (`/etc/fstab.bak.YYYYMMDD_HHMMSS`)
before modifying anything. The original is never deleted.

**Rollback plans in the log** are generated from the actual devices detected
for the current session. On encrypted or LVM-backed systems, they include the
mapped root path plus any required `cryptsetup open` and `vgchange -ay` steps.

---

## When a live USB is required

**Required when:**
- The system cannot boot at all (no kernel or initramfs present)
- The root filesystem is unmountable from a running session
- You need to write to the EFI System Partition from outside the installed OS

**Optional (but recommended) when:**
- The system boots into an emergency shell
- Only the GRUB config needs regeneration

**Recommended ISO:** [Arch Linux ISO](https://archlinux.org/download/)

All required tools are pre-installed in the Arch live environment.
