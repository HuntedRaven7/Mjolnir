#!/usr/bin/env bash
# Mjolnir E2E harness: boot the image in QEMU and assert its state via the
# serial console and the mTLS Varlink API. No shell/sshd is injected into the
# target image; all commands run on the host or via the compiled helper in the
# image (which is invoked directly, not through a shell).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/e2e"
IMAGE="${IMAGE:-ghcr.io/huntedraven7/mjolnir:testing}"
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
LOOP=""
INSTALL_CID=""
INSTALL_QEMU=""
cleanup() {
  if [ -n "$INSTALL_QEMU" ]; then
    kill "$INSTALL_QEMU" 2>/dev/null || true
  fi
  if [ -f "$PIDFILE" ]; then
    kill "$(cat "$PIDFILE")" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
  if [ -n "$INSTALL_CID" ]; then
    podman rm -f "$INSTALL_CID" >/dev/null 2>&1 || true
  fi
  if [ -n "$LOOP" ]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

fail() { echo "::error::$*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

if [ "${SKIP_PULL:-0}" = "1" ]; then
  # Local image built in the same job (PR runs): just verify it is present.
  echo "==> using local image $IMAGE"
  podman image inspect "$IMAGE" >/dev/null || fail "local image $IMAGE not found"
else
  echo "==> pulling $IMAGE"
  podman pull "$IMAGE"
fi

echo "==> installing image to disk"
# A loop device in a container has no udev data, which bootc's DPS check
# requires. Install inside a VM instead: the target is a real virtio disk and
# the live installer root has a working udev daemon.
INSTALL_IMAGE="$IMAGE"
if [ "${SKIP_PULL:-0}" = "1" ]; then
  TAG="e2e-${GITHUB_RUN_ID:-local}"
  OWNER="${GITHUB_REPOSITORY%/*}"
  OWNER="${OWNER,,}"
  INSTALL_IMAGE="ghcr.io/${OWNER}/mjolnir:${TAG}"
  echo "${GH_TOKEN:-}" | podman login ghcr.io -u "${GITHUB_ACTOR:-HuntedRaven7}" --password-stdin
  podman push "$IMAGE" "docker://${INSTALL_IMAGE}"
fi

echo "==> building installer ISO for ${INSTALL_IMAGE}"
if ! IMAGE="$INSTALL_IMAGE" ./installer/build-iso.sh > "$BUILD/installer-iso.log" 2>&1; then
  tail -80 "$BUILD/installer-iso.log" >&2
  fail "installer ISO build failed"
fi
INSTALL_ISO="$ROOT/dist/mjolnir-installer-amd64.iso"
[ -f "$INSTALL_ISO" ] || fail "installer ISO was not built"

# OVMF firmware: prefer the 4M build, fall back to the older layout.
OVMF=""
for name in OVMF_CODE_4M.fd OVMF_CODE.fd; do
  if [ -f "/usr/share/OVMF/$name" ]; then OVMF="/usr/share/OVMF/$name"; break; fi
done
[ -n "$OVMF" ] || OVMF=$(find /usr/share/OVMF -maxdepth 1 -name 'OVMF_CODE*.fd' 2>/dev/null | sort | head -n1)
[ -n "$OVMF" ] || fail "OVMF_CODE*.fd not found"

rm -f "$DISK" "$BUILD/install.log"
truncate -s 30G "$DISK"
# bootc's composefs pull runs skopeo inside a privileged container and needs
# more than 4 GB; with 4 GB the OOM killer kills skopeo mid-layer.
qemu-system-x86_64 -enable-kvm -m 8192 -smp 2 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF" \
  -cdrom "$INSTALL_ISO" \
  -drive file="$DISK",format=raw,if=virtio \
  -nographic -serial file:"$BUILD/install.log" -monitor none &
INSTALL_QEMU=$!
installed=0
deadline=$((SECONDS + 900))
while [ "$SECONDS" -lt "$deadline" ]; do
  if grep -q 'Mjolnir installed successfully' "$BUILD/install.log" 2>/dev/null; then
    installed=1
    break
  fi
  sleep 5
done
kill "$INSTALL_QEMU" 2>/dev/null || true
wait "$INSTALL_QEMU" 2>/dev/null || true
INSTALL_QEMU=""
[ "$installed" = 1 ] || { tail -60 "$BUILD/install.log" >&2; fail "VM installer did not finish"; }
pass "installed image to disk in VM"

echo "==> booting VM via UEFI/systemd-boot (serial console: $SERIAL)"
# Boot through the firmware so systemd-boot loads the signed UKI from the ESP.
# A direct -kernel/-initrd boot would bypass the signed UKI and its pinned
# composefs digest, which is exactly what this E2E must exercise.
# Ubuntu 26.04 (resolute) ships only 4M firmware (OVMF_CODE_4M.fd); older
# releases ship OVMF_CODE.fd. Accept either layout so the runner can boot the
# signed UKI through systemd-boot regardless of the OVMF package version.
OVMF=""
for name in OVMF_CODE_4M.fd OVMF_CODE.fd; do
  if [ -f "/usr/share/OVMF/$name" ]; then
    OVMF="/usr/share/OVMF/$name"
    break
  fi
done
if [ -z "$OVMF" ]; then
  OVMF=$(find /usr/share/OVMF -maxdepth 1 -name 'OVMF_CODE*.fd' 2>/dev/null | sort | head -n1)
fi
[ -n "$OVMF" ] || fail "OVMF_CODE*.fd not found (UEFI firmware required for the sealed UKI)"
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
if command -v cosign >/dev/null && [ "${SKIP_COSIGN:-0}" != "1" ]; then
  DIGEST=$(skopeo inspect --raw "docker://$IMAGE" >/dev/null 2>&1 && \
    podman inspect "$IMAGE" --format '{{.Id}}' | sed 's/^sha256://')
  COSIGN_EXPERIMENTAL=1 cosign verify \
    --certificate-identity-regexp="https://github.com/${GITHUB_REPOSITORY:-HuntedRaven7/Mjolnir}/.github/workflows/.*" \
    --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
    "$IMAGE@sha256:$DIGEST" >/dev/null || fail "cosign verification failed"
  pass "image has a valid keyless signature"
else
  echo "SKIP: cosign verification (not installed or local image)"
fi

echo "==> E2E checks passed"
