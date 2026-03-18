#!/usr/bin/env bash
# tests/test_fstab.sh — unit tests for lib/fstab.sh
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

export LOG_FILE="/tmp/test_fstab_$$.log"
MOCK_DIR="$(mktemp -d /tmp/arch-recovery-fstab-mocks.XXXXXX)"

make_mock() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "${MOCK_DIR}/$1"
    chmod +x "${MOCK_DIR}/$1"
}

# MOUNT_ROOT must be exported BEFORE sourcing core.sh to avoid readonly clash
FAKE_ROOT="$(mktemp -d /tmp/test-fstab-root.XXXXXX)"
mkdir -p "${FAKE_ROOT}/etc"
export MOUNT_ROOT="${FAKE_ROOT}"  # set before source so guard skips readonly
export PATH="${MOCK_DIR}:${PATH}"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/fstab.sh"
init_log

# ── Helper: write fstab and run validation ────────────────────────────────────
_write_fstab() { printf '%s\n' "$1" > "${FAKE_ROOT}/etc/fstab"; }
_remove_fstab() { rm -f "${FAKE_ROOT}/etc/fstab"; }

# ── Test: no fstab — warns but exits 0 ───────────────────────────────────────
_remove_fstab
assert_exits_ok validate_and_repair_fstab

# ── Test: valid tmpfs-only fstab — exits 0 ───────────────────────────────────
make_mock blkid 'exit 0'
_write_fstab "tmpfs /tmp tmpfs defaults,noatime 0 0"
assert_exits_ok validate_and_repair_fstab

# ── Test: stale UUID gets commented out ───────────────────────────────────────
# blkid exits 1 → UUID not found → line should become #REMOVED
make_mock blkid 'exit 1'
_write_fstab "UUID=deadbeef-0000-0000-0000-000000000000 / ext4 defaults 0 1"
validate_and_repair_fstab 2>/dev/null || true
assert_true "stale UUID line commented out" \
    grep -q "#REMOVED" "${FAKE_ROOT}/etc/fstab"

# ── Test: backup file created alongside fstab ─────────────────────────────────
make_mock blkid 'exit 0'
_write_fstab "tmpfs /tmp tmpfs defaults 0 0"
validate_and_repair_fstab 2>/dev/null
BACKUP_COUNT="$(find "${FAKE_ROOT}/etc" -name 'fstab.bak.*' | wc -l)"
assert_true "backup file created" test "${BACKUP_COUNT}" -ge 1

# ── Test: comment lines are not flagged ───────────────────────────────────────
make_mock blkid 'exit 1'  # would flag any real UUID
_write_fstab "# UUID=deadbeef-0000-0000-0000-000000000000 / ext4 defaults 0 1"
validate_and_repair_fstab 2>/dev/null || true
# The comment line must NOT have been re-commented as #REMOVED
REMOVED_COUNT="$(grep -c "^#REMOVED" "${FAKE_ROOT}/etc/fstab" 2>/dev/null || true)"
assert_eq "${REMOVED_COUNT}" "0" "comment UUID lines not flagged as stale"

# ── Test: PARTUUID= stale entry gets commented out ────────────────────────────
make_mock blkid 'exit 1'
_write_fstab "PARTUUID=cafebabe-dead-beef-cafe-babecafebeef /boot/efi vfat defaults 0 2"
validate_and_repair_fstab 2>/dev/null || true
assert_true "stale PARTUUID line commented out" \
    grep -q "#REMOVED" "${FAKE_ROOT}/etc/fstab"

# ── Test: valid UUID passes without commenting ────────────────────────────────
make_mock blkid 'exit 0'  # UUID found
_write_fstab "UUID=aabbccdd-1234-5678-9abc-def012345678 / ext4 defaults 0 1"
validate_and_repair_fstab 2>/dev/null
REMOVED="$(grep -c "^#REMOVED" "${FAKE_ROOT}/etc/fstab" 2>/dev/null || true)"
assert_eq "${REMOVED}" "0" "valid UUID is not removed"

rm -rf "${MOCK_DIR}" "${FAKE_ROOT}" "${LOG_FILE}"
test_summary
