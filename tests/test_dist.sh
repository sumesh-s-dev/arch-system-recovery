#!/usr/bin/env bash
# tests/test_dist.sh — regression coverage for reproducible release bundles
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

cd "${REPO_ROOT}"

version="$(bash bin/arch-recovery --version | awk '{print $2}')"
archive="dist/arch-system-recovery-v${version}.tar.gz"
tracked_file="README.md"
original_mtime="$(stat -c %y "${tracked_file}")"

cleanup() {
    touch -d "${original_mtime}" "${tracked_file}" 2>/dev/null || true
}
trap cleanup EXIT

assert_exits_ok make dist

checksum_before="$(sha256sum "${archive}" | awk '{print $1}')"
assert_not_empty "${checksum_before}" "initial dist checksum should exist"
assert_exits_ok tar -tzf "${archive}"

listing="$(tar -tzf "${archive}")"
assert_contains "${listing}" "arch-system-recovery-${version}/README.md" \
    "dist archive should include README under the versioned root"

touch -d '2030-01-01 00:00:00 UTC' "${tracked_file}"

assert_exits_ok make dist

checksum_after="$(sha256sum "${archive}" | awk '{print $1}')"
assert_eq "${checksum_after}" "${checksum_before}" \
    "dist archive should be reproducible across tracked-file mtime changes"

test_summary
