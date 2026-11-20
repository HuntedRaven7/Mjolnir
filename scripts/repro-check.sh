#!/usr/bin/env bash
# Build the final BST element twice from scratch and compare:
#   1. the BuildStream artifact CAS digest (rootfs bytes), and
#   2. a hash of the complete OCI layout (layers, config, annotations).
# Both must match for the build to be reproducible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ELEMENT="${ELEMENT:-oci/mjolnir.bst}"
OUT=.repro
mkdir -p "$OUT"

build_once() {
  local n="$1"
  rm -rf "$OUT/oci-$n"
  just bst artifact delete "$ELEMENT" >/dev/null 2>&1 || true
  just bst build --ignore-project-artifact-remotes --artifact-remote invalid "$ELEMENT" >/dev/null
  just bst show --deps none --format '%{artifact-cas-digest}' "$ELEMENT" > "$OUT/cas-$n.txt"
  just bst artifact checkout "$ELEMENT" --directory "/src/$OUT/oci-$n" >/dev/null
  (cd "$OUT/oci-$n" && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
    | sha256sum | awk '{print $1}' > "$OUT/layout-$n.sha"
  echo "build $n: CAS=$(cat "$OUT/cas-$n.txt") OCI=$(cat "$OUT/layout-$n.sha")"
}

build_once 1
build_once 2

if ! diff -u "$OUT/cas-1.txt" "$OUT/cas-2.txt"; then
  echo "::error::BuildStream artifact CAS digests differ between builds" >&2
  exit 1
fi
if ! diff -u "$OUT/layout-1.sha" "$OUT/layout-2.sha"; then
  echo "::error::OCI layouts differ between builds" >&2
  exit 1
fi
echo "Reproducibility check passed"
