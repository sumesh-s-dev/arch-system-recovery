#!/usr/bin/env bash
# tests/test_detect.sh — unit tests for lib/detect.sh
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

MOCK_DIR="$(mktemp -d /tmp/arch-recovery-mocks.XXXXXX)"
export LOG_FILE="/tmp/test_detect_$$.log"
export PATH="${MOCK_DIR}:${PATH}"

source "${REPO_ROOT}/lib/core.sh"
init_log

make_mock() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "${MOCK_DIR}/$1"
    chmod +x "${MOCK_DIR}/$1"
}

# ── detect_filesystem ─────────────────────────────────────────────────────────
make_mock blkid 'echo "btrfs"'
source "${REPO_ROOT}/lib/detect.sh"
result="$(detect_filesystem /dev/fake1 2>/dev/null)"
assert_eq "${result}" "btrfs" "detect_filesystem returns btrfs"

make_mock blkid 'echo "ext4"'
source "${REPO_ROOT}/lib/detect.sh"
result="$(detect_filesystem /dev/fake2 2>/dev/null)"
assert_eq "${result}" "ext4" "detect_filesystem returns ext4"

make_mock blkid 'echo "ntfs"'
assert_exits_err bash -c "
    export PATH='${MOCK_DIR}:\$PATH'
    export LOG_FILE=/dev/null
    source '${REPO_ROOT}/lib/core.sh'
    source '${REPO_ROOT}/lib/detect.sh'
    detect_filesystem /dev/fake3 2>/dev/null
"

# ── detect_bootloader ─────────────────────────────────────────────────────────
# detect_bootloader accepts an optional root path arg (avoids MOUNT_ROOT readonly issue)
source "${REPO_ROOT}/lib/detect.sh"

FAKE_ROOT="$(mktemp -d /tmp/fake-root.XXXXXX)"

# systemd-boot: loader.conf present
mkdir -p "${FAKE_ROOT}/boot/loader"
touch "${FAKE_ROOT}/boot/loader/loader.conf"
result="$(detect_bootloader "${FAKE_ROOT}" 2>/dev/null)"
assert_eq "${result}" "systemd-boot" "detect_bootloader finds systemd-boot"

# GRUB: /boot/grub directory present
rm -rf "${FAKE_ROOT}"
FAKE_ROOT="$(mktemp -d /tmp/fake-root.XXXXXX)"
mkdir -p "${FAKE_ROOT}/boot/grub"
result="$(detect_bootloader "${FAKE_ROOT}" 2>/dev/null)"
assert_eq "${result}" "grub" "detect_bootloader finds grub"

# Unknown: neither present
rm -rf "${FAKE_ROOT}"
FAKE_ROOT="$(mktemp -d /tmp/fake-root.XXXXXX)"
mkdir -p "${FAKE_ROOT}/boot"
result="$(detect_bootloader "${FAKE_ROOT}" 2>/dev/null)"
assert_eq "${result}" "unknown" "detect_bootloader returns unknown"

# ── fstab-backed boot / EFI detection ────────────────────────────────────────
rm -rf "${FAKE_ROOT}"
FAKE_ROOT="$(mktemp -d /tmp/fake-root.XXXXXX)"
mkdir -p "${FAKE_ROOT}/etc"
cat > "${FAKE_ROOT}/etc/fstab" <<'EOF'
UUID=root-uuid / ext4 defaults 0 1
UUID=boot-uuid /boot ext4 defaults 0 2
UUID=efi-uuid /boot/efi vfat defaults 0 2
EOF

make_mock blkid '
case "$*" in
  "-U boot-uuid") echo "/dev/sdb1"; exit 0 ;;
  "-U efi-uuid")  echo "/dev/sdb2"; exit 0 ;;
  "-s TYPE -o value /dev/sdb1") echo "ext4"; exit 0 ;;
  "-s TYPE -o value /dev/sdb2") echo "vfat"; exit 0 ;;
  "-s PART_ENTRY_TYPE -o value /dev/sdb1") echo ""; exit 0 ;;
  "-s PART_ENTRY_TYPE -o value /dev/sdb2") echo "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"; exit 0 ;;
  "-s UUID -o value /dev/sdb1") echo "boot-uuid"; exit 0 ;;
  "-s UUID -o value /dev/sdb2") echo "efi-uuid"; exit 0 ;;
  *) exit 1 ;;
esac'
source "${REPO_ROOT}/lib/detect.sh"

result="$(detect_boot_device "${FAKE_ROOT}" 2>/dev/null)"
assert_eq "${result}" "/dev/sdb1" "detect_boot_device resolves /boot from fstab"

result="$(detect_fstab_efi_mountpoint "${FAKE_ROOT}" 2>/dev/null)"
assert_eq "${result}" "/boot/efi" "detect_fstab_efi_mountpoint prefers /boot/efi"

result="$(detect_fstab_efi_device "${FAKE_ROOT}" 2>/dev/null)"
assert_eq "${result}" "/dev/sdb2" "detect_fstab_efi_device resolves EFI device from fstab"

assert_true "device_matches_spec matches UUID entries" device_matches_spec "/dev/sdb1" "UUID=boot-uuid"
assert_true "strong native root scores are accepted" _should_accept_auto_detect_root 6 ext4 0 false
assert_true "single encrypted container can be auto-detected" _should_accept_auto_detect_root 5 crypto_LUKS 1 false
assert_false "multiple encrypted containers are not auto-selected" _should_accept_auto_detect_root 5 crypto_LUKS 2 false
assert_false "ties are rejected for auto-detection" _should_accept_auto_detect_root 7 ext4 0 true

rm -rf "${MOCK_DIR}" "${FAKE_ROOT}" "${LOG_FILE}"
test_summary
