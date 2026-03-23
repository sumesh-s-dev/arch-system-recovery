#!/usr/bin/env bash
# tests/integration/test_loopback.sh — privileged loopback integration coverage
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

skip() {
    echo "SKIP: $1"
    exit 0
}

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    [[ "${actual}" == "${expected}" ]] || fail "${msg}: expected '${expected}', got '${actual}'"
    pass "${msg}"
}

assert_file_contains() {
    local file="$1" needle="$2" msg="$3"
    grep -Fq -- "${needle}" "${file}" || fail "${msg}: '${needle}' not found in ${file}"
    pass "${msg}"
}

[[ "${EUID}" -eq 0 ]] || skip "requires root"

for dep in losetup truncate mkfs.ext4 mkfs.btrfs mkfs.vfat cryptsetup \
           pvcreate vgcreate lvcreate lvremove vgremove pvremove \
           btrfs mount umount blkid lsblk findmnt; do
    command -v "${dep}" &>/dev/null || skip "missing dependency: ${dep}"
done

WORKDIR="$(mktemp -d /tmp/arch-recovery-integration.XXXXXX)"
EXT4_LOOP=""
BTRFS_LOOP=""
LUKS_LOOP=""
LVM_LOOP=""
VG_NAME="archrecoverytest$$"

cleanup() {
    set +e
    if declare -f cleanup_mounts >/dev/null 2>&1; then
        cleanup_mounts >/dev/null 2>&1 || true
    fi
    for mp in \
        "${WORKDIR}/ext4-prep" \
        "${WORKDIR}/ext4-check" \
        "${WORKDIR}/btrfs-prep" \
        "${WORKDIR}/btrfs-check" \
        "${WORKDIR}/repair-root/boot/efi"; do
        mountpoint -q "${mp}" 2>/dev/null && umount -l "${mp}" >/dev/null 2>&1 || true
    done
    [[ -n "${VG_NAME:-}" ]] && lvremove -ff -y "/dev/${VG_NAME}/root" >/dev/null 2>&1 || true
    [[ -n "${VG_NAME:-}" ]] && vgremove -ff -y "${VG_NAME}" >/dev/null 2>&1 || true
    [[ -n "${LVM_LOOP:-}" ]] && pvremove -ff -y "${LVM_LOOP}" >/dev/null 2>&1 || true
    [[ -n "${EXT4_LOOP:-}" ]] && losetup -d "${EXT4_LOOP}" >/dev/null 2>&1 || true
    [[ -n "${BTRFS_LOOP:-}" ]] && losetup -d "${BTRFS_LOOP}" >/dev/null 2>&1 || true
    [[ -n "${LUKS_LOOP:-}" ]] && losetup -d "${LUKS_LOOP}" >/dev/null 2>&1 || true
    [[ -n "${LVM_LOOP:-}" ]] && losetup -d "${LVM_LOOP}" >/dev/null 2>&1 || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

export LOG_FILE="${WORKDIR}/integration.log"
export SESSION_DIR="${WORKDIR}/session"
export MOUNT_ROOT="${WORKDIR}/repair-root"
export LOG_LEVEL="silent"
export AUTO_MODE=false
export DRY_RUN=false

source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/detect.sh"
source "${REPO_ROOT}/lib/mount.sh"
source "${REPO_ROOT}/lib/luks.sh"
source "${REPO_ROOT}/lib/repair.sh"
init_log

# ext4 root
truncate -s 96M "${WORKDIR}/ext4.img"
EXT4_LOOP="$(losetup --find --show "${WORKDIR}/ext4.img")"
mkfs.ext4 -F "${EXT4_LOOP}" >/dev/null
mkdir -p "${WORKDIR}/ext4-prep" "${WORKDIR}/ext4-check"
mount -t ext4 "${EXT4_LOOP}" "${WORKDIR}/ext4-prep"
mkdir -p "${WORKDIR}/ext4-prep/etc" "${WORKDIR}/ext4-prep/boot" \
         "${WORKDIR}/ext4-prep/var/lib/pacman/local"
printf '%s / ext4 defaults 0 1\n' "${EXT4_LOOP}" > "${WORKDIR}/ext4-prep/etc/fstab"
printf 'ID=arch\n' > "${WORKDIR}/ext4-prep/etc/os-release"
touch "${WORKDIR}/ext4-prep/boot/vmlinuz-linux"
umount "${WORKDIR}/ext4-prep"

assert_eq "$(detect_filesystem "${EXT4_LOOP}")" "ext4" "detect_filesystem sees ext4 loopback root"
mount_root_at "${WORKDIR}/ext4-check" "${EXT4_LOOP}" ext4 ro
validate_mounted_root "${WORKDIR}/ext4-check" "${EXT4_LOOP}" true
pass "mount_root_at mounts ext4 loopback root read-only"
umount "${WORKDIR}/ext4-check"

# btrfs root with @ subvolume
truncate -s 160M "${WORKDIR}/btrfs.img"
BTRFS_LOOP="$(losetup --find --show "${WORKDIR}/btrfs.img")"
mkfs.btrfs -f "${BTRFS_LOOP}" >/dev/null
mkdir -p "${WORKDIR}/btrfs-prep" "${WORKDIR}/btrfs-check"
mount -t btrfs -o subvolid=5 "${BTRFS_LOOP}" "${WORKDIR}/btrfs-prep"
btrfs subvolume create "${WORKDIR}/btrfs-prep/@" >/dev/null
mkdir -p "${WORKDIR}/btrfs-prep/@/etc" "${WORKDIR}/btrfs-prep/@/boot" \
         "${WORKDIR}/btrfs-prep/@/var/lib/pacman/local"
printf '%s / btrfs defaults 0 1\n' "${BTRFS_LOOP}" > "${WORKDIR}/btrfs-prep/@/etc/fstab"
printf 'ID=arch\n' > "${WORKDIR}/btrfs-prep/@/etc/os-release"
touch "${WORKDIR}/btrfs-prep/@/boot/vmlinuz-linux"
umount "${WORKDIR}/btrfs-prep"

assert_eq "$(detect_btrfs_subvol "${BTRFS_LOOP}")" "@" "detect_btrfs_subvol finds @ subvolume"
mount_root_at "${WORKDIR}/btrfs-check" "${BTRFS_LOOP}" btrfs ro
validate_mounted_root "${WORKDIR}/btrfs-check" "${BTRFS_LOOP}" true
pass "mount_root_at mounts BTRFS @ subvolume read-only"
umount "${WORKDIR}/btrfs-check"

# luks root
truncate -s 96M "${WORKDIR}/luks.img"
LUKS_LOOP="$(losetup --find --show "${WORKDIR}/luks.img")"
printf 'integration-pass\n' > "${WORKDIR}/luks.key"
chmod 600 "${WORKDIR}/luks.key"
cryptsetup luksFormat --batch-mode "${LUKS_LOOP}" "${WORKDIR}/luks.key" >/dev/null
is_luks "${LUKS_LOOP}" || fail "is_luks should detect the loopback LUKS container"
pass "is_luks detects loopback LUKS container"
LUKS_MAPPED="$(printf 'integration-pass\n' | unlock_luks "${LUKS_LOOP}")"
[[ -b "${LUKS_MAPPED}" ]] || fail "unlock_luks should create a mapper device"
mkfs.ext4 -F "${LUKS_MAPPED}" >/dev/null
assert_eq "$(detect_filesystem "${LUKS_MAPPED}")" "ext4" "detect_filesystem sees ext4 inside unlocked LUKS"
close_luks
[[ ! -e "${LUKS_MAPPED}" ]] || fail "close_luks should close the mapper"
pass "unlock_luks and close_luks work on a real loopback container"

# lvm root
truncate -s 256M "${WORKDIR}/lvm.img"
LVM_LOOP="$(losetup --find --show "${WORKDIR}/lvm.img")"
pvcreate -ff -y "${LVM_LOOP}" >/dev/null
vgcreate "${VG_NAME}" "${LVM_LOOP}" >/dev/null
lvcreate -y -L 96M -n root "${VG_NAME}" >/dev/null
assert_eq "$(detect_lvm "${LVM_LOOP}")" "/dev/${VG_NAME}/root" "detect_lvm resolves the root logical volume"

# boot repair paths
MOCK_BIN="${WORKDIR}/mock-bin"
mkdir -p "${MOCK_BIN}" "${MOUNT_ROOT}/boot/efi" "${MOUNT_ROOT}/boot/grub" "${WORKDIR}/esp"
cat > "${MOCK_BIN}/arch-chroot" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${WORKDIR}/arch-chroot.log"
exit 0
EOF
chmod +x "${MOCK_BIN}/arch-chroot"
export PATH="${MOCK_BIN}:${PATH}"
mount --bind "${WORKDIR}/esp" "${MOUNT_ROOT}/boot/efi"

repair_initramfs
repair_bootloader grub
repair_bootloader systemd-boot

assert_file_contains "${WORKDIR}/arch-chroot.log" "mkinitcpio -P" "repair_initramfs invokes mkinitcpio in chroot"
assert_file_contains "${WORKDIR}/arch-chroot.log" "--efi-directory=/boot/efi" "repair_grub uses the mounted EFI directory"
assert_file_contains "${WORKDIR}/arch-chroot.log" "grub-mkconfig -o /boot/grub/grub.cfg" "repair_grub regenerates grub.cfg"
assert_file_contains "${WORKDIR}/arch-chroot.log" "bootctl install" "repair_systemd_boot installs systemd-boot"

echo "Integration suite completed successfully."
