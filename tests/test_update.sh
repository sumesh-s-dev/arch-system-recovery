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
    }
  ]
}
'

assert_eq "$(_latest_release_tag "${release_json}")" "v1.2.3" "latest release tag parser extracts tag"
assert_eq "$(_release_bundle_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.tar.gz" "release bundle name matches convention"
assert_eq "$(_release_bundle_checksum_name "v1.2.3")" \
    "arch-system-recovery-v1.2.3.tar.gz.sha256" "checksum asset name matches convention"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.tar.gz")" \
    "https://example.com/arch-system-recovery-v1.2.3.tar.gz" "release asset URL parser finds bundle"
assert_eq "$(_release_asset_url "${release_json}" "arch-system-recovery-v1.2.3.tar.gz.sha256")" \
    "https://example.com/arch-system-recovery-v1.2.3.tar.gz.sha256" "release asset URL parser finds checksum"

rm -f "${LOG_FILE}"
test_summary
