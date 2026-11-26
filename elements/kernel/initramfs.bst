kind: script
description: |
  Kernel, modules and initramfs for bootc. The FSDK kernel element installs
  vmlinuz and modules under /usr/lib/modules/<version>; dracut generates a
  systemd initramfs with bootc's compiled composefs root setup. The generated
  archive is then stripped of shells and shell hooks so the shipped boot
  artifact obeys hard rule 1.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/fakecap.bst
- freedesktop-sdk.bst:components/dracut.bst
- freedesktop-sdk.bst:components/cryptsetup.bst
# dracut's crypt module depends on dm, whose check requires dmsetup. FSDK's
# cryptsetup element ships only libdevmapper; lvm2.bst provides the binary.
- freedesktop-sdk.bst:components/lvm2.bst
- freedesktop-sdk.bst:components/tpm2-tss.bst
- freedesktop-sdk.bst:components/linux.bst
- freedesktop-sdk.bst:components/linux-firmware.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/cpio.bst
- freedesktop-sdk.bst:components/zstd.bst
- filename: config/files-src.bst
  config:
    location: /config
- filename: kernel/initramfs-src.bst
  config:
    location: /initramfs-tools
- filename: mgmt/bootc.bst
  config:
    location: /bootc

environment:
  LD_PRELOAD: /usr/libexec/fakecap/fakecap.so
  FAKECAP_DB: /fakecap

variables:
  strip-binaries: ''

config:
  commands:
  - mkdir -p /fakecap /tmp /var/tmp /run
  - |
    set -eux
    version="$(ls -1 /usr/lib/modules | head -n1)"
    test -n "${version}"
    test -f "/usr/lib/modules/${version}/vmlinuz"
    echo "Kernel version: ${version}"
    # TPM2-backed LUKS needs cryptsetup, its systemd token plugin and tpm2-tss
    # in the initramfs. Under systemd.volatile=yes /etc/crypttab is tmpfs at
    # runtime, so the build-time copy below is what early boot reads.
    # FSDK splits debug symbols into /usr/lib/debug; a bare -name match picks
    # the .debug file, which is not a loadable cryptsetup token plugin.
    token=$(find /usr/lib /usr/lib64 -path '*/debug/*' -prune -o \
      -name 'libcryptsetup-token-systemd-tpm2.so*' -print -quit 2>/dev/null || true)
    test -n "${token}"
    echo "TPM2 cryptsetup token plugin: ${token}"
    if [ -n "${token}" ]; then
      install -Dm644 "${token}" /usr/lib/cryptsetup/libcryptsetup-token-systemd-tpm2.so
    fi
    install -Dm644 /config/crypttab /etc/crypttab
    install -Dm644 /config/dracut/50-mjolnir-tpm2.conf \
      /etc/dracut.conf.d/50-mjolnir-tpm2.conf
    # dracut requires modules.dep in the sandbox root /usr/lib/modules.
    depmod -a "${version}"
    mkdir -p "%{install-root}/usr/lib/modules"
    cp -a "/usr/lib/modules/${version}" "%{install-root}/usr/lib/modules/"
    # bootc's dracut module installs only a compiled helper and a native
    # systemd unit. Its module-setup.sh is a build-time script; nothing from it
    # is copied into the initramfs as a shell payload.
    mkdir -p /usr/lib/dracut/modules.d/51bootc
    cp /bootc/usr/lib/dracut/modules.d/51bootc/module-setup.sh \
       /usr/lib/dracut/modules.d/51bootc/module-setup.sh
    cp /bootc/usr/lib/systemd/system/bootc-root-setup.service \
       /usr/lib/systemd/system/bootc-root-setup.service
    install -Dm755 /bootc/usr/lib/bootc/initramfs-setup \
       /usr/lib/bootc/initramfs-setup

    # Keep dracut's diagnostics visible when BST truncates the build log.
    if ! dracut --no-hostonly --zstd --reproducible --no-machineid \
           --kver "${version}" \
           --kernel-image "/usr/lib/modules/${version}/vmlinuz" \
           --add bootc \
           --fstab --verbose -f /initramfs.raw > /tmp/dracut.log 2>&1; then
      tail -80 /tmp/dracut.log >&2
      exit 1
    fi
    /initramfs-tools/sanitize-initramfs.sh /initramfs.raw /initramfs.img
    install -Dm644 /initramfs.img \
      "%{install-root}/usr/lib/modules/${version}/initramfs.img"
    depmod -b "%{install-root}/usr" -a "${version}"
    echo "${version}" > "%{install-root}/usr/lib/mjolnir-kernel-version"
