#!/usr/bin/env bash
# tests/test_main.sh — regression tests for entrypoint helper behavior
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

rollback_log="/tmp/test_main_rollback_$$.log"
rollback_out="$(bash -c "
    export LOG_FILE='${rollback_log}'
    export DRY_RUN=true
    source '${REPO_ROOT}/bin/arch-recovery'
    _save_rollback_plan \
        '/dev/nvme0n1p2' '/dev/mapper/vg0-root' '/dev/nvme0n1p1' '/dev/nvme0n1p1' \
        'grub' '/boot' true true
    cat '${rollback_log}'
")"

assert_contains "${rollback_out}" "cryptsetup open /dev/nvme0n1p2 recovery_crypt" \
    "rollback plan includes LUKS reopen instructions"
assert_contains "${rollback_out}" "vgchange -ay" \
    "rollback plan includes LVM activation instructions"
assert_contains "${rollback_out}" "mount /dev/mapper/vg0-root /mnt" \
    "rollback plan mounts the mapped root device"
assert_contains "${rollback_out}" "mount /dev/nvme0n1p1 /mnt/boot" \
    "rollback plan uses the detected EFI mountpoint"
assert_contains "${rollback_out}" "--efi-directory=/boot" \
    "rollback plan reuses the detected GRUB EFI directory"

rm -f "${rollback_log}"
test_summary
