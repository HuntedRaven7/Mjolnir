#!/usr/bin/env bash
# Full install + OVMF boot proof for the signed composefs UKI.
#
# Runs on the CI runner (root required). There is no shell in the image: the
# image is installed with `bootc install to-disk`, the installed UKI is checked
# against the composefs digest of the image under test, and the disk is booted
# through OVMF/systemd-boot. Readiness is proven by the image's own Varlink
# socket, not by injecting a shell or a login into the target.
set -euo pipefail

IMAGE="${1:-localhost/mjolnir:latest}"
WORK="${RUNNER_TEMP:-/tmp}/mjolnir-boot-test"
SERIAL="$WORK/serial.log"

fail() { echo "::error::$*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
need() { command -v "$1" >/dev/null || fail "missing tool: $1"; }

for t in podman qemu-system-x86_64 objcopy losetup blkid mount umount find openssl base64 sudo; do
  need "$t"
done
sudo -n true || fail "passwordless sudo is required for the privileged install and QEMU"

rm -rf "$WORK"
mkdir -p "$WORK/rootfs" "$WORK/esp"
trap 'set +e; sudo umount "$WORK/esp" 2>/dev/null; [ -n "${LOOP:-}" ] && sudo losetup -d "$LOOP" 2>/dev/null; kill "${QEMU_PID:-}" 2>/dev/null; sudo podman rm -f mjolnir-boot-src 2>/dev/null' EXIT

echo "==> computing the expected composefs digest from the image under test"
sudo podman create --name mjolnir-boot-src "$IMAGE" >/dev/null
sudo podman export mjolnir-boot-src | tar -x -C "$WORK/rootfs"
EXPECTED=$(sudo podman run --rm --privileged -v "$WORK/rootfs:/target:ro" \
  "$IMAGE" bootc container compute-composefs-digest /target)
case "$EXPECTED" in
  *[!0-9a-f]*|'') fail "invalid digest from compute-composefs-digest: $EXPECTED" ;;
esac
pass "expected composefs digest=$EXPECTED"

echo "==> installing with bootc install to-disk"
truncate -s 32G "$WORK/disk.raw"
# An empty /run/udev makes bootc probe partition types with blkid instead of
# the host udev database, which has no record for partitions created inside
# the container. The host attaches the whole disk with partition scanning.
# No --karg: the signed UKI carries its whole command line.
LOOP=$(sudo losetup -f --show -P "$WORK/disk.raw")
set +e
sudo podman run --rm --privileged --pid=host --ipc=host \
  -v /dev:/dev -v /sys:/sys:ro --tmpfs /run/udev \
  -v /var/lib/containers:/var/lib/containers \
  "$IMAGE" \
  bootc install to-disk --composefs-backend --generic-image "$LOOP" \
    --filesystem btrfs --wipe --bootloader systemd
INSTALL_RC=$?
set -e
if [ "$INSTALL_RC" -ne 0 ]; then
  sudo lsblk -o NAME,PARTTYPE,PTTYPE,FSTYPE "$LOOP" >&2 || true
  fail "bootc install to-disk failed with exit $INSTALL_RC"
fi
pass "bootc install to-disk accepted the signed UKI digest"

echo "==> inspecting the installed ESP"
ESP_PART=""
for p in "${LOOP}"p*; do
  [ -b "$p" ] || continue
  [ "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null || true)" = "vfat" ] && ESP_PART="$p"
done
[ -n "$ESP_PART" ] || fail "no ESP partition found on $LOOP"
sudo mount "$ESP_PART" "$WORK/esp"

UKI=$(sudo find "$WORK/esp/EFI/Linux" -name '*.efi' -type f 2>/dev/null | head -1)
[ -n "$UKI" ] || fail "bootc did not install a UKI to the ESP"
sudo objcopy -O binary -j .cmdline "$UKI" "$WORK/cmdline.bin"
CMD=$(tr -d '\000' < "$WORK/cmdline.bin")
echo "$CMD" | grep -q 'composefs.digest=v1-sha512-12:' || fail "missing signed V1 digest: $CMD"
echo "$CMD" | grep -q 'systemd.volatile=yes' || fail "missing volatile karg: $CMD"
DIGEST=$(printf '%s\n' "$CMD" | sed -n 's/.*composefs.digest=v1-sha512-12:\([0-9a-f]*\).*/\1/p')
[ "$DIGEST" = "$EXPECTED" ] || fail "installed UKI digest $DIGEST != image digest $EXPECTED"
pass "installed UKI pins the digest of the image under test"

echo "==> booting the installed disk with OVMF"
sudo umount "$WORK/esp"
sudo losetup -d "$LOOP"
LOOP=""
OVMF_CODE=$(ls /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/edk2/ovmf/OVMF_CODE_4M.fd /usr/share/qemu/OVMF.fd 2>/dev/null | head -1)
OVMF_VARS=$(ls /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/edk2/ovmf/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd 2>/dev/null | head -1)
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || fail "OVMF firmware not installed"
cp "$OVMF_CODE" "$WORK/code.fd"
cp "$OVMF_VARS" "$WORK/vars.fd"

# varlink-httpd requires a client CA credential from the provisioning system.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -subj /CN=MjolnirBootTest >/dev/null 2>&1
CA_B64=$(base64 -w0 "$WORK/ca.crt")

timeout 300 sudo qemu-system-x86_64 \
  -m 2048 -smp 2 -enable-kvm -nographic \
  -drive if=pflash,format=raw,unit=0,file="$WORK/code.fd",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
  -drive file="$WORK/disk.raw",format=raw,media=disk \
  -smbios "type=11,value=io.systemd.credential.binary:varlink-httpd.tls.trust=$CA_B64" \
  -netdev user,id=net0,hostfwd=tcp::11031-:1031 \
  -device virtio-net-pci,netdev=net0 \
  >"$SERIAL" 2>&1 &
QEMU_PID=$!

echo "==> waiting for the booted image to open its Varlink socket"
ready=0
for _ in $(seq 1 140); do
  if timeout 2 bash -c 'exec 3<>/dev/tcp/127.0.0.1/11031' 2>/dev/null; then
    ready=1
    break
  fi
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 2
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
[ "$ready" = 1 ] || { tail -60 "$SERIAL" >&2; fail "booted image did not open its Varlink socket"; }
pass "booted image reached user space (Varlink socket is accepting)"

echo "==> checking the booted kernel command line and unit state"
[ -s "$SERIAL" ] || fail "VM produced no serial output"
grep -q 'Command line:' "$SERIAL" || fail "kernel cmdline not visible on serial console"
grep -q "composefs.digest=v1-sha512-12:$EXPECTED" "$SERIAL" || \
  fail "booted cmdline lost the pinned composefs digest"
grep -q 'systemd.volatile=yes' "$SERIAL" || fail "booted cmdline lost systemd.volatile=yes"
if grep -qE '\[ *FAILED *\]|Failed to start' "$SERIAL"; then
  grep -E '\[ *FAILED *\]|Failed to start' "$SERIAL" >&2
  fail "failed systemd units at boot"
fi
# bootc-root-setup.service is Required by initrd-root-fs.target. A failure
# there prevents switch-root, so a live Varlink socket also proves it ran.
pass "booted with OVMF: signed cmdline, verified root, no failed units"

echo "Serial console log: $SERIAL"
