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
# The bootc image hardlinks its /usr files into sysroot/ostree/repo, so a
# selective `podman export | tar -x` cannot materialise them. podman cp reads
# through the container filesystem and resolves the hardlinks.
mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib" "$ROOTFS/etc"
podman cp "$CID:/usr/lib/systemd" "$ROOTFS/usr/lib/systemd"
for path in usr/bin/podman usr/bin/skopeo usr/bin/bootc \
            usr/bin/mount usr/bin/umount usr/bin/ip usr/bin/nmcli usr/bin/lsblk \
            etc/os-release; do
  podman cp "$CID:/$path" "$ROOTFS/$path"
done
# The base image enables sshd; it has no place in the installer live root.
find "$ROOTFS/usr/lib/systemd/system" -name 'sshd*' -delete
# systemd's switch-root checks for an OS tree (os-release, /init) and then
# executes /sbin/init in the new root.
ln -sfn usr/lib/systemd/systemd "$ROOTFS/init"
mkdir -p "$ROOTFS/sbin"
ln -sfn ../usr/lib/systemd/systemd "$ROOTFS/sbin/init"
ln -sfn usr/bin "$ROOTFS/bin"
ln -sfn usr/lib "$ROOTFS/lib"
ln -sfn usr/lib64 "$ROOTFS/lib64"

# The staged binaries are dynamically linked; copy only the shared objects
# they actually need instead of the whole (269 MB) /usr/lib64 tree.
LIBS=$(podman exec "$CID" bash -c 'for b in /usr/lib/systemd/systemd /usr/bin/podman /usr/bin/skopeo /usr/bin/bootc /usr/bin/mount /usr/bin/umount /usr/bin/ip /usr/bin/nmcli /usr/bin/lsblk; do ldd "$b" 2>/dev/null; done | grep -oE "/(lib64|usr/lib64)/[^ ]+" | sort -u')
for lib in $LIBS; do
  rel=${lib#/lib64/}
  rel=${rel#/usr/lib64/}
  mkdir -p "$ROOTFS/usr/lib64/$(dirname "$rel")"
  podman cp "$CID:$lib" "$ROOTFS/usr/lib64/$rel"
done

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
# The live root needs its own module tree: NVMe, MMC and USB storage are
# modules, and after switch-root udev must be able to load the driver for the
# node's actual disk. Without this the installer sees no target disks.
mkdir -p "$ROOTFS/usr/lib/modules"
podman cp "$CID:/usr/lib/modules/$KVER" "$ROOTFS/usr/lib/modules/$KVER"
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
cat > "$BUILD/esp/loader/entries/mjolnir.conf" <<'EOF'
title Mjolnir Installer
linux /vmlinuz
initrd /initrd.img
options console=tty0 console=ttyS0,115200 root=live:CDLABEL=MJOLNIR_INSTALL rd.live.dir=/LiveOS rd.live.squashimg=squashfs.img rd.live.overlay.overlayfs=1
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
