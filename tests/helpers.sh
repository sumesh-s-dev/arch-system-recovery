#!/usr/bin/env bash
# tests/helpers.sh — minimal assertion library for arch-recovery tests
# Source this file at the top of each test_*.sh file.
#
# Available assertions:
#   assert_eq       ACTUAL EXPECTED [msg]
#   assert_contains HAYSTACK NEEDLE [msg]
#   assert_empty    VALUE            [msg]
#   assert_not_empty VALUE           [msg]
#   assert_true     CMD...           [msg]
#   assert_false    CMD...           [msg]
#   assert_exits_ok CMD...
#   assert_exits_err CMD...

# ── Assertion counters (per test file) ────────────────────────────────────────
_ASSERT_PASS=0
_ASSERT_FAIL=0

# ── Internal: _fail ───────────────────────────────────────────────────────────
_fail() {
    local msg="${1}"
    echo "      FAIL: ${msg}" >&2
    _ASSERT_FAIL=$(( _ASSERT_FAIL + 1 ))
    # Propagate failure to test runner
    return 1
}

_pass() {
    _ASSERT_PASS=$(( _ASSERT_PASS + 1 ))
}

# ── assert_eq ─────────────────────────────────────────────────────────────────
assert_eq() {
    local actual="${1}"
    local expected="${2}"
    local msg="${3:-assert_eq}"
    if [[ "${actual}" == "${expected}" ]]; then
        _pass
    else
        _fail "${msg}: expected '${expected}', got '${actual}'"
    fi
}

# ── assert_contains ───────────────────────────────────────────────────────────
assert_contains() {
    local haystack="${1}"
    local needle="${2}"
    local msg="${3:-assert_contains}"
    if [[ "${haystack}" == *"${needle}"* ]]; then
        _pass
    else
        _fail "${msg}: '${haystack}' does not contain '${needle}'"
    fi
}

# ── assert_empty ──────────────────────────────────────────────────────────────
assert_empty() {
    local value="${1}"
    local msg="${2:-assert_empty}"
    if [[ -z "${value}" ]]; then
        _pass
    else
        _fail "${msg}: expected empty, got '${value}'"
    fi
}

# ── assert_not_empty ──────────────────────────────────────────────────────────
assert_not_empty() {
    local value="${1}"
    local msg="${2:-assert_not_empty}"
    if [[ -n "${value}" ]]; then
        _pass
    else
        _fail "${msg}: expected non-empty value"
    fi
}

# ── assert_true ───────────────────────────────────────────────────────────────
# assert_true MSG CMD [ARGS...]
# First argument is the human-readable description; rest is the command.
assert_true() {
    local msg="${1}"; shift
    if "$@" 2>/dev/null; then
        _pass
    else
        _fail "assert_true [${msg}]: command returned non-zero: ${*}"
    fi
}

# ── assert_false ──────────────────────────────────────────────────────────────
# assert_false MSG CMD [ARGS...]
assert_false() {
    local msg="${1}"; shift
    if ! "$@" 2>/dev/null; then
        _pass
    else
        _fail "assert_false [${msg}]: command returned zero (expected failure): ${*}"
    fi
}

# ── assert_exits_ok ───────────────────────────────────────────────────────────
# Runs command in a subshell; asserts exit code 0
assert_exits_ok() {
    if ( "$@" >/dev/null 2>&1 ); then
        _pass
    else
        _fail "assert_exits_ok: '${*}' exited non-zero"
    fi
}

# ── assert_exits_err ──────────────────────────────────────────────────────────
# Runs command in a subshell; asserts exit code != 0
assert_exits_err() {
    if ! ( "$@" >/dev/null 2>&1 ); then
        _pass
    else
        _fail "assert_exits_err: '${*}' exited zero (expected failure)"
    fi
}

# ── summary (called at end of each test file) ─────────────────────────────────
test_summary() {
    local file="${BASH_SOURCE[1]:-unknown}"
    echo "      assertions: ${_ASSERT_PASS} passed, ${_ASSERT_FAIL} failed"
    if [[ ${_ASSERT_FAIL} -gt 0 ]]; then
        return 1
    fi
}
