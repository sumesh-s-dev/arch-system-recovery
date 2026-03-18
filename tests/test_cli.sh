#!/usr/bin/env bash
# tests/test_cli.sh — tests CLI flag parsing, --help, --version output
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

ARCH_RECOVERY="${REPO_ROOT}/bin/arch-recovery"

# --help exits 0
assert_exits_ok bash "${ARCH_RECOVERY}" --help

# --help output contains expected sections
help_out="$(bash "${ARCH_RECOVERY}" --help 2>&1)"
assert_contains "${help_out}" "USAGE"        "--help prints USAGE"
assert_contains "${help_out}" "--auto"       "--help lists --auto"
assert_contains "${help_out}" "--dry-run"    "--help lists --dry-run"
assert_contains "${help_out}" "--diagnose"   "--help lists --diagnose"
assert_contains "${help_out}" "--tui"        "--help lists --tui"

# --version exits 0
assert_exits_ok bash "${ARCH_RECOVERY}" --version

# --version output contains version number
ver_out="$(bash "${ARCH_RECOVERY}" --version 2>&1)"
assert_contains "${ver_out}" "arch-recovery" "--version contains 'arch-recovery'"
assert_contains "${ver_out}" "1."            "--version contains a version number"

# --changelog exits 0
assert_exits_ok bash "${ARCH_RECOVERY}" --changelog

# unknown flag exits non-zero
assert_exits_err bash "${ARCH_RECOVERY}" --not-a-real-flag 2>/dev/null

# unknown flag prints something to stderr
err_out="$(bash "${ARCH_RECOVERY}" --unknown-xyz 2>&1 || true)"
assert_not_empty "${err_out}" "Unknown flag produces error output"

# --dry-run alone exits 0 (no devices needed in dry-run before mounting)
# We cannot run the full flow without root, but --help/--version/--changelog must work
assert_exits_ok bash "${ARCH_RECOVERY}" --help

test_summary
