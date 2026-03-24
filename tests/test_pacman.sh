#!/usr/bin/env bash
# tests/test_pacman.sh — unit tests for mirrorlist refresh safety
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

FAKE_ROOT="$(mktemp -d /tmp/arch-recovery-pacman-root.XXXXXX)"
export MOUNT_ROOT="${FAKE_ROOT}"
export LOG_FILE="/tmp/test_pacman_$$.log"

mkdir -p "${FAKE_ROOT}/etc/pacman.d"
printf 'Server = https://old.example/\n' > "${FAKE_ROOT}/etc/pacman.d/mirrorlist"

source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/pacman.sh"

_network_available() { return 0; }
_write_mirrorlist_file() {
    local target="$1"
    printf 'Server = https://new.example/\n' > "${target}"
}

_refresh_mirrorlist 2>/dev/null

mirrorlist_content="$(cat "${FAKE_ROOT}/etc/pacman.d/mirrorlist")"
assert_contains "${mirrorlist_content}" "Server = https://new.example/" \
    "successful refresh replaces mirrorlist with staged content"
assert_true "mirrorlist backup is created" \
    bash -c "ls '${FAKE_ROOT}/etc/pacman.d'/mirrorlist.bak.* >/dev/null 2>&1"

: > "${LOG_FILE}"
printf 'Server = https://stable.example/\n' > "${FAKE_ROOT}/etc/pacman.d/mirrorlist"
_write_mirrorlist_file() {
    return 1
}

_refresh_mirrorlist 2>/dev/null

mirrorlist_content="$(cat "${FAKE_ROOT}/etc/pacman.d/mirrorlist")"
assert_contains "${mirrorlist_content}" "Server = https://stable.example/" \
    "failed refresh keeps the previous mirrorlist"
assert_false "failed refresh leaves no staged file behind" \
    test -e "${FAKE_ROOT}/etc/pacman.d/mirrorlist.new"
assert_true "failed refresh is logged as a warning" \
    grep -q "keeping existing mirrorlist" "${LOG_FILE}"

rm -rf "${FAKE_ROOT}" "${LOG_FILE}"
test_summary
