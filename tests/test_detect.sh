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

rm -rf "${MOCK_DIR}" "${FAKE_ROOT}" "${LOG_FILE}"
test_summary
