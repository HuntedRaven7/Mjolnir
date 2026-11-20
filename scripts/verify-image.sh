#!/usr/bin/env bash
# Verify image signature, legacy .sig tag and SBOM attestation.
set -euo pipefail
IMAGE="${1:-ghcr.io/HuntedRaven7/Mjolnir:testing}"
DIGEST="${2:-}"
OWNER="${GITHUB_REPOSITORY_OWNER:-HuntedRaven7}"
IDENTITY="^https://github\.com/${OWNER}/Mjolnir/\.github/workflows/build\.yml@refs/heads/(testing|gh-readonly-queue/testing/.+)$"
ISSUER="https://token.actions.githubusercontent.com"

[ -n "$DIGEST" ] || { echo "usage: $0 IMAGE DIGEST" >&2; exit 2; }
REF="${IMAGE%:*}@${DIGEST}"

echo "==> verifying image signature"
cosign verify --new-bundle-format=false \
  --certificate-identity-regexp "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" "$REF" >/dev/null
echo "PASS: image signature"

echo "==> verifying legacy .sig tag (bootc/podman compatibility)"
cosign download signature "$REF" >/dev/null
echo "PASS: legacy .sig tag present"

echo "==> checking SBOM attestation"
if cosign verify-attestation --type https://spdx.dev/Document/v2.3 \
    --certificate-identity-regexp "$IDENTITY" \
    --certificate-oidc-issuer "$ISSUER" "$REF" >/dev/null 2>&1; then
  echo "PASS: SPDX SBOM attestation"
else
  echo "WARN: no SPDX v2.3 attestation on this image"
fi
