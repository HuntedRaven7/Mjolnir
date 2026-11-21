#!/usr/bin/env bash
# Build a UEFI live ISO: systemd-boot loads a dracut-generated initramfs,
# whose dmsquash-live module mounts /LiveOS/squashfs.img from the ISO as the
# live root. That root holds the static Go installer, podman/skopeo/bootc and
# systemd.
#
# Prerequisites on the host: go, podman, mtools (mformat, mcopy, mmd),
# mksquashfs, xorriso and systemd-boot EFI binaries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/iso"
OUT="$ROOT/dist"
ARCH="${ARCH:-amd64}"
IMAGE="${IMAGE:-ghcr.io/huntedraven7/mjolnir:stable}"
# The plain fedora container is too minimal: it has no kernel, systemd, podman,
# skopeo, bootc, ip or nmcli. The bootc image ships all of them; pin by digest.
BASE="${BASE_IMAGE:-quay.io/fedora/fedora-bootc@sha256:840da31a3e3e8055a8d1c8c0f378e66e5c7de6ebe39037bbf7e5b252f138f04d}"
EFI_ARCH="$([ "$ARCH" = arm64 ] && echo aa64 || echo x64)"
BOOT_EFI="$([ "$ARCH" = arm64 ] && echo BOOTAA64.EFI || echo BOOTX64.EFI)"

for tool in go podman mformat mcopy mmd mksquashfs xorriso; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

# Always start from a clean staging tree: podman cp fails when a destination
# from an earlier layout (or an interrupted run) still exists, e.g. a regular
# file where it wants to create a directory.
rm -rf "$BUILD"
mkdir -p "$BUILD"/{esp/EFI/BOOT,esp/loader/entries,esp/LiveOS,squashfs/bin,squashfs/opt,squashfs/etc}
mkdir -p "$OUT"

echo "==> building static installer"
(cd "$ROOT/installer" && GOOS=linux GOARCH="$ARCH" CGO_ENABLED=0 \
  go build -trimpath -ldflags='-s -w' -o "$BUILD/squashfs/opt/mjolnir-install" .)

echo "==> staging live root filesystem from $BASE"
# dracut needs a running container, so start one with an idle PID 1.
podman rm -f mjolnir-iso-root >/dev/null 2>&1 || true
CID=$(podman run -d --name mjolnir-iso-root "$BASE" sleep infinity)
trap 'podman rm -f "$CID" >/dev/null 2>&1 || true' EXIT
ROOTFS="$BUILD/squashfs"
mkdir -p "$ROOTFS"
# Stage the complete base filesystem. Cherry-picking binaries left the live
# root without helpers referenced by systemd units (lvm, udevadm,
# systemd-tmpfiles, hwdb, ...), which produced a stream of failed units on
# real hardware. The full export resolves the base image's ostree hardlinks.
podman export "$CID" | tar -x -C "$ROOTFS"
# The ostree object store is only needed to resolve those hardlinks.
rm -rf "$ROOTFS/sysroot"
# Documentation and locales are not needed in an installer.
rm -rf "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/man" \
  "$ROOTFS/usr/share/locale" "$ROOTFS/usr/share/help" "$ROOTFS/var/cache"

# The base image enables sshd; it has no place in the installer live root.
find "$ROOTFS/usr/lib/systemd/system" -name 'sshd*' -delete

cat > "$ROOTFS/etc/mjolnir-installer.json" <<EOF
{"image":"$IMAGE","filesystem":"btrfs"}
EOF
install -Dm644 "$ROOT/installer/systemd/mjolnir-installer.service" \
  "$ROOTFS/usr/lib/systemd/system/mjolnir-installer.service"
mkdir -p "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants"
ln -sf ../mjolnir-installer.service \
  "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/mjolnir-installer.service"

echo "==> building live root squashfs"
mksquashfs "$ROOTFS" "$BUILD/esp/LiveOS/squashfs.img" -noappend -comp xz -no-xattrs

echo "==> building initramfs with dracut"
# The bootc image ships dracut but not the live-root modules. Vendor the
# version-matched modules (see installer/dracut-modules/README.md) into the
# throwaway container; they are used only to build this ISO.
for module in 90dmsquash-live 99img-lib; do
  podman cp "$ROOT/installer/dracut-modules/$module" \
    "$CID:/usr/lib/dracut/modules.d/$module"
done
KVER=$(podman exec "$CID" bash -c 'ls /usr/lib/modules | head -n1')
[ -n "$KVER" ] || { echo "no kernel version in BASE_IMAGE=$BASE" >&2; exit 1; }
# --no-hostonly is required: dmsquash-live refuses to run in host-only mode.
# isofs is needed to read the ISO once the firmware hands over to the kernel.
podman exec "$CID" bash -c \
  "dracut --no-hostonly --kver '$KVER' --add 'dmsquash-live img-lib' \
    --add-drivers isofs --force /tmp/initramfs.img"
podman cp "$CID:/tmp/initramfs.img" "$BUILD/esp/initrd.img"
podman cp "$CID:/usr/lib/modules/$KVER/vmlinuz" "$BUILD/esp/vmlinuz"

echo "==> assembling ESP"
BOOT_SOURCE="${SYSTEMD_BOOT_EFI:-/usr/lib/systemd/boot/efi/systemd-boot${EFI_ARCH}.efi}"
[ -f "$BOOT_SOURCE" ] || { echo "missing $BOOT_SOURCE" >&2; exit 1; }
cp "$BOOT_SOURCE" "$BUILD/esp/EFI/BOOT/$BOOT_EFI"

cat > "$BUILD/esp/loader/loader.conf" <<'EOF'
default mjolnir
timeout 5
editor no
EOF
# selinux=0: the full base brings its SELinux policy, but the squashfs-backed
# live root cannot set the security xattrs systemd wants and it aborts with
# "Failed to allocate manager object". SELinux is not needed in the installer.
cat > "$BUILD/esp/loader/entries/mjolnir.conf" <<'EOF'
title Mjolnir Installer
linux /vmlinuz
initrd /initrd.img
options console=tty0 console=ttyS0,115200 root=live:CDLABEL=MJOLNIR_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1 selinux=0
EOF
# mformat needs an existing image file, and xorriso resolves -e relative to
# the ISO root, so the FAT image must live inside $BUILD/esp. It has to hold
# both the kernel and the dracut initramfs.
EFI_IMG="$BUILD/esp/efi.img"
truncate -s 256M "$EFI_IMG"
mformat -i "$EFI_IMG" -F ::
mmd -i "$EFI_IMG" ::EFI ::EFI/BOOT ::loader ::loader/entries
mcopy -i "$EFI_IMG" "$BUILD/esp/EFI/BOOT/$BOOT_EFI" ::EFI/BOOT/$BOOT_EFI
mcopy -i "$EFI_IMG" "$BUILD/esp/loader/loader.conf" ::loader/loader.conf
mcopy -i "$EFI_IMG" "$BUILD/esp/loader/entries/mjolnir.conf" ::loader/entries/mjolnir.conf
mcopy -i "$EFI_IMG" "$BUILD/esp/vmlinuz" ::vmlinuz
mcopy -i "$EFI_IMG" "$BUILD/esp/initrd.img" ::initrd.img

echo "==> writing ISO"
ISO="$OUT/mjolnir-installer-${ARCH}.iso"
xorriso -as mkisofs -o "$ISO" -R -J -joliet-long -V MJOLNIR_INSTALL \
  -eltorito-alt-boot -e efi.img -no-emul-boot --efi-boot-part --efi-boot-image \
  "$BUILD/esp"
echo "wrote $ISO"
