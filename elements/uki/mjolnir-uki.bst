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
- filename: oci/rootfs.bst
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
    # The BST sandbox root is FUSE and cannot read xattrs (listxattr returns
    # ENOTSUP), which bootc's composefs scanner requires. Copy the rootfs onto
    # /tmp (tmpfs) where xattrs work. The composefs transform only keeps
    # security.capability, so tmpfs's lack of persistent security.* xattrs is
    # harmless. /var/tmp is needed by bootc for its temp repo; our patched
    # bootc honours TMPDIR, which we point at the writable /tmp.
    export TMPDIR=/tmp
    WORK=/tmp/mjolnir-uki
    ROOTFS="$WORK/rootfs"
    mkdir -p "$WORK" "${ROOTFS}" "$WORK/keys" \
      "%{install-root}/boot/EFI/Linux" \
      "%{install-root}/usr/lib/systemd/boot/efi" "%{install-root}/usr/share/mjolnir"
    # Staged deps are read-only; copy keys to writable /tmp and fix their mode
    # (systemd-sbsign refuses overly permissive private keys).
    cp /boot-keys/*.key /boot-keys/*.crt /boot-keys/*.pub "$WORK/keys/"
    chmod 0600 "$WORK/keys/"*.key
    cp -a /layer/. "${ROOTFS}/"

    # Use the kernel/initramfs already built by kernel/initramfs.bst (staged
    # at /kernel). Do NOT run split-kernel-and-rootfs on the rootfs: it *moves*
    # files out of the tree whose digest we pin, and would change that digest.
    kver=$(cat /kernel/usr/lib/mjolnir-kernel-version)
    KDIR="/kernel/usr/lib/modules/${kver}"
    test -f "$KDIR/vmlinuz"
    test -f "$KDIR/initramfs.img"

    # bootc computes the composefs digest of the exact rootfs and generates the
    # `.cmdline` (v1 digest + v2 fallback + kargs.d entries such as
    # systemd.volatile=yes). No --karg may be passed at install time.
    bootc container ukify --rootfs "$ROOTFS" --kernel-dir "$KDIR" \
      -- --output "$WORK/mjolnir.efi" \
      --uname "${kver}" \
      --signtool=systemd-sbsign --no-sign-kernel \
      --secureboot-private-key="${WORK}/keys/VENDOR.key" \
      --secureboot-certificate="${WORK}/keys/VENDOR.crt" \
      --pcr-private-key="${WORK}/keys/PCR.key" \
      --pcr-public-key="${WORK}/keys/PCR.pub" \
      --pcr-banks=sha256

    # systemd-measure signs the expected PCR 11 value offline; no TPM is needed
    # in the build sandbox. ukify embeds the signature (.pcrsig) and its public
    # key (.pcrpkey) in the signed UKI. systemd-stub exposes them to the initrd,
    # which lets a signed UKI update still unseal MjolnirState.
    test -x /usr/lib/systemd/systemd-measure
    objcopy -O binary -j .pcrsig "$WORK/mjolnir.efi" "$WORK/pcrsig.json"
    objcopy -O binary -j .pcrpkey "$WORK/mjolnir.efi" "$WORK/pcrpkey.pem"
    cmp "$WORK/pcrpkey.pem" "${WORK}/keys/PCR.pub"
    grep -q '"sig"' "$WORK/pcrsig.json"

    # Assert the signature and that the digest was baked into the cmdline.
    sbverify --cert "${WORK}/keys/VENDOR.crt" "$WORK/mjolnir.efi"
    objcopy -O binary -j .cmdline "$WORK/mjolnir.efi" "$WORK/cmdline.txt"
    grep -q 'composefs' "$WORK/cmdline.txt"
    grep -q 'systemd.volatile=yes' "$WORK/cmdline.txt"
    grep -q 'console=ttyS0,115200' "$WORK/cmdline.txt"
    grep -q 'systemd.journald.forward_to_console=1' "$WORK/cmdline.txt"

    # Publish the public PCR artifacts in this signing-only artifact. They are
    # also embedded in the signed UKI (and exposed to the initrd by systemd-stub),
    # so they are deliberately not copied into the digest-pinned runtime tree.
    # PCR.key never leaves the signing-only artifacts.
    install -Dm644 "${WORK}/keys/PCR.pub" \
      "%{install-root}/usr/lib/systemd/tpm2-pcr-public-key.pem"
    install -Dm644 "$WORK/pcrsig.json" \
      "%{install-root}/usr/share/mjolnir/tpm2-pcr-signature.json"
    install -Dm644 "$WORK/mjolnir.efi" \
      "%{install-root}/boot/EFI/Linux/mjolnir-${kver}.efi"

    # Sign systemd-boot so Secure Boot can load the loader; bootctl prefers
    # the .signed variant.
    /usr/lib/systemd/systemd-sbsign sign \
      --private-key="${WORK}/keys/VENDOR.key" \
      --certificate="${WORK}/keys/VENDOR.crt" \
      --output="%{install-root}/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi.signed" \
      "/usr/lib/systemd/boot/efi/systemd-boot%{efi-arch}.efi"

    # The pinned composefs digest, for attestation/verification.
    bootc container compute-composefs-digest "$ROOTFS" > \
      "%{install-root}/usr/share/mjolnir/composefs-digest.txt"
