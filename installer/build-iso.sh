#!/usr/bin/env bash
# Build a minimal UEFI live ISO that boots a small initrd containing the
# static Go installer, podman/skopeo/bootc and systemd as PID 1.
#
# Prerequisites on the host: go, podman, cpio, gzip, xz, mtools (mformat,
# mcopy, mmd), mksquashfs, xorriso and systemd-boot EFI binaries.
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

for tool in go podman cpio gzip xz mformat mcopy mmd mksquashfs xorriso; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

mkdir -p "$BUILD"/{initrd,esp/EFI/BOOT,esp/loader/entries,squashfs/bin,squashfs/opt,squashfs/etc}
mkdir -p "$OUT"

echo "==> building static installer"
(cd "$ROOT/installer" && GOOS=linux GOARCH="$ARCH" CGO_ENABLED=0 \
  go build -trimpath -ldflags='-s -w' -o "$BUILD/squashfs/opt/mjolnir-install" .)

echo "==> staging live root filesystem from $BASE"
CID=$(podman create --name mjolnir-iso-root "$BASE" /usr/bin/true 2>/dev/null || \
  podman create "$BASE" /usr/bin/true)
trap 'podman rm -f "$CID" >/dev/null 2>&1 || true' EXIT
ROOTFS="$BUILD/squashfs"
# The bootc image hardlinks its /usr files into sysroot/ostree/repo, so a
# selective `podman export | tar -x` cannot materialise them. podman cp reads
# through the container filesystem and resolves the hardlinks.
mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/usr/lib"
podman cp "$CID:/usr/lib/systemd" "$ROOTFS/usr/lib/systemd"
for path in usr/bin/podman usr/bin/skopeo usr/bin/bootc \
            usr/bin/mount usr/bin/umount usr/bin/ip usr/bin/nmcli; do
  podman cp "$CID:/$path" "$ROOTFS/$path"
done

cat > "$BUILD/squashfs/etc/mjolnir-installer.json" <<EOF
{"image":"$IMAGE","filesystem":"btrfs"}
EOF
install -Dm644 "$ROOT/installer/systemd/mjolnir-installer.service" \
  "$ROOTFS/usr/lib/systemd/system/mjolnir-installer.service"
mkdir -p "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants"
ln -sf ../mjolnir-installer.service \
  "$ROOTFS/usr/lib/systemd/system/multi-user.target.wants/mjolnir-installer.service"

echo "==> building squashfs"
mksquashfs "$ROOTFS" "$BUILD/initrd/usr.squashfs" -noappend -comp xz -no-xattrs

echo "==> building initrd"
(
  cd "$BUILD/initrd"
  echo usr.squashfs | cpio -o -H newc --quiet | gzip -9 > "$BUILD/esp/initrd.img"
)

echo "==> assembling ESP"
BOOT_SOURCE="${SYSTEMD_BOOT_EFI:-/usr/lib/systemd/boot/efi/systemd-boot${EFI_ARCH}.efi}"
[ -f "$BOOT_SOURCE" ] || { echo "missing $BOOT_SOURCE" >&2; exit 1; }
cp "$BOOT_SOURCE" "$BUILD/esp/EFI/BOOT/$BOOT_EFI"
VMLINUZ=""
if [ -d "$BUILD/squashfs/usr/lib/modules" ]; then
  VMLINUZ=$(find "$BUILD/squashfs/usr/lib/modules" -name vmlinuz 2>/dev/null | head -n1 || true)
fi
if [ -z "$VMLINUZ" ]; then
  podman cp "$CID:/usr/lib/modules" "$BUILD/modules" >/dev/null 2>&1 || true
  VMLINUZ=$(find "$BUILD/modules" -name vmlinuz 2>/dev/null | head -n1 || true)
fi
[ -n "$VMLINUZ" ] || { echo "no vmlinuz in BASE_IMAGE=$BASE; set BASE_IMAGE to an image with a kernel" >&2; exit 1; }
cp "$VMLINUZ" "$BUILD/esp/vmlinuz"

cat > "$BUILD/esp/loader/loader.conf" <<'EOF'
default mjolnir
timeout 5
editor no
EOF
cat > "$BUILD/esp/loader/entries/mjolnir.conf" <<'EOF'
title Mjolnir Installer
linux /vmlinuz
initrd /initrd.img
options console=tty0 console=ttyS0,115200 rd.systemd.gpt_auto=0 rd.driver.pre=loop root=live:CDLABEL=MJOLNIR_INSTALL
EOF
# mformat needs an existing image file, and xorriso resolves -e relative to
# the ISO root, so the FAT image must live inside $BUILD/esp.
EFI_IMG="$BUILD/esp/efi.img"
truncate -s 64M "$EFI_IMG"
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
