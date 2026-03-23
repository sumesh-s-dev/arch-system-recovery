#!/usr/bin/env bash
# tests/test_repair.sh — unit tests for lib/repair.sh
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

assert_exits_err bash -c "
    export LOG_FILE=/dev/null
    export AUTO_MODE=true
    source '${REPO_ROOT}/lib/core.sh'
    source '${REPO_ROOT}/lib/repair.sh'
    mount_bind() { :; }
    die() { exit 1; }
    repair_bootloader unknown 2>/dev/null
"

auto_out="$(bash -c "
    export LOG_FILE=/dev/null
    export AUTO_MODE=true
    source '${REPO_ROOT}/lib/core.sh'
    source '${REPO_ROOT}/lib/repair.sh'
    mount_bind() { :; }
    die() { echo \"\$*\"; exit 1; }
    repair_bootloader unknown 2>&1
" || true)"
assert_contains "${auto_out}" "Could not auto-detect the bootloader in --auto mode" \
    "auto mode fails fast when bootloader detection is unknown"

rm -f /tmp/test_repair_$$.log 2>/dev/null || true
test_summary
