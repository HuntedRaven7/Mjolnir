kind: script
description: |
  Kernel, modules and initramfs for bootc. The FSDK kernel element installs
  vmlinuz and modules under /usr/lib/modules/<version>; dracut generates a
  generic initramfs with systemd as init so the composefs root can be mounted.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/fakecap.bst
- freedesktop-sdk.bst:components/dracut.bst
- freedesktop-sdk.bst:components/linux.bst
- freedesktop-sdk.bst:components/linux-firmware.bst
- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/cpio.bst
- freedesktop-sdk.bst:components/zstd.bst

environment:
  LD_PRELOAD: /usr/libexec/fakecap/fakecap.so
  FAKECAP_DB: /fakecap

variables:
  strip-binaries: ''

config:
  commands:
  - mkdir -p /fakecap /tmp /var/tmp /run
  - |
    set -eu
    version="$(ls -1 /usr/lib/modules | head -n1)"
    test -n "${version}"
    test -f "/usr/lib/modules/${version}/vmlinuz"
    echo "Kernel version: ${version}"
    # dracut requires modules.dep in the sandbox root /usr/lib/modules.
    depmod -a "${version}"
    mkdir -p "%{install-root}/usr/lib/modules"
    cp -a "/usr/lib/modules/${version}" "%{install-root}/usr/lib/modules/"
    dracut --no-hostonly --zstd --reproducible --no-machineid \
           --kver "${version}" \
           --kernel-image "/usr/lib/modules/${version}/vmlinuz" \
           --fstab --verbose -f /initramfs.img
    install -Dm644 /initramfs.img \
      "%{install-root}/usr/lib/modules/${version}/initramfs.img"
    depmod -b "%{install-root}/usr" -a "${version}"
    echo "${version}" > "%{install-root}/usr/lib/mjolnir-kernel-version"
