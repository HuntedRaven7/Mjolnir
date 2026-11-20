kind: manual
description: |
  SIGNING-ONLY. Builds a signed, composefs-digest-pinned UKI with bootc's
  ukify integration. The digest is computed from the exact final rootfs and
  baked into the signed .cmdline section, so Secure Boot trusts the root.
  NEVER add this element to a runtime stack (its artifact contains key material
  via boot-keys.bst). The resulting EFI is copied into the OCI by oci/mjolnir.bst.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/systemd-ukify.bst
- freedesktop-sdk.bst:components/_private/sbsigntools.bst
- freedesktop-sdk.bst:components/binutils.bst
- freedesktop-sdk.bst:components/systemd.bst
- mgmt/bootc.bst
- filename: kernel/initramfs.bst
  config:
    location: /kernel
- filename: oci/layers/mjolnir.bst
  config:
    location: /layer
- filename: uki/boot-keys.bst
  config:
    location: /boot-keys
variables:
  strip-binaries: ''
config:
  install-commands:
  - |
    set -eu
    mkdir -p /work/kernel /work/rootfs /tmp "%{install-root}/boot/EFI/Linux"
    # bootc computes the composefs digest from the final rootfs and generates
    # the `.cmdline` (including the v1 digest + v2 fallback and our kargs.d
    # entries such as systemd.volatile=yes). No kargs may be passed at install.
    bootc container split-kernel-and-rootfs --rootfs /layer --output /work/kernel
    kver=$(cat /kernel/usr/lib/mjolnir-kernel-version)
    test -f "/work/kernel/${kver}/vmlinuz"
    test -f "/work/kernel/${kver}/initramfs.img"
    bootc container ukify --rootfs /layer --kernel-dir "/work/kernel/${kver}" \
      -- --output "/work/mjolnir.efi" \
      --uname "${kver}" \
      --signtool=systemd-sbsign --no-sign-kernel \
      --secureboot-private-key=/boot-keys/VENDOR.key \
      --secureboot-certificate=/boot-keys/VENDOR.crt
    # Assert the signature and that the digest was baked into the cmdline.
    sbverify --cert /boot-keys/VENDOR.crt /work/mjolnir.efi
    objcopy -O binary -j .cmdline /work/mjolnir.efi /work/cmdline.txt
    grep -q 'composefs' /work/cmdline.txt
    grep -q 'systemd.volatile=yes' /work/cmdline.txt
    install -Dm644 /work/mjolnir.efi \
      "%{install-root}/boot/EFI/Linux/mjolnir-${kver}.efi"
    # Sign systemd-boot so Secure Boot can load the loader; bootctl prefers
    # the .signed variant.
    systemd-sbsign sign \
      --private-key=/boot-keys/VENDOR.key \
      --certificate=/boot-keys/VENDOR.crt \
      --output="%{install-root}/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi.signed" \
      "/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi"
    # The composefs digest for attestation/verification.
    bootc container compute-composefs-digest /layer > "%{install-root}/usr/share/mjolnir/composefs-digest.txt"
