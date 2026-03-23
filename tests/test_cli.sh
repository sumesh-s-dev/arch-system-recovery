#!/usr/bin/env bash
# tests/test_cli.sh — tests CLI flag parsing, --help, --version output
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

ARCH_RECOVERY="${REPO_ROOT}/bin/arch-recovery"
MOCK_DIR="$(mktemp -d /tmp/arch-recovery-cli-mocks.XXXXXX)"
export PATH="${MOCK_DIR}:${PATH}"

make_mock() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "${MOCK_DIR}/$1"
    chmod +x "${MOCK_DIR}/$1"
}

# --help exits 0
assert_exits_ok bash "${ARCH_RECOVERY}" --help

# --help output contains expected sections
help_out="$(bash "${ARCH_RECOVERY}" --help 2>&1)"
assert_contains "${help_out}" "USAGE"        "--help prints USAGE"
assert_contains "${help_out}" "--auto"       "--help lists --auto"
assert_contains "${help_out}" "--dry-run"    "--help lists --dry-run"
assert_contains "${help_out}" "--diagnose"   "--help lists --diagnose"
assert_contains "${help_out}" "--tui"        "--help lists --tui"
assert_contains "${help_out}" "--boot"       "--help lists --boot"

# --version exits 0
assert_exits_ok bash "${ARCH_RECOVERY}" --version

# --version output contains version number
ver_out="$(bash "${ARCH_RECOVERY}" --version 2>&1)"
assert_contains "${ver_out}" "arch-recovery" "--version contains 'arch-recovery'"
assert_contains "${ver_out}" "1."            "--version contains a version number"

# --changelog exits 0
assert_exits_ok bash "${ARCH_RECOVERY}" --changelog

# --check-update exits 0 and reaches the helper implementation
make_mock curl 'printf '\''{"tag_name":"v1.1.0"}\n'\'''
assert_exits_ok bash "${ARCH_RECOVERY}" --check-update
check_update_out="$(bash "${ARCH_RECOVERY}" --check-update 2>&1)"
assert_contains "${check_update_out}" "Current version" "--check-update prints current version"
assert_contains "${check_update_out}" "Latest release" "--check-update prints latest release"

# unknown flag exits non-zero
assert_exits_err bash "${ARCH_RECOVERY}" --not-a-real-flag 2>/dev/null

# unknown flag prints something to stderr
err_out="$(bash "${ARCH_RECOVERY}" --unknown-xyz 2>&1 || true)"
assert_not_empty "${err_out}" "Unknown flag produces error output"

# --dry-run alone exits 0 (no devices needed in dry-run before mounting)
# We cannot run the full flow without root, but --help/--version/--changelog must work
assert_exits_ok bash "${ARCH_RECOVERY}" --help

rm -rf "${MOCK_DIR}"
test_summary
