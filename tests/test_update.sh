#!/usr/bin/env bash
# tests/test_update.sh — unit tests for verified self-update helper parsing
set -euo pipefail

source "${TESTS_DIR}/helpers.sh"

export LOG_FILE="/tmp/test_update_$$.log"
source "${REPO_ROOT}/bin/arch-recovery"

release_json='
{
  "tag_name": "v1.2.3",
  "assets": [
    {
      "name": "arch-system-recovery-v1.2.3.tar.gz",
      "browser_download_url": "https://example.com/arch-system-recovery-v1.2.3.tar.gz"
    },
    {
      "name": "arch-system-recovery-v1.2.3.tar.gz.sha256",
      "browser_download_url": "https://example.com/arch-system-recovery-v1.2.3.tar.gz.sha256"
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
    "arch-system-recovery-v1.2.3.tar.gz" "release bundle name matches convention"
assert_eq "$(_release_bundle_checksum_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.tar.gz.sha256" "checksum asset name matches convention"
assert_eq "$(_release_bundle_manifest_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.manifest" "release manifest name matches convention"
assert_eq "$(_release_bundle_manifest_signature_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.manifest.sig" "release manifest signature name matches convention"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.tar.gz")" \
    "https://example.com/arch-system-recovery-v1.2.3.tar.gz" "release asset URL parser finds bundle"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.tar.gz.sha256")" \
    "https://example.com/arch-system-recovery-v1.2.3.tar.gz.sha256" "release asset URL parser finds checksum"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.manifest")" \
    "https://example.com/arch-system-recovery-v1.2.3.manifest" "release asset URL parser finds manifest"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.manifest.sig")" \
    "https://example.com/arch-system-recovery-v1.2.3.manifest.sig" "release asset URL parser finds manifest signature"

tmpdir="$(mktemp -d /tmp/test-update-sign.XXXXXX)"
ssh-keygen -q -t ed25519 -N "" -f "${tmpdir}/release_key" >/dev/null
printf 'test-signer %s\n' "$(cat "${tmpdir}/release_key.pub")" > "${tmpdir}/allowed_signers"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  archive.tar.gz\n' \
    > "${tmpdir}/manifest"
ssh-keygen -Y sign -f "${tmpdir}/release_key" -n arch-recovery -I test-signer \
    "${tmpdir}/manifest" >/dev/null 2>&1

assert_exits_ok bash -c "
    export LOG_FILE=/dev/null
    export RELEASE_SIGNERS_FILE='${tmpdir}/allowed_signers'
    export RELEASE_SIGNER_PRINCIPAL='test-signer'
    source '${REPO_ROOT}/bin/arch-recovery'
    _verify_release_manifest_signature '${tmpdir}/manifest' '${tmpdir}/manifest.sig'
"

rm -rf "${tmpdir}"
rm -f "${LOG_FILE}"
test_summary
