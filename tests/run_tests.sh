#!/usr/bin/env bash
# tests/run_tests.sh — test runner for arch-system-recovery
# Discovers and runs all tests/test_*.sh files.
# Does NOT require root. Tests use mocks/stubs for system calls.
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

# ── Counters ──────────────────────────────────────────────────────────────────
TOTAL=0
PASSED=0
FAILED=0
ERRORS=()

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ── run_test_file ─────────────────────────────────────────────────────────────
run_test_file() {
    local file="$1"
    local name
    name="$(basename "${file}" .sh)"

    echo -e "${BOLD}  ▶ ${name}${RESET}"

    # Each test file is sourced in a subshell so failures are isolated
    if (
        export REPO_ROOT
        export TESTS_DIR
        # Provide a stub LOG_FILE so core functions don't need /tmp write
        export LOG_FILE="/dev/null"
        source "${file}"
    ); then
        echo -e "    ${GREEN}✓ passed${RESET}"
        return 0
    else
        echo -e "    ${RED}✗ failed${RESET}"
        return 1
    fi
}

# ── Discovery ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}arch-system-recovery test suite${RESET}"
echo "────────────────────────────────────────"

for test_file in "${TESTS_DIR}"/test_*.sh; do
    if [[ ! -f "${test_file}" ]]; then
        echo "  No test files found matching tests/test_*.sh"
        break
    fi

    TOTAL=$(( TOTAL + 1 ))
    if run_test_file "${test_file}"; then
        PASSED=$(( PASSED + 1 ))
    else
        FAILED=$(( FAILED + 1 ))
        ERRORS+=("$(basename "${test_file}")")
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo "────────────────────────────────────────"
echo -e "  Total:  ${TOTAL}"
echo -e "  ${GREEN}Passed: ${PASSED}${RESET}"
if [[ ${FAILED} -gt 0 ]]; then
    echo -e "  ${RED}Failed: ${FAILED}${RESET}"
    for e in "${ERRORS[@]}"; do
        echo -e "    ${RED}✗ ${e}${RESET}"
    done
    echo ""
    exit 1
else
    echo -e "  ${GREEN}All tests passed.${RESET}"
    echo ""
fi
