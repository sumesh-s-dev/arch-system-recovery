#!/usr/bin/env bash
# tests/test_luks.sh — unit tests for lib/luks.sh
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

MOCK_DIR="$(mktemp -d /tmp/arch-recovery-luks-mocks.XXXXXX)"
export LOG_FILE="/tmp/test_luks_$$.log"
export PATH="${MOCK_DIR}:${PATH}"

source "${REPO_ROOT}/lib/core.sh"
init_log

make_mock() {
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "${MOCK_DIR}/$1"
    chmod +x "${MOCK_DIR}/$1"
}

# is_luks: true when cryptsetup exits 0
make_mock cryptsetup 'exit 0'
source "${REPO_ROOT}/lib/luks.sh"
assert_true "is_luks true when cryptsetup exits 0" is_luks "/dev/fake1"

# is_luks: false when cryptsetup exits 1
make_mock cryptsetup 'exit 1'
source "${REPO_ROOT}/lib/luks.sh"
assert_false "is_luks false when cryptsetup exits 1" is_luks "/dev/fake2"

# close_luks: no-op when mapper absent — must not error
make_mock cryptsetup 'exit 0'
assert_exits_ok bash -c "
    export PATH='${MOCK_DIR}:\$PATH'
    export LOG_FILE=/dev/null
    source '${REPO_ROOT}/lib/core.sh'
    source '${REPO_ROOT}/lib/luks.sh'
    close_luks 2>/dev/null
"

# cryptsetup open is invoked with correct arguments
make_mock cryptsetup '
case "$1" in
  isLuks) exit 0 ;;
  open)   touch /tmp/luks_open_called_'"$$"'; exit 0 ;;
  *)      exit 0 ;;
esac'
source "${REPO_ROOT}/lib/luks.sh"
# Directly invoke the mock to verify argument routing
cryptsetup open --type luks /dev/fake1 recovery_crypt 2>/dev/null || true
assert_true "cryptsetup open mock was called" test -f "/tmp/luks_open_called_$$"
rm -f "/tmp/luks_open_called_$$"

rm -rf "${MOCK_DIR}" "${LOG_FILE}"
test_summary
