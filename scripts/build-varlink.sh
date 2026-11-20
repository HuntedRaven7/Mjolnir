#!/usr/bin/env bash
set -euo pipefail
WORK=${WORK:-/var/tmp/varlink-build}
COMMIT=f14cc14e8ab5143ebf67140cbd884d703a0567be
rm -rf "$WORK"
mkdir -p "$WORK/out"
git clone --quiet https://github.com/systemd/varlink-http-bridge.git "$WORK/src"
git -C "$WORK/src" checkout --quiet "$COMMIT"
test "$(git -C "$WORK/src" rev-parse HEAD)" = "$COMMIT"
# Build against a pinned Rust toolchain. OpenSSL is used for native TLS/mTLS
# support (rustls is deliberately avoided upstream for binary size).
podman pull --quiet docker.io/library/rust:1.90.0-slim >/dev/null
podman run --rm \
  -v "$WORK/src:/src:Z" -v "$WORK/out:/out:Z" \
  -w /src docker.io/library/rust:1.90.0-slim \
  bash -c 'apt-get update -qq && apt-get install -y -qq pkg-config libssl-dev >/dev/null && cargo build --release --locked --bin varlink-httpd && cp target/release/varlink-httpd /out/'
strip "$WORK/out/varlink-httpd"
sha256sum "$WORK/out/varlink-httpd"
