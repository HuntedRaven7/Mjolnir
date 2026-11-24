kind: script
description: |
  Final Mjolnir bootc OCI image. It consumes the complete rootfs from
  oci/rootfs.bst (the exact tree whose composefs digest is pinned in both
  signed UKIs) and adds only /boot artifacts before build-oci turns it into an
  OCI layout with bootc labels. composefs empties /boot before hashing, so the
  added UKIs cannot invalidate the digest.

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
    # Only /boot is modified here. The signed systemd-boot loader is already
    # part of oci/rootfs.bst, so the tree hashed by bootc is unchanged.
    # bootc detects the single UKI in /boot/EFI/Linux and installs it to the
    # ESP; the signed .cmdline carries the exact rootfs digest.
    mkdir -p "${root}/boot/EFI/Linux" "${root}/boot/mjolnir-debug"
    cp -a /uki/boot/EFI/Linux/. "${root}/boot/EFI/Linux/"
    cp -a /uki/boot/mjolnir-debug/. "${root}/boot/mjolnir-debug/"
    cp /uki/boot/mjolnir-composefs-digest.txt "${root}/boot/"

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
