kind: script
description: |
  Final Mjolnir bootc OCI image. It consumes the sanitized rootfs from
  oci/rootfs.bst (the exact tree whose composefs digest is pinned in the signed
  UKI) and adds the signed boot artifacts before build-oci turns it into an OCI
  layout with bootc labels.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/oci-builder.bst
- freedesktop-sdk.bst:components/libcap.bst
- filename: oci/rootfs.bst
  config:
    location: /rootfs
- filename: uki/mjolnir-uki.bst
  config:
    location: /uki

variables:
  strip-binaries: ''
  image-repo: mjolnir
  sysroot-seed: 2b6e2ba0-6f4a-4d32-9a08-6f0f0f0f0f01

config:
  commands:
  - |
    set -eu
    root=/rootfs

    # --- sealed boot: signed UKI with the composefs digest pinned -----------
    # bootc's composefs backend detects /boot/EFI/Linux/*.efi and installs it
    # to the ESP; the signed .cmdline carries the exact rootfs digest.
    mkdir -p "${root}/boot/EFI/Linux"
    cp -a /uki/boot/EFI/Linux/. "${root}/boot/EFI/Linux/"
    mkdir -p "${root}/usr/lib/systemd/boot/efi"
    cp -a /uki/usr/lib/systemd/boot/efi/. "${root}/usr/lib/systemd/boot/efi/"
    mkdir -p "${root}/usr/share/mjolnir"
    cp /uki/usr/share/mjolnir/composefs-digest.txt "${root}/usr/share/mjolnir/"

    # --- build the OCI layout -----------------------------------------------
    cd "%{install-root}"
    build-oci <<'EOF'
    mode: oci
    gzip: disabled
    images:
    - os: linux
      architecture: "%{go-arch}"
      layer: /rootfs
      comment: "Import Mjolnir layer"
      config:
        Labels:
          'containers.bootc': '1'
          'org.opencontainers.image.title': 'Mjolnir'
          'org.opencontainers.image.description': 'FSDK-based hardened Kubernetes server'
          'org.opencontainers.image.vendor': 'Mjolnir'
          'org.opencontainers.image.licenses': 'Apache-2.0'
      index-annotations:
        'org.opencontainers.image.ref.name': 'ghcr.io/quinn/mjolnir:%{branch}'
    EOF
