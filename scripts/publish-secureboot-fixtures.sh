#!/usr/bin/env bash
# Publish the three Secure Boot unlock fixtures to a stable GitHub Release.
# The release tag is an asset namespace, not an image release: assets are
# refreshed from each successful testing build, so Gram's curl URLs never move.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

DIR="${1:?usage: publish-secureboot-fixtures.sh FIXTURES_DIR}"
TAG="secureboot-fixtures-v1"
REPO="${GITHUB_REPOSITORY:-HuntedRaven7/Mjolnir}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

for f in OVMF_VARS.enrolled.fd uki-signed.efi uki-unknown.efi SHA256SUMS; do
  [ -s "$DIR/$f" ] || fail "missing fixture: $DIR/$f"
done
(cd "$DIR" && sha256sum -c SHA256SUMS) || fail "fixture checksum mismatch"

command -v gh >/dev/null || fail "gh is required"

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
cat >"$NOTES" <<EOF
## Secure Boot unlock fixtures

Stable base URL for these three assets:

\`${BASE}\`

| Asset | Purpose |
| --- | --- |
| \`OVMF_VARS.enrolled.fd\` | Blank OVMF varstore with VENDOR and DEBUG certs enrolled in PK/KEK/db, Secure Boot on. Copy fresh per boot case. |
| \`uki-signed.efi\` | Production VENDOR-signed UKI with the PCR 11 signature that unseals MjolnirState. |
| \`uki-unknown.efi\` | DEBUG-signed UKI with a different PCR signing key; passes firmware, fails PCR unseal. |

Checksums are in \`SHA256SUMS\`. No private keys are published. These assets
track the latest successful \`testing\` build. Regeneration is documented at
https://github.com/${REPO}/blob/testing/docs/SECUREBOOT-FIXTURES.md
EOF

if ! gh release view "$TAG" >/dev/null 2>&1; then
  gh release create "$TAG" --target "${GITHUB_SHA:-testing}" \
    --title "Secure Boot unlock fixtures" --notes-file "$NOTES" \
    || fail "could not create release $TAG"
else
  gh release edit "$TAG" --notes-file "$NOTES" || fail "could not update release notes"
fi

gh release upload "$TAG" \
  "$DIR/OVMF_VARS.enrolled.fd" \
  "$DIR/uki-signed.efi" \
  "$DIR/uki-unknown.efi" \
  "$DIR/SHA256SUMS" \
  --clobber || fail "could not upload release assets"

for f in OVMF_VARS.enrolled.fd uki-signed.efi uki-unknown.efi SHA256SUMS; do
  gh release view "$TAG" --json assets --jq ".assets[].name" | grep -Fxq "$f" || \
    fail "asset $f is missing from release $TAG"
done
echo "Published fixtures at $BASE"
