#!/usr/bin/env bash
# tests/test_tui.sh — unit tests for lib/tui.sh bash fallback helpers
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

export LOG_FILE="/tmp/test_tui_$$.log"
source "${REPO_ROOT}/lib/core.sh"
source "${REPO_ROOT}/lib/tui.sh"
init_log

contains_line() {
    local value="$1" needle="$2"
    printf '%s\n' "${value}" | grep -qx "${needle}"
}

default_choices="$(
    _tui_checklist bash "Select Repairs" "Choose what to repair:" \
        "INITRAMFS" "Rebuild initramfs" ON \
        "BOOTLOADER" "Reinstall bootloader" ON \
        "FSTAB" "Validate /etc/fstab" ON \
        "KEYRING" "Repair pacman keyring" OFF <<< ""
)"

assert_true "default checklist keeps INITRAMFS selected" contains_line "${default_choices}" "INITRAMFS"
assert_true "default checklist keeps BOOTLOADER selected" contains_line "${default_choices}" "BOOTLOADER"
assert_true "default checklist keeps FSTAB selected" contains_line "${default_choices}" "FSTAB"
assert_false "default checklist excludes KEYRING" contains_line "${default_choices}" "KEYRING"

toggled_choices="$(
    _tui_checklist bash "Select Repairs" "Choose what to repair:" \
        "INITRAMFS" "Rebuild initramfs" ON \
        "BOOTLOADER" "Reinstall bootloader" ON \
        "FSTAB" "Validate /etc/fstab" ON \
        "KEYRING" "Repair pacman keyring" OFF <<< "2 4"
)"

assert_false "toggle removes BOOTLOADER" contains_line "${toggled_choices}" "BOOTLOADER"
assert_true "toggle adds KEYRING" contains_line "${toggled_choices}" "KEYRING"

rm -f "${LOG_FILE}"
test_summary
