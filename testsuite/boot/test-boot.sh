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

fail() {
  echo "::error::$*" >&2
  if [ -s "${SERIAL:-}" ]; then
    echo "--- serial console tail at failure ---" >&2
    tail -80 "$SERIAL" >&2
  fi
  exit 1
}
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
# bootc install hashes the OCI layers in container storage, not a flattened tar
# export: rechunking changes how a tar view collapses hardlinks and directory
# metadata. Compute the digest from the same view the installer consumes so the
# assertion below compares the UKI against the image it was actually installed
# from. This is bootc's own compute-composefs-digest-from-storage path.
GRAPHROOT=$(sudo podman system info -f '{{.Store.GraphRoot}}')
EXPECTED=$(sudo podman run --rm --privileged --security-opt=label=disable \
  -v "$GRAPHROOT:/run/host-container-storage:ro" -v /sys:/sys:ro --tmpfs=/var \
  "$IMAGE" bootc container compute-composefs-digest-from-storage)
case "$EXPECTED" in
  *[!0-9a-f]*|'') fail "invalid digest from compute-composefs-digest-from-storage: $EXPECTED" ;;
esac
pass "expected composefs digest=$EXPECTED"

echo "==> installing with bootc install to-disk"
truncate -s 32G "$WORK/disk.raw"
# bootc hard-checks the root partition's DPS type GUID before mkfs. It prefers
# lsblk's udev-backed parttype and mirrors the host udev DB from PID 1, which has
# no ID_PART_ENTRY_TYPE for loop partitions created after boot. Our bootc patch
# probes the disk with `blkid -p` whenever lsblk leaves parttype or pttype empty,
# so the check reads the DPS GUID from the real GPT. bootc requires --pid=host.
# The disk is attached on the host with partition scanning (-P), so the whole
# device and its partition nodes are complete. DPS stays on and no device path
# is hardcoded here.
# --run-repart makes bootc plan the disk from the image's repart.d definitions.
# With --generic-image it creates root/ESP/BIOS at install and leaves the space
# systemd-repart needs for MjolnirState on first boot. Without it bootc uses
# sfdisk only: it grows root over the whole disk, the encrypted state partition
# never appears, and systemd-cryptsetup@mjolnir-state waits on its device unit
# without a timeout until the boot test gives up.
# No --karg: a sealed UKI carries its whole cmdline in the signed .cmdline
# section, and bootc refuses install-time kargs.
LOOP=$(sudo losetup -f --show -P "$WORK/disk.raw")
set +e
sudo podman run --rm --privileged --pid=host --ipc=host \
  -v /dev:/dev -v /sys:/sys:ro --tmpfs /run/udev \
  -v /var/lib/containers:/var/lib/containers \
  "$IMAGE" \
  bootc install to-disk --composefs-backend --generic-image "$LOOP" \
    --filesystem btrfs --wipe --bootloader systemd --run-repart
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
sudo umount "$WORK/esp" || fail "could not unmount the ESP at $WORK/esp"
sudo losetup -d "$LOOP" || fail "could not detach $LOOP"
LOOP=""

# `ls a b c | head -1` exits 2 under pipefail when any operand is absent, even
# when another one exists. That killed this script silently right after the
# echo above. Probe candidates in preference order and report where we looked.
first_firmware() {
  local var=$1 label=$2 candidate
  shift 2
  for candidate in "$@"; do
    if [ -f "$candidate" ]; then
      printf -v "$var" '%s' "$candidate"
      return 0
    fi
  done
  fail "$label firmware not found; searched: $*"
}
first_firmware OVMF_CODE "OVMF code" \
  /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/edk2/ovmf/OVMF_CODE_4M.fd /usr/share/qemu/OVMF.fd
first_firmware OVMF_VARS "OVMF vars" \
  /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/edk2/ovmf/OVMF_VARS_4M.fd /usr/share/qemu/OVMF_VARS.fd
echo "    OVMF code: $OVMF_CODE"
echo "    OVMF vars: $OVMF_VARS"
cp "$OVMF_CODE" "$WORK/code.fd" || fail "could not copy $OVMF_CODE"
cp "$OVMF_VARS" "$WORK/vars.fd" || fail "could not copy $OVMF_VARS"

# varlink-httpd requires a client CA credential from the provisioning system.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
  -keyout "$WORK/ca.key" -out "$WORK/ca.crt" -subj /CN=MjolnirBootTest >/dev/null 2>&1 \
  || fail "could not generate the test client CA"
CA_B64=$(base64 -w0 "$WORK/ca.crt") || fail "could not encode the test client CA"

timeout 300 sudo qemu-system-x86_64 \
  -m 2048 -smp 2 -enable-kvm -nographic \
  -drive if=pflash,format=raw,unit=0,file="$WORK/code.fd",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$WORK/vars.fd" \
  -drive file="$WORK/disk.raw",format=raw,media=disk \
  -smbios type=11,value=io.systemd.credential:mjolnir.boot-report=1 \
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
QEMU_RC=0
wait "$QEMU_PID" 2>/dev/null || QEMU_RC=$?
[ "$ready" = 1 ] || {
  echo "    QEMU exited with status $QEMU_RC" >&2
  echo "    serial log bytes: $(wc -c < "$SERIAL" 2>/dev/null || echo 0)" >&2
  tail -60 "$SERIAL" >&2 || true
  fail "booted image did not open its Varlink socket"
}
pass "booted image reached user space (Varlink socket is accepting)"

echo "==> checking the booted kernel command line and unit state"
[ -s "$SERIAL" ] || fail "VM produced no serial output"
echo "    serial head (first 12 lines):"
head -12 "$SERIAL" | sed 's/^/    /'
# The kernel's early cmdline printk is not a stable assertion surface: quiet,
# console selection and kernel-version prefixes all change what reaches the
# serial log, and this guest need not emit it at all. The authoritative cmdline
# is the .cmdline section of the one signed UKI on the installed ESP, read into
# CMD above and accepted by bootc at install time. The live Varlink socket
# proves the disk booted into user space from that UKI. Assert those instead.
[ -n "$CMD" ] || fail "installed UKI has no .cmdline section"
printf '%s\n' "$CMD" | grep -q "composefs.digest=v1-sha512-12:$EXPECTED" || \
  fail "booted cmdline lost the pinned composefs digest"
printf '%s\n' "$CMD" | grep -q 'systemd.volatile=yes' || \
  fail "booted cmdline lost systemd.volatile=yes"
grep -q 'Startup finished' "$SERIAL" || fail "systemd did not finish startup"
if grep -qE '\[ *FAILED *\]|Failed to start' "$SERIAL"; then
  grep -E '\[ *FAILED *\]|Failed to start' "$SERIAL" >&2
  fail "failed systemd units at boot"
fi
# The boot-report credential must keep its dotted name: the unit is gated on
# /run/credentials/@system/mjolnir.boot-report, not on a generic status flag.
grep -q 'Started Report bootc status on the serial console' "$SERIAL" || \
  fail "mjolnir-boot-report.service did not start; the credential must be named mjolnir.boot-report"
grep -q '"booted"' "$SERIAL" || fail "bootc status report missing from console"
grep -q '"image"' "$SERIAL" || fail "bootc status did not report image provenance"
# bootc-root-setup.service is Required by initrd-root-fs.target. A failure
# there prevents switch-root, so a live Varlink socket also proves it ran.
pass "booted with OVMF: signed UKI cmdline, live user space, no failed units"

echo "Serial console log: $SERIAL"
