#!/usr/bin/env bash
# tests/test_dist.sh — regression coverage for reproducible release bundles
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

cd "${REPO_ROOT}"

version="$(bash bin/arch-recovery --version | awk '{print $2}')"
archive="dist/arch-system-recovery-v${version}.tar"
tracked_file="README.md"
original_mtime="$(stat -c %y "${tracked_file}")"
manifest="docs/releases/v${version}.manifest"
signature="${manifest}.sig"
MOCK_DIR="$(mktemp -d /tmp/arch-recovery-dist-mocks.XXXXXX)"
BACKUP_DIR="$(mktemp -d /tmp/arch-recovery-dist-backups.XXXXXX)"
export PATH="${MOCK_DIR}:${PATH}"

if [[ -f "${manifest}" ]]; then
    cp "${manifest}" "${BACKUP_DIR}/manifest"
fi
if [[ -f "${signature}" ]]; then
    cp "${signature}" "${BACKUP_DIR}/manifest.sig"
fi

cat > "${MOCK_DIR}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    *"-Y sign"*)
        manifest="${@: -1}"
        printf '%s\n' "mock-signature" > "${manifest}.sig"
        exit 0
        ;;
    *"-Y verify"*)
        exit 0
        ;;
esac

exit 1
EOF
chmod +x "${MOCK_DIR}/ssh-keygen"

cleanup() {
    touch -d "${original_mtime}" "${tracked_file}" 2>/dev/null || true
    if [[ -f "${BACKUP_DIR}/manifest" ]]; then
        cp "${BACKUP_DIR}/manifest" "${manifest}"
    else
        rm -f "${manifest}"
    fi
    if [[ -f "${BACKUP_DIR}/manifest.sig" ]]; then
        cp "${BACKUP_DIR}/manifest.sig" "${signature}"
    else
        rm -f "${signature}"
    fi
    rm -rf "${MOCK_DIR}"
    rm -rf "${BACKUP_DIR}"
}
trap cleanup EXIT

assert_exits_ok make dist

checksum_before="$(sha256sum "${archive}" | awk '{print $1}')"
assert_not_empty "${checksum_before}" "initial dist checksum should exist"
assert_exits_ok tar -tf "${archive}"

listing="$(tar -tf "${archive}")"
assert_contains "${listing}" "arch-system-recovery-${version}/README.md" \
    "dist archive should include README under the versioned root"
assert_exits_ok make release-manifest
assert_exits_ok make dist

checksum_after_manifest="$(sha256sum "${archive}" | awk '{print $1}')"
assert_eq "${checksum_after_manifest}" "${checksum_before}" \
    "dist archive should not change after regenerating signed release manifests"

touch -d '2030-01-01 00:00:00 UTC' "${tracked_file}"

assert_exits_ok make dist

checksum_after="$(sha256sum "${archive}" | awk '{print $1}')"
assert_eq "${checksum_after}" "${checksum_before}" \
    "dist archive should be reproducible across tracked-file mtime changes"

test_summary
