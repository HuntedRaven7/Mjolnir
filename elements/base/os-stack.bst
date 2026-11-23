kind: stack
description: |
  The shipped userspace payload. Deliberately excludes runtime-gnu (which
  carries bash and coreutils), python3, perl, and openssh. Native ELF
  utilities such as cp(1) and mount(8) are kept because kubeadm's preflight
  requires them; they are not interpreters.

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
- freedesktop-sdk.bst:bootstrap/coreutils.bst
- freedesktop-sdk.bst:components/ca-certificates.bst
- freedesktop-sdk.bst:components/tzdata.bst
- freedesktop-sdk.bst:components/hosts.bst
- freedesktop-sdk.bst:components/nsswitch-config.bst
- freedesktop-sdk.bst:integration/extra-fs.bst
- freedesktop-sdk.bst:integration/ldconfig.bst

- freedesktop-sdk.bst:components/systemd.bst
- freedesktop-sdk.bst:components/dbus.bst
- freedesktop-sdk.bst:components/dbus-broker.bst
- freedesktop-sdk.bst:components/kmod.bst
- freedesktop-sdk.bst:components/shadow.bst
- freedesktop-sdk.bst:components/util-linux-full.bst
- freedesktop-sdk.bst:components/iproute2.bst
- freedesktop-sdk.bst:components/procps.bst
# bootc re-execs filesystem creation inside a container from the image being
# installed. Without these tools, `bootc install --filesystem btrfs` fails with
# "Creating rootfs: No such file or directory" (mkfs.btrfs) or the same error
# at "Creating ESP filesystem" (mkfs.fat).
- freedesktop-sdk.bst:components/btrfs-progs.bst
- freedesktop-sdk.bst:components/dosfstools.bst

# WiFi client (station mode) and firmware. NetworkManager is the daemon;
# wpa-supplicant is the explicitly selected WiFi backend (FSDK's NM build
# defaults to iwd, which we do not use).
- freedesktop-sdk.bst:components/networkmanager.bst
- freedesktop-sdk.bst:components/wpa-supplicant.bst
- freedesktop-sdk.bst:components/linux-firmware.bst
- freedesktop-sdk.bst:components/wireless-regdb-bin.bst

# Kernel, modules and initramfs.
- kernel/initramfs.bst

# bootc (in-place upgrades and bootc container lint).
- mgmt/bootc.bst

# KubeStellar Console fleet plugin.
- plugins/console/fleet.bst
- plugins/console/files.bst

# Mjolnir components.
- k8s/binaries.bst
- k8s/manifests.bst
- mgmt/varlink.bst
- mgmt/helpers.bst
- config/files.bst

public:
  bst:
    integration-commands:
    # bootc's expected mount layout; relative symlink targets only.
    - rm -rf /boot /run /sysroot
    - mkdir -p /boot /run /sysroot /sysroot/ostree
    - rm -rf /home /root /opt /mnt /srv /var /ostree /usr/local
    - mkdir -p /home /root /snap
    - mkdir -p /var/home /var/roothome /var/opt /var/mnt /var/srv /var/tmp /var/lib
    - ln -sT sysroot/ostree /ostree
    - ln -sT var/opt /opt
    - ln -sT var/mnt /mnt
    - ln -sT var/srv /srv
    - ln -sT ../var/usrlocal /usr/local
    - touch /etc/machine-id
