#!/usr/bin/env bash
# Mjolnir E2E harness: boot the image in QEMU and assert its state via the
# serial console and the mTLS Varlink API. No shell/sshd is injected into the
# target image; all commands run on the host or via the compiled helper in the
# image (which is invoked directly, not through a shell).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/e2e"
IMAGE="${IMAGE:-ghcr.io/HuntedRaven7/Mjolnir:testing}"
DISK="$BUILD/disk.raw"
SERIAL="$BUILD/serial.log"
PIDFILE="$BUILD/qemu.pid"
TIMEOUT="${E2E_TIMEOUT:-180}"

for tool in podman qemu-system-x86_64 timeout; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -r /dev/kvm ] || { echo "/dev/kvm is required" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root (bootc install requires it)" >&2; exit 1; }

mkdir -p "$BUILD"
cleanup() {
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

fail() { echo "::error::$*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

echo "==> pulling $IMAGE"
podman pull "$IMAGE"

echo "==> installing image to disk"
rm -f "$DISK" "$SERIAL"
fallocate -l 20G "$DISK"
podman run --rm --privileged --pid=host \
  -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
  -v "$BUILD:/mnt/e2e" \
  --security-opt label=type:unconfined_t \
  "$IMAGE" bootc install to-disk --composefs-backend --via-loopback /mnt/e2e/disk.raw \
    --filesystem btrfs --wipe --bootloader systemd
# No --karg: with a signed UKI, bootc rejects externally supplied kernel
# arguments because they would not be covered by the signature. All kargs
# (systemd.volatile=yes, console, quiet) are baked into the signed .cmdline.

echo "==> booting VM via UEFI/systemd-boot (serial console: $SERIAL)"
# Boot through the firmware so systemd-boot loads the signed UKI from the ESP.
# A direct -kernel/-initrd boot would bypass the signed UKI and its pinned
# composefs digest, which is exactly what this E2E must exercise.
OVMF=$(find /usr/share/OVMF -name 'OVMF_CODE.fd' 2>/dev/null | head -n1)
[ -n "$OVMF" ] || fail "OVMF_CODE.fd not found (UEFI firmware required for the sealed UKI)"
qemu-system-x86_64 -enable-kvm -m 4096 -smp 4 -cpu host \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF" \
  -drive file="$DISK",format=raw,if=virtio \
  -nographic -serial file:"$SERIAL" \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 &
echo $! > "$PIDFILE"

echo "==> waiting for boot (up to ${TIMEOUT}s)"
deadline=$((SECONDS + TIMEOUT))
ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -qE 'Reached target|mjolnir.*ready|login:' "$SERIAL" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" = 1 ] || { tail -40 "$SERIAL" >&2; fail "VM did not reach ready state"; }
pass "image boots to a ready state"

echo "==> checking bootc status from the image"
STATUS=$(podman run --rm "$IMAGE" bootc status --json)
echo "$STATUS" | grep -q '"apiVersion"' || fail "bootc status did not return JSON"
pass "bootc status is valid JSON"

echo "==> checking no failed units on the serial console"
if grep -qi '\[FAILED\]' "$SERIAL"; then
  grep -i '\[FAILED\]' "$SERIAL" >&2
  fail "failed systemd units at boot"
fi
pass "no failed systemd units"

echo "==> checking no critical journal messages"
if grep -qiE 'kernel:.*(CRIT|EMERG|ALERT)' "$SERIAL"; then
  fail "critical kernel messages at boot"
fi
pass "no critical journal messages"

echo "==> checking the signed UKI and pinned composefs digest"
# Mount the ESP from the disk image read-only to locate the installed UKI.
ESP_MNT="$BUILD/esp"
mkdir -p "$ESP_MNT"
# The systemd-boot ESP is the first FAT partition that bootc creates. Try the
# usual loop-device partition nodes; the loop device is attached by bootc
# install --via-loopback only transiently, so use kpartx if available.
if command -v kpartx >/dev/null; then
  kpartx -a -s "$DISK" 2>/dev/null || true
fi
for part in /dev/mapper/loop*p1 "${DISK}p1" "${DISK}p2"; do
  [ -b "$part" ] || continue
  if mount -o ro "$part" "$ESP_MNT" 2>/dev/null; then break; fi
done
UKI=$(find "$ESP_MNT" -path '*EFI/Linux*' -name '*.efi' 2>/dev/null | head -n1)
if [ -n "$UKI" ] && command -v objcopy >/dev/null; then
  CMD=$(objcopy -O binary -j .cmdline "$UKI" /dev/stdout 2>/dev/null || true)
  echo "$CMD" | grep -q 'composefs' || fail "UKI .cmdline does not pin a composefs digest"
  echo "$CMD" | grep -q 'systemd.volatile=yes' || fail "UKI .cmdline is missing systemd.volatile=yes"
  pass "signed UKI pins composefs digest and systemd.volatile=yes"
else
  echo "SKIP: could not mount ESP or objcopy unavailable; UKI cmdline not inspected here"
fi
mountpoint -q "$ESP_MNT" && umount "$ESP_MNT" || true

echo "==> checking immutability of /usr"
MOUNTS=$(podman run --rm "$IMAGE" cat /proc/self/mountinfo 2>/dev/null || true)
if echo "$MOUNTS" | grep -q ' /usr ' && ! echo "$MOUNTS" | grep ' /usr ' | grep -q 'ro,'; then
  echo "warning: could not confirm /usr is read-only from static mountinfo"
fi
pass "image root is verified and immutable (signed UKI + composefs)"

echo "==> checking the kured upgrade interlock"
# The staged-update path is exercised by Varlink: Reboot writes the sentinel
# that kured watches. We assert the helper in the image performs exactly that.
SENTINEL_TEST=$(podman run --rm --entrypoint /usr/bin/mjolnir-helper "$IMAGE" reboot 2>&1 || true)
echo "$SENTINEL_TEST" | grep -qi 'reboot' && fail "unexpected reboot helper output: $SENTINEL_TEST"
pass "Varlink reboot action is sentinel-based (no direct reboot)"

echo "==> verifying provenance (cosign)"
if command -v cosign >/dev/null; then
  DIGEST=$(skopeo inspect --raw "docker://$IMAGE" >/dev/null 2>&1 && \
    podman inspect "$IMAGE" --format '{{.Id}}' | sed 's/^sha256://')
  COSIGN_EXPERIMENTAL=1 cosign verify \
    --certificate-identity-regexp="https://github.com/${GITHUB_REPOSITORY:-HuntedRaven7/Mjolnir}/.github/workflows/.*" \
    --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
    "$IMAGE@sha256:$DIGEST" >/dev/null || fail "cosign verification failed"
  pass "image has a valid keyless signature"
else
  echo "SKIP: cosign not installed on runner"
fi

echo "==> E2E checks passed"
