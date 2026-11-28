kind: manual
description: |
  SIGNING-ONLY. Owns the final rootfs tree, builds the signed composefs-digest-
  pinned UKI for it, and stages the tree so oci/mjolnir.bst can build the OCI
  layer from the exact tree whose digest is baked into the signed .cmdline
  section. Also stages two public unlock fixtures outside that tree.
  NEVER add this element to a runtime stack (its artifact contains key material
  via boot-keys.bst and a full copy of the rootfs).

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
      "%{install-root}/rootfs" "%{install-root}/usr/share/mjolnir"
    # Staged deps are read-only; copy keys to writable /tmp and fix their mode
    # (systemd-sbsign refuses overly permissive private keys).
    cp /boot-keys/*.key /boot-keys/*.crt /boot-keys/*.pub "$WORK/keys/"
    chmod 0600 "$WORK/keys/"*.key
    cp -a /layer/. "${ROOTFS}/"

    # Sign systemd-boot so Secure Boot can load the loader; bootctl prefers the
    # .signed variant. This is a /usr file, so it is part of the composefs digest
    # and must be in the tree before the digest is computed. The signed bytes and
    # the parent directory mtime must match the BST-normalized OCI layer: copy
    # the mtimes from the files that came from the staged dependency.
    EFI_DIR="${ROOTFS}/usr/lib/systemd/boot/efi"
    /usr/lib/systemd/systemd-sbsign sign \
      --private-key="${WORK}/keys/VENDOR.key" \
      --certificate="${WORK}/keys/VENDOR.crt" \
      --output="${EFI_DIR}/systemd-boot%{efi-arch}.efi.signed" \
      "${EFI_DIR}/systemd-boot%{efi-arch}.efi"
    touch -r "${EFI_DIR}/systemd-boot%{efi-arch}.efi" \
      "${EFI_DIR}/systemd-boot%{efi-arch}.efi.signed"
    touch -r "/layer/usr/lib/systemd/boot/efi" "${EFI_DIR}"

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

    # The debug UKI pins the same verified root but is signed with a DEBUG key
    # that is never enrolled in firmware. Its distinct os-release gives it its
    # own systemd-boot title. It is staged under /boot for opt-in registration,
    # not installed as a second bootc-managed UKI: bootc rejects two composefs
    # cmdlines under EFI/Linux.
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
      --os-release=@"$WORK/debug-os-release" \
      --signtool=systemd-sbsign --no-sign-kernel \
      --secureboot-private-key="${WORK}/keys/DEBUG.key" \
      --secureboot-certificate="${WORK}/keys/DEBUG.crt" \
      --pcr-private-key="${WORK}/keys/PCR.key" \
      --pcr-public-key="${WORK}/keys/PCR.pub" \
      --pcr-banks=sha256
    sbverify --cert "${WORK}/keys/DEBUG.crt" "$WORK/mjolnir-debug.efi"
    objcopy -O binary -j .cmdline "$WORK/mjolnir-debug.efi" "$WORK/debug-cmdline.txt"
    grep -q 'composefs.digest=v1-sha512-12:' "$WORK/debug-cmdline.txt"
    grep -q "$(cat "%{install-root}/usr/share/mjolnir/composefs-digest.txt")" \
      "$WORK/debug-cmdline.txt"
    if cmp -s "$WORK/mjolnir.efi" "$WORK/mjolnir-debug.efi"; then
      echo "debug UKI is byte-identical to the default UKI" >&2
      exit 1
    fi

    # The pinned composefs digest, as a build record. It is deliberately kept
    # out of the image: a file containing its own tree's digest cannot be part
    # of that tree. No runtime code reads it; attestation reads /proc/cmdline.
    bootc container compute-composefs-digest "$ROOTFS" > \
      "%{install-root}/usr/share/mjolnir/composefs-digest.txt"

    # Assert the signature and that the digest was baked into the cmdline.
    sbverify --cert "${WORK}/keys/VENDOR.crt" "$WORK/mjolnir.efi"
    objcopy -O binary -j .cmdline "$WORK/mjolnir.efi" "$WORK/cmdline.txt"
    grep -q "$(cat "%{install-root}/usr/share/mjolnir/composefs-digest.txt")" \
      "$WORK/cmdline.txt"
    grep -q 'systemd.volatile=yes' "$WORK/cmdline.txt"
    grep -q 'console=ttyS0,115200' "$WORK/cmdline.txt"
    grep -q 'systemd.journald.forward_to_console=1' "$WORK/cmdline.txt"

    # Unlock fixture: a UKI that passes firmware verification with DEBUG.crt
    # (enrolled in the published test OVMF vars) but carries a PCR signature
    # from UNKNOWN_PCR.key. The sealed state trusts PCR.key, so this UKI
    # reaches the initrd and then fails the PCR 11 unseal. It pins the same
    # composefs digest as the production UKI and is staged outside /rootfs.
    cat > "$WORK/unknown-os-release" <<EOF
    ID=mjolnir
    ID_LIKE=fedoraproject
    NAME="Mjolnir"
    PRETTY_NAME="Mjolnir (unknown PCR)"
    VERSION_ID="0"
    VARIANT_ID=unknown
    EOF
    bootc container ukify --rootfs "$ROOTFS" --kernel-dir "$KDIR" \
      -- --output "$WORK/mjolnir-unknown.efi" \
      --uname "${kver}-unknown" \
      --os-release=@"$WORK/unknown-os-release" \
      --signtool=systemd-sbsign --no-sign-kernel \
      --secureboot-private-key="${WORK}/keys/DEBUG.key" \
      --secureboot-certificate="${WORK}/keys/DEBUG.crt" \
      --pcr-private-key="${WORK}/keys/UNKNOWN_PCR.key" \
      --pcr-public-key="${WORK}/keys/UNKNOWN_PCR.pub" \
      --pcr-banks=sha256
    sbverify --cert "${WORK}/keys/DEBUG.crt" "$WORK/mjolnir-unknown.efi"
    objcopy -O binary -j .pcrpkey "$WORK/mjolnir-unknown.efi" \
      "$WORK/unknown-pcrpkey.pem"
    cmp "$WORK/unknown-pcrpkey.pem" "${WORK}/keys/UNKNOWN_PCR.pub"
    if cmp -s "$WORK/unknown-pcrpkey.pem" "$WORK/pcrpkey.pem"; then
      echo "unknown fixture reuses the production PCR key" >&2
      exit 1
    fi
    objcopy -O binary -j .cmdline "$WORK/mjolnir-unknown.efi" \
      "$WORK/unknown-cmdline.txt"
    grep -q "$(cat "%{install-root}/usr/share/mjolnir/composefs-digest.txt")" \
      "$WORK/unknown-cmdline.txt"

    # Publish the public PCR artifacts in this signing-only artifact. They are
    # also embedded in the signed UKI (and exposed to the initrd by systemd-stub),
    # so they are deliberately not copied into the digest-pinned runtime tree.
    # PCR.key never leaves the signing-only artifacts.
    install -Dm644 "${WORK}/keys/PCR.pub" \
      "%{install-root}/usr/lib/systemd/tpm2-pcr-public-key.pem"
    install -Dm644 "$WORK/pcrsig.json" \
      "%{install-root}/usr/share/mjolnir/tpm2-pcr-signature.json"

    # bootc's boot transform empties /boot before hashing, so installing the UKI
    # here does not invalidate the digest computed above.
    install -Dm644 "$WORK/mjolnir.efi" \
      "${ROOTFS}/boot/EFI/Linux/mjolnir-${kver}.efi"
    # Publish the pinned digest under /boot for attestation. composefs empties
    # /boot before hashing, so this cannot make the pin self-referential.
    install -Dm644 "%{install-root}/usr/share/mjolnir/composefs-digest.txt" \
      "${ROOTFS}/boot/mjolnir-composefs-digest.txt"
    install -Dm644 "$WORK/mjolnir-debug.efi" \
      "${ROOTFS}/boot/mjolnir-debug/mjolnir-debug-${kver}.efi"
    cat > "${ROOTFS}/boot/mjolnir-debug/mjolnir-debug.conf" <<EOF
    title Mjolnir (debug)
    efi /EFI/Linux/mjolnir-debug-${kver}.efi
    EOF

    # Public unlock fixtures, outside /rootfs so they cannot enter the
    # digest-pinned tree or the OCI layer. Only the signed binaries and the
    # enrolled OVMF varstore built from them are published; no key material.
    install -Dm644 "$WORK/mjolnir.efi" \
      "%{install-root}/fixtures/uki-signed.efi"
    install -Dm644 "$WORK/mjolnir-unknown.efi" \
      "%{install-root}/fixtures/uki-unknown.efi"

    # The OCI layer is this exact tree. oci/mjolnir.bst must not mutate it.
    cp -a "${ROOTFS}/." "%{install-root}/rootfs/"
