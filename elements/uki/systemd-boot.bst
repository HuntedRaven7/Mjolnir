kind: manual
description: |
  SIGNING-ONLY. Signs the FSDK systemd-boot loader with the production DB key.
  The signed binary is consumed by oci/rootfs.bst so that it is part of the
  exact tree whose composefs digest is pinned in the signed UKI. No key
  material is copied into this element's artifact.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/systemd.bst
- filename: uki/boot-keys.bst
  config:
    location: /boot-keys
variables:
  strip-binaries: ''
config:
  install-commands:
  - |
    set -eu
    export TMPDIR=/tmp
    WORK=/tmp/mjolnir-systemd-boot
    mkdir -p "$WORK/keys" "%{install-root}/usr/lib/systemd/boot/efi"
    cp /boot-keys/VENDOR.key /boot-keys/VENDOR.crt "$WORK/keys/"
    chmod 0600 "$WORK/keys/"*.key

    SRC="/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi"
    test -f "$SRC"
    /usr/lib/systemd/systemd-sbsign sign \
      --private-key="$WORK/keys/VENDOR.key" \
      --certificate="$WORK/keys/VENDOR.crt" \
      --output="%{install-root}/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi.signed" \
      "$SRC"
    test -s "%{install-root}/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi.signed"
