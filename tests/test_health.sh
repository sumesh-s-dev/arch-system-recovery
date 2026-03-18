#!/usr/bin/env bash
# tests/test_health.sh — unit tests for lib/health.sh
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

export LOG_FILE="/tmp/test_health_$$.log"
MOCK_DIR="$(mktemp -d /tmp/arch-recovery-health-mocks.XXXXXX)"
export PATH="${MOCK_DIR}:${PATH}"

make_mock() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "${MOCK_DIR}/$1"
    chmod +x "${MOCK_DIR}/$1"
}

# ── Build a minimal healthy fake chroot ───────────────────────────────────────
HEALTHY_ROOT="$(mktemp -d /tmp/fake-healthy.XXXXXX)"
mkdir -p "${HEALTHY_ROOT}/boot/grub"
mkdir -p "${HEALTHY_ROOT}/etc"
mkdir -p "${HEALTHY_ROOT}/var/lib/pacman/local/linux-6.9.0"
mkdir -p "${HEALTHY_ROOT}/var/lib/pacman/local/bash-5.2.0"

touch "${HEALTHY_ROOT}/boot/vmlinuz-linux"
# initramfs must be > 1024 bytes
dd if=/dev/urandom bs=1100 count=1 2>/dev/null > "${HEALTHY_ROOT}/boot/initramfs-linux.img"
echo 'HOOKS=(base udev autodetect modconf block filesystems)' \
    > "${HEALTHY_ROOT}/etc/mkinitcpio.conf"
echo 'LANG=en_US.UTF-8'   > "${HEALTHY_ROOT}/etc/locale.conf"
touch "${HEALTHY_ROOT}/etc/localtime"
echo "tmpfs /tmp tmpfs defaults 0 0" > "${HEALTHY_ROOT}/etc/fstab"
echo 'linux /boot/vmlinuz-linux root=UUID=abc rw' > "${HEALTHY_ROOT}/boot/grub/grub.cfg"

# Mocks for system tools called by health.sh
make_mock mountpoint 'exit 0'
make_mock efibootmgr 'printf "Boot0000* Arch Linux\n"; exit 0'
make_mock blkid       'exit 0'   # all UUIDs valid

# MOUNT_ROOT exported BEFORE source so readonly guard leaves it as our value
export MOUNT_ROOT="${HEALTHY_ROOT}"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/detect.sh"
source "${REPO_ROOT}/lib/health.sh"
init_log

# ── Test: fully healthy root passes ──────────────────────────────────────────
assert_exits_ok run_health_check

# ── Test: missing kernel causes fail ─────────────────────────────────────────
rm -f "${HEALTHY_ROOT}/boot/vmlinuz-linux"
assert_exits_err run_health_check
touch "${HEALTHY_ROOT}/boot/vmlinuz-linux"  # restore

# ── Test: zero-byte initramfs causes fail ────────────────────────────────────
: > "${HEALTHY_ROOT}/boot/initramfs-linux.img"
assert_exits_err run_health_check
# restore
dd if=/dev/urandom bs=1100 count=1 2>/dev/null > "${HEALTHY_ROOT}/boot/initramfs-linux.img"

# ── Test: missing mkinitcpio.conf causes fail ────────────────────────────────
rm -f "${HEALTHY_ROOT}/etc/mkinitcpio.conf"
assert_exits_err run_health_check
echo 'HOOKS=(base udev autodetect)' > "${HEALTHY_ROOT}/etc/mkinitcpio.conf"  # restore

# ── Test: missing /etc/fstab causes fail ─────────────────────────────────────
rm -f "${HEALTHY_ROOT}/etc/fstab"
assert_exits_err run_health_check
echo "tmpfs /tmp tmpfs defaults 0 0" > "${HEALTHY_ROOT}/etc/fstab"  # restore

# ── Test: missing pacman db causes fail ──────────────────────────────────────
rm -rf "${HEALTHY_ROOT}/var/lib/pacman/local"
assert_exits_err run_health_check

rm -rf "${MOCK_DIR}" "${HEALTHY_ROOT}" "${LOG_FILE}"
test_summary
