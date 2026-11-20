#!/usr/bin/env bash
# Reproducibly build the pinned varlink-httpd binary(ies) for the image.
# The upstream project publishes no release tarballs, so we compile a pinned
# commit with a pinned Rust toolchain container. Cross-compilation uses the
# Debian aarch64 cross sysroot (libssl-dev:arm64) for the arm64 target.
set -euo pipefail

COMMIT=$(grep 'varlink-bridge-commit' include/versions.yml | sed -E 's/.*"(.*)"/\1/')
OUT_DIR="${OUT_DIR:-files/varlink}"
WORK="${WORK:-/var/tmp/varlink-build}"
ARCH="${1:-amd64}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

if [ "$ARCH" = arm64 ]; then
  RUST_TARGET="aarch64-unknown-linux-gnu"
  GCC_PKG="gcc-aarch64-linux-gnu"
  LINKER="aarch64-linux-gnu-gcc"
  LIBSSL="libssl-dev:arm64"
else
  RUST_TARGET="x86_64-unknown-linux-gnu"
  GCC_PKG="gcc"
  LINKER="cc"
  LIBSSL="libssl-dev"
fi

echo "==> building varlink-httpd for $ARCH ($RUST_TARGET) at $COMMIT"
rm -rf "$WORK"
mkdir -p "$WORK/out"
git clone --quiet https://github.com/systemd/varlink-http-bridge.git "$WORK/src"
git -C "$WORK/src" checkout --quiet "$COMMIT"
test "$(git -C "$WORK/src" rev-parse HEAD)" = "$COMMIT"

podman run --rm \
  -v "$WORK/src:/src:Z" -v "$WORK/out:/out:Z" \
  -w /src \
  -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
  docker.io/rust:1.90.0-slim \
  bash -c "dpkg --add-architecture arm64 && \\
           apt-get update -qq && \\
           apt-get install -y -qq pkg-config $GCC_PKG $LIBSSL >/dev/null && \\
           rustup target add $RUST_TARGET && \\
           export PKG_CONFIG_ALLOW_CROSS=1 && \\
           export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig && \\
           export PKG_CONFIG_SYSROOT_DIR=/ && \\
           export OPENSSL_LIB_DIR=/usr/lib/aarch64-linux-gnu && \\
           export OPENSSL_INCLUDE_DIR=/usr/include && \\
           export CARGO_TARGET_$(echo $RUST_TARGET | tr 'a-z-' 'A-Z_')_LINKER=$LINKER && \\
           cargo build --release --locked --bin varlink-httpd --target $RUST_TARGET && \\
           cp target/$RUST_TARGET/release/varlink-httpd /out/"

install -Dm755 "$WORK/out/varlink-httpd" "$OUT_DIR/varlink-httpd-$ARCH"
sha256sum "$OUT_DIR/varlink-httpd-$ARCH"
echo "Update include/versions.yml with the sha256 above."
