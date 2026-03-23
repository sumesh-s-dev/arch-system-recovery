#!/usr/bin/env bash
# tests/test_core.sh — unit tests for lib/core.sh
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

export LOG_FILE="/tmp/test_core_$$.log"
source "${REPO_ROOT}/lib/core.sh"
init_log

# version and constants
assert_not_empty "${TOOLKIT_VERSION}"  "TOOLKIT_VERSION should be set"
assert_not_empty "${MOUNT_ROOT}"       "MOUNT_ROOT should be set"
assert_not_empty "${LOG_FILE}"         "LOG_FILE should be set"

default_log_path="$(bash -c "
    unset LOG_FILE SESSION_DIR
    source '${REPO_ROOT}/lib/core.sh'
    init_log
    printf '%s\n' \"\$LOG_FILE\"
")"
assert_contains "${default_log_path}" "/tmp/arch-recovery-session." \
    "init_log defaults to a private session directory"
rm -rf "$(dirname "${default_log_path}")"

# log() writes to LOG_FILE (log writes to stderr AND file)
log "test message alpha" 2>/dev/null
assert_true "log writes to LOG_FILE" \
    grep -q "test message alpha" "${LOG_FILE}"

# err() writes ERROR: prefix to LOG_FILE
err "test error beta" 2>/dev/null
assert_true "err writes ERROR prefix to LOG_FILE" \
    grep -q "ERROR: test error beta" "${LOG_FILE}"

# die() exits non-zero
assert_exits_err bash -c "
    export LOG_FILE=/dev/null
    source '${REPO_ROOT}/lib/core.sh'
    die 'intentional' 2>/dev/null
"

# run_cmd: dry-run skips execution
DRY_RUN=true
TOUCHED="/tmp/test_dryrun_$$"
run_cmd touch "${TOUCHED}" 2>/dev/null
assert_false "dry-run must not create file" test -f "${TOUCHED}"
DRY_RUN=false

# run_cmd: normal mode executes command
TOUCHED2="/tmp/test_run_$$"
run_cmd touch "${TOUCHED2}" 2>/dev/null
assert_true "run_cmd creates file in normal mode" test -f "${TOUCHED2}"
rm -f "${TOUCHED2}"

# warn() does not abort (exits 0)
assert_exits_ok bash -c "
    export LOG_FILE=/dev/null
    source '${REPO_ROOT}/lib/core.sh'
    warn 'just a warning' 2>/dev/null
"

rm -f "${LOG_FILE}"
test_summary
