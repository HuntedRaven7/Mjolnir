kind: manual
description: |
  SIGNING-ONLY. Builds two signed, composefs-digest-pinned UKIs with bootc's
  ukify integration. Both digest values are computed from oci/rootfs.bst, the
  exact tree that build-oci packages, so `bootc install` reproduces them from
  the installed rootfs. The digests live in the signed `.cmdline` section only.

  The default UKI is signed with DB/VENDOR and is handed to bootc via
  /boot/EFI/Linux. The debug UKI is signed with a distinct DEBUG key, has its
  own EFIname and title, and is staged under /boot/mjolnir-debug for an
  operator to register as an additional systemd-boot entry. It is deliberately
  not a second bootc-managed UKI: bootc rejects two composefs cmdlines and
  names every UKI it installs after the deployment digest.

  NEVER add this element to a runtime stack (its artifact is built from
  signing-only dependencies). Only the signed PE binaries are copied into the
  final image by oci/mjolnir.bst.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
- freedesktop-sdk.bst:components/systemd-ukify.bst
- freedesktop-sdk.bst:components/_private/sbsigntools.bst
- freedesktop-sdk.bst:components/binutils.bst
- freedesktop-sdk.bst:components/diffutils.bst
- freedesktop-sdk.bst:components/systemd.bst
# systemd-measure computes the PCR policy with libtss2 in the build sandbox.
- freedesktop-sdk.bst:components/tpm2-tss.bst
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
    # /tmp (tmpfs) where xattrs work. /var/tmp is needed by bootc for its temp
    # repo; our patched bootc honours TMPDIR, which we point at the writable /tmp.
    export TMPDIR=/tmp
    WORK=/tmp/mjolnir-uki
    ROOTFS="$WORK/rootfs"
    mkdir -p "$WORK" "${ROOTFS}" "$WORK/keys" \
      "%{install-root}/boot/EFI/Linux" \
      "%{install-root}/boot/mjolnir-debug"
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

    # bootc computes the composefs digest of the exact final rootfs and
    # generates the `.cmdline` (V1 digest + V2 fallback + kargs.d entries such
    # as systemd.volatile=yes and console=ttyS0). No --karg may be passed at
    # install time, because that would bypass the signature.
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

    # The debug UKI pins the same verified root but is signed by a different
    # key that is never enrolled in firmware. Its own os-release gives it a
    # distinct systemd-boot title.
    cat > "$WORK/debug-os-release" <<EOF
    ID=mjolnir
    ID_LIKE=fedoraproject
    NAME="Mjolnir"
    PRETTY_NAME="Mjolnir (debug)"
    VERSION_ID="0"
    VARIANT_ID=debug
    EOF
    bootc container ukify --rootfs "$ROOTFS" --kernel-dir "$KDIR" \
      -- --output "$WORK/mjolnir-debug.efi" \
      --uname "${kver}-debug" \
      --os-release=@"${WORK}/debug-os-release" \
      --signtool=systemd-sbsign --no-sign-kernel \
      --secureboot-private-key="${WORK}/keys/DEBUG.key" \
      --secureboot-certificate="${WORK}/keys/DEBUG.crt"

    # Assert both signatures and that the same digest was baked into both
    # cmdlines. The digest is written under /boot, which composefs empties
    # before hashing, so publishing it cannot make the pin self-referential.
    sbverify --cert "${WORK}/keys/VENDOR.crt" "$WORK/mjolnir.efi"
    sbverify --cert "${WORK}/keys/DEBUG.crt" "$WORK/mjolnir-debug.efi"
    for uki in mjolnir mjolnir-debug; do
      objcopy -O binary -j .cmdline "$WORK/${uki}.efi" "$WORK/${uki}.cmdline"
      grep -q 'composefs.digest=v1-sha512-12:' "$WORK/${uki}.cmdline"
      grep -q 'systemd.volatile=yes' "$WORK/${uki}.cmdline"
      # Gates from the diagnostics stack apply to both signed UKIs.
      grep -q 'console=ttyS0,115200' "$WORK/${uki}.cmdline"
      grep -q 'systemd.journald.forward_to_console=1' "$WORK/${uki}.cmdline"
    done
    PRIMARY_DIGEST=$(sed -n 's/.*composefs.digest=v1-sha512-12:\([0-9a-f]*\).*/\1/p' "$WORK/mjolnir.cmdline")
    DEBUG_DIGEST=$(sed -n 's/.*composefs.digest=v1-sha512-12:\([0-9a-f]*\).*/\1/p' "$WORK/mjolnir-debug.cmdline")
    test -n "$PRIMARY_DIGEST"
    test "$PRIMARY_DIGEST" = "$DEBUG_DIGEST"
    # A distinct signing key must produce a distinct PE binary.
    if cmp -s "$WORK/mjolnir.efi" "$WORK/mjolnir-debug.efi"; then
      echo "debug UKI is byte-identical to the default UKI" >&2
      exit 1
    fi

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
    install -Dm644 "$WORK/mjolnir-debug.efi" \
      "%{install-root}/boot/mjolnir-debug/mjolnir-debug-${kver}.efi"
    cat > "%{install-root}/boot/mjolnir-debug/mjolnir-debug.conf" <<EOF
    title Mjolnir (debug)
    efi /EFI/Linux/mjolnir-debug-${kver}.efi
    EOF

    # The pinned composefs digest, for attestation/verification. Stored under
    # /boot so it is outside the composefs image and cannot change the digest.
    bootc container compute-composefs-digest "$ROOTFS" > \
      "%{install-root}/boot/mjolnir-composefs-digest.txt"
    DIGEST=$(cat "%{install-root}/boot/mjolnir-composefs-digest.txt")
    grep -q "${DIGEST}" "$WORK/mjolnir.cmdline"
