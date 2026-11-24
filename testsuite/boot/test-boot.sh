#!/usr/bin/env bash
# Full install + boot proof for the sealed UKI.
#
# Runs on the CI runner (root required). There is no custom installer and no
# shell in the image: the image is installed with `bootc install to-disk`, the
# signed UKIs on the ESP are inspected from the runner, and the disk is booted
# with OVMF. Assertions read the serial console and the installed ESP.
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
trap 'set +e; sudo umount "$WORK/esp" 2>/dev/null; [ -n "${LOOP:-}" ] && sudo losetup -d "$LOOP" 2>/dev/null; sudo podman rm -f mjolnir-boot-src 2>/dev/null' EXIT

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
# Via-loopback creates the loop device inside the container, where there is no
# udev database for bootc's Discoverable Partitions root-type check. Override
# that check with a CI-only config in /etc; the shipped image keeps DPS and
# discoverable device paths. No --karg: a sealed UKI carries its whole cmdline
# in the signed .cmdline section, and bootc refuses install-time kargs.
mkdir -p "$WORK/bootc-install"
cat > "$WORK/bootc-install/99-ci-loopback.toml" <<'EOF'
[install]
discoverable-partitions = false
EOF
sudo podman run --rm --privileged --pid=host \
  -v /dev:/dev --tmpfs /run/udev \
  -v /var/lib/containers:/var/lib/containers \
  -v "$WORK/bootc-install:/etc/bootc/install:ro" \
  -v "$WORK:/data" "$IMAGE" \
  bootc install to-disk --composefs-backend --via-loopback /data/disk.raw \
    --filesystem btrfs --wipe --bootloader systemd
pass "bootc install to-disk accepted the signed UKI digest"

echo "==> inspecting the installed ESP"
LOOP=$(sudo losetup -f --show -P "$WORK/disk.raw")
ESP_PART=""
for p in "${LOOP}"p*; do
  [ -b "$p" ] || continue
  [ "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null || true)" = "vfat" ] && ESP_PART="$p"
done
[ -n "$ESP_PART" ] || fail "no ESP partition found on $LOOP"
sudo mount "$ESP_PART" "$WORK/esp"

UKI=$(sudo find "$WORK/esp/EFI/Linux/bootc" -name '*.efi' -type f 2>/dev/null | head -1)
[ -n "$UKI" ] || fail "bootc did not install a UKI to the ESP"
sudo objcopy -O binary -j .cmdline "$UKI" "$WORK/cmdline.bin"
CMD=$(tr -d '\000' < "$WORK/cmdline.bin")
echo "$CMD" | grep -q 'composefs.digest=v1-sha512-12:' || fail "missing signed V1 digest: $CMD"
echo "$CMD" | grep -q 'systemd.volatile=yes' || fail "missing volatile karg: $CMD"
DIGEST=$(printf '%s\n' "$CMD" | sed -n 's/.*composefs.digest=v1-sha512-12:\([0-9a-f]*\).*/\1/p')
[ "$DIGEST" = "$EXPECTED" ] || fail "installed UKI digest $DIGEST != image digest $EXPECTED"
pass "installed UKI pins the digest of the image under test"

echo "==> registering the separately signed debug UKI as a second boot entry"
sudo podman cp mjolnir-boot-src:/boot/mjolnir-debug "$WORK/"
DBG_EFI=$(sudo find "$WORK/mjolnir-debug" -name '*.efi' -type f | head -1)
[ -n "$DBG_EFI" ] || fail "debug UKI is missing from the image"
sudo install -Dm644 "$DBG_EFI" "$WORK/esp/EFI/Linux/$(basename "$DBG_EFI")"
sudo install -Dm644 "$WORK/mjolnir-debug/mjolnir-debug.conf" \
  "$WORK/esp/loader/entries/99-mjolnir-debug.conf"
sudo objcopy -O binary -j .cmdline \
  "$WORK/esp/EFI/Linux/$(basename "$DBG_EFI")" "$WORK/debug-cmdline.bin"
DBG_CMD=$(tr -d '\000' < "$WORK/debug-cmdline.bin")
echo "$DBG_CMD" | grep -q 'composefs.digest=v1-sha512-12:' || fail "debug UKI has no digest"
printf '%s\n' "$DBG_CMD" | grep -q "$EXPECTED" || fail "debug UKI pins a different root"
[ "$(basename "$DBG_EFI")" != "$(basename "$UKI")" ] || fail "debug UKI has no distinct EFIname"
[ "$DBG_EFI" != "$UKI" ] || fail "debug UKI is not a distinct binary"
pass "debug UKI is a distinct entry pinning the same verified root"

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

# varlink-httpd requires a client CA credential. The boot-report credential is
# opt-in; it makes bootc status (including image provenance) appear on the
# serial console without a shell in the image.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -subj /CN=MjolnirBootTest >/dev/null 2>&1
CA_B64=$(base64 -w0 "$WORK/ca.crt")

timeout 240 sudo qemu-system-x86_64 \
  -m 2048 -smp 2 -enable-kvm -nographic \
  -drive if=pflash,format=raw,unit=0,file="$WORK/code.fd",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
  -drive file="$WORK/disk.raw",format=raw,media=disk \
  -smbios type=11,value=io.systemd.credential:mjolnir.boot-report=1 \
  -smbios "type=11,value=io.systemd.credential.binary:varlink-httpd.tls.trust=$CA_B64" \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  >"$SERIAL" 2>&1 &
QEMU_PID=$!
for _ in $(seq 1 110); do
  grep -q 'Startup finished' "$SERIAL" 2>/dev/null && break
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 2
done
kill "$QEMU_PID" 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
[ -s "$SERIAL" ] || fail "VM produced no serial output"

grep -q 'Command line:' "$SERIAL" || fail "kernel cmdline not visible on serial console"
grep -q 'composefs.digest=v1-sha512-12:' "$SERIAL" || fail "booted cmdline lost the signed digest"
grep -q 'systemd.volatile=yes' "$SERIAL" || fail "booted cmdline lost systemd.volatile=yes"
grep -q 'Startup finished' "$SERIAL" || fail "systemd did not finish startup"
if grep -qE '\[ *FAILED *\]|Failed to start' "$SERIAL"; then
  echo "--- failed units ---" >&2
  grep -E '\[ *FAILED *\]|Failed to start' "$SERIAL" >&2
  fail "failed systemd units at boot"
fi
grep -q '"booted"' "$SERIAL" || fail "bootc status report missing from console"
grep -q '"image"' "$SERIAL" || fail "bootc status did not report image provenance"
pass "booted with OVMF: signed cmdline, bootc status, no failed units, provenance"

echo "Serial console log: $SERIAL"
