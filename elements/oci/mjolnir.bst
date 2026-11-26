kind: script
description: |
  Final Mjolnir bootc OCI image. The layer is the exact tree that
  uki/mjolnir-uki.bst hashed for the signed UKI. No file is added to it here:
  the signed systemd-boot, the UKI and the kargs are already in that tree, and
  mutating it after signing would invalidate the pinned composefs digest.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/oci-builder.bst
- freedesktop-sdk.bst:components/libcap.bst
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


    # --- build the OCI layout -----------------------------------------------
    # /uki/rootfs is the tree the signed UKI pinned, including its /boot/EFI/
    # Linux UKI and its signed systemd-boot. Do not copy anything into it.
    cd "%{install-root}"
    build-oci <<'EOF'
    mode: oci
    gzip: disabled
    images:
    - os: linux
      architecture: "%{go-arch}"
      layer: /uki/rootfs
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
