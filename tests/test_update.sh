#!/usr/bin/env bash
# tests/test_update.sh — unit tests for verified self-update helper parsing
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

export LOG_FILE="/tmp/test_update_$$.log"
MOCK_DIR="$(mktemp -d /tmp/arch-recovery-update-mocks.XXXXXX)"
export PATH="${MOCK_DIR}:${PATH}"
source "${REPO_ROOT}/bin/arch-recovery"

cat > "${MOCK_DIR}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
    *"-Y verify"*)
        exit 0
        ;;
esac

exit 1
EOF
chmod +x "${MOCK_DIR}/ssh-keygen"

release_json='
{
  "tag_name": "v1.2.3",
  "assets": [
    {
      "name": "arch-system-recovery-v1.2.3.tar",
      "browser_download_url": "https://example.com/arch-system-recovery-v1.2.3.tar"
    },
    {
      "name": "arch-system-recovery-v1.2.3.tar.sha256",
      "browser_download_url": "https://example.com/arch-system-recovery-v1.2.3.tar.sha256"
    },
    {
      "name": "arch-system-recovery-v1.2.3.manifest",
      "browser_download_url": "https://example.com/arch-system-recovery-v1.2.3.manifest"
    },
    {
      "name": "arch-system-recovery-v1.2.3.manifest.sig",
      "browser_download_url": "https://example.com/arch-system-recovery-v1.2.3.manifest.sig"
    }
  ]
}
'

assert_eq "$(_latest_release_tag "${release_json}")" "v1.2.3" "latest release tag parser extracts tag"
assert_eq "$(_release_bundle_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.tar" "release bundle name matches convention"
assert_eq "$(_release_bundle_checksum_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.tar.sha256" "checksum asset name matches convention"
assert_eq "$(_release_bundle_manifest_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.manifest" "release manifest name matches convention"
assert_eq "$(_release_bundle_manifest_signature_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.manifest.sig" "release manifest signature name matches convention"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.tar")" \
    "https://example.com/arch-system-recovery-v1.2.3.tar" "release asset URL parser finds bundle"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.tar.sha256")" \
    "https://example.com/arch-system-recovery-v1.2.3.tar.sha256" "release asset URL parser finds checksum"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.manifest")" \
    "https://example.com/arch-system-recovery-v1.2.3.manifest" "release asset URL parser finds manifest"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.manifest.sig")" \
    "https://example.com/arch-system-recovery-v1.2.3.manifest.sig" "release asset URL parser finds manifest signature"

tmpdir="$(mktemp -d /tmp/test-update-sign.XXXXXX)"
printf 'test-signer ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockKeyForUnitTestsOnly\n' \
    > "${tmpdir}/allowed_signers"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  archive.tar\n' \
    > "${tmpdir}/manifest"
printf '%s\n' "mock-signature" > "${tmpdir}/manifest.sig"

assert_exits_ok bash -c "
    export LOG_FILE=/dev/null
    export PATH=\"${MOCK_DIR}:\$PATH\"
    export RELEASE_SIGNERS_FILE='${tmpdir}/allowed_signers'
    export RELEASE_SIGNER_PRINCIPAL='test-signer'
    source '${REPO_ROOT}/bin/arch-recovery'
    _verify_release_manifest_signature '${tmpdir}/manifest' '${tmpdir}/manifest.sig'
"

rm -rf "${tmpdir}"
rm -rf "${MOCK_DIR}"
rm -f "${LOG_FILE}"
test_summary
