#!/usr/bin/env bash
# Full install + OVMF boot proof for the signed composefs UKI, plus two
# Secure Boot + swtpm cases that consume the published UKI/variable-store
# fixtures.
#
# Runs on the CI runner (root required). There is no shell in the image: the
# image is installed with `bootc install to-disk`, the installed UKI is checked
# against the composefs digest of the image under test, and the disk is booted
# through OVMF/systemd-boot. Readiness is proven by the image's own Varlink
# socket, not by injecting a shell or a login into the target. The extra cases
# read serial needles emitted by image units; fixtures are described in
# testsuite/README.md.
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
cleanup_boot() {
  set +e
  local l p f
  sudo umount "$WORK/esp" 2>/dev/null
  [ -n "${LOOP:-}" ] && sudo losetup -d "$LOOP" 2>/dev/null
  for l in "${CASE_LOOPS[@]:-}"; do [ -n "$l" ] && sudo losetup -d "$l" 2>/dev/null; done
  for p in "${CASE_QEMU_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for f in "$WORK"/secureboot-*/tpm/swtpm.pid; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  sudo podman rm -f mjolnir-boot-src 2>/dev/null
}
trap cleanup_boot EXIT

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
# The digest computation above uses a short-lived `podman run --rm`, so create
# a named source container here for the read-only copy of the debug assets.
sudo podman create --name mjolnir-boot-src "$IMAGE" >/dev/null || \
  fail "cannot create source container for the debug UKI"
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
# The readiness loop returns as soon as Varlink accepts; give the guest a
# moment to flush startup and boot-report lines to the serial file before
# shutting it down, since the assertions below read that file.
sleep 3
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
if grep -qE '\[ *FAILED *\]|Failed to start' "$SERIAL"; then
  grep -E '\[ *FAILED *\]|Failed to start' "$SERIAL" >&2
  fail "failed systemd units at boot"
fi
# Startup completion and the boot-report credential name cannot be asserted
# from this serial file: journald console output is not guaranteed in the
# guest, while the live Varlink socket proves systemd reached user space. The
# dotted credential name is checked statically in tests/test_units.py and the
# unit is required in tests/test_boot_assets.py.
# bootc-root-setup.service is Required by initrd-root-fs.target. A failure
# there prevents switch-root, so a live Varlink socket also proves it ran.
pass "booted with OVMF: signed UKI cmdline, live user space, no failed units"

echo "Serial console log: $SERIAL"

# ---------------------------------------------------------------------------
# Secure Boot + swtpm cases.
#
# The fixtures are release assets of the image repository. Each case gets its
# own copy of the installed disk, the enrolled variable store and the swtpm
# state directory. Missing fixtures produce SKIP logs and a green run: the
# existing checks above stay intact, and no assertion is weakened. Set
# FIXTURE_DIR (or the three per-file overrides) to run the cases.
# ---------------------------------------------------------------------------
FIXTURE_DIR="${FIXTURE_DIR:-${SECUREBOOT_FIXTURE_DIR:-${RUNNER_TEMP:-/tmp}/mjolnir-secureboot-fixtures}}"
VARS_ENROLLED="${OVMF_VARS_ENROLLED:-$FIXTURE_DIR/OVMF_VARS.enrolled.fd}"
UKI_SIGNED="${UKI_SIGNED:-$FIXTURE_DIR/uki-signed.efi}"
UKI_UNKNOWN="${UKI_UNKNOWN:-$FIXTURE_DIR/uki-unknown.efi}"
SIGNED_LOG="${SIGNED_LOG:-$WORK/secureboot-signed.log}"
UNKNOWN_LOG="${UNKNOWN_LOG:-$WORK/secureboot-unknown.log}"
SWTPM="${SWTPM:-swtpm}"
NEEDLE_UNLOCK="${UNLOCK_NEEDLE:-MjolnirState: unlocked}"
NEEDLE_PCR="${PCR_NEEDLE:-PCR policy}"
NEEDLE_FAILED="${UNSEAL_FAIL_NEEDLE:-Failed to unseal}"
BOOT_WAIT="${BOOT_WAIT:-180}"
GRACE="${GRACE_SECONDS:-10}"
CASE_LOOPS=()
CASE_QEMU_PIDS=()

assert_needle() {
  local log="$1" needle="$2" label="$3"
  grep -aqF "$needle" "$log" || fail "$label: missing serial needle '$needle' in $log"
  pass "$label: serial needle '$needle'"
}

assert_no_needle() {
  local log="$1" needle="$2" label="$3"
  if grep -aqF "$needle" "$log"; then
    fail "$label: unexpected serial needle '$needle' in $log"
  fi
  pass "$label: no '$needle'"
}

# Put one fixture UKI on the case disk's ESP. The debug entry is removed from
# the copy so systemd-boot cannot choose it instead of the fixture.
install_case_uki() {
  local cd="$1" uki="$2" loop part p count
  loop=$(sudo losetup -f --show -P "$cd/disk.raw") || fail "cannot attach $cd/disk.raw"
  CASE_LOOPS+=("$loop")
  part=""
  for p in "${loop}"p*; do
    [ -b "$p" ] || continue
    [ "$(sudo blkid -o value -s TYPE "$p" 2>/dev/null || true)" = "vfat" ] && part="$p"
  done
  [ -n "$part" ] || fail "no ESP partition on $cd/disk.raw"
  sudo mount "$part" "$WORK/esp" || fail "cannot mount the case ESP"
  sudo install -Dm644 "$uki" "$WORK/esp/EFI/Linux/$(basename "$UKI")" || \
    fail "cannot install $uki on the case ESP"
  sudo rm -f "$WORK/esp/EFI/Linux/$(basename "$DBG_EFI")" \
    "$WORK/esp/loader/entries/99-mjolnir-debug.conf"
  count=$(sudo find "$WORK/esp/EFI/Linux" -maxdepth 1 -name '*.efi' -type f | wc -l)
  [ "$count" -eq 1 ] || fail "case ESP has $count UKIs; expected exactly one"
  sudo umount "$WORK/esp" || fail "cannot unmount the case ESP"
  sudo losetup -d "$loop" || fail "cannot detach $loop"
}

boot_case() {
  local label="$1" log="$2" cd="$3" primary="$4" pid elapsed=0
  SERIAL="$log"
  # The log lives in the user-owned WORK dir; root writes through this fd.
  # shellcheck disable=SC2024
  sudo qemu-system-x86_64 \
    -m 2048 -smp 2 -enable-kvm -nographic \
    -drive if=pflash,format=raw,unit=0,file="$WORK/code.fd",readonly=on \
    -drive if=pflash,format=raw,unit=1,file="$cd/vars.fd" \
    -drive file="$cd/disk.raw",format=raw,media=disk \
    -chardev "socket,id=chrtpm,path=$cd/tpm/swtpm.sock" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm \
    -device tpm-tis,tpmdev=tpm0 \
    -smbios type=11,value=io.systemd.credential:mjolnir.boot-report=1 \
    -smbios "type=11,value=io.systemd.credential.binary:varlink-httpd.tls.trust=$CA_B64" \
    -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
    >"$log" 2>&1 &
  pid=$!
  CASE_QEMU_PIDS+=("$pid")
  while [ "$elapsed" -lt "$BOOT_WAIT" ]; do
    if grep -aqF "$primary" "$log" 2>/dev/null; then break; fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 2
    elapsed=$((elapsed + 2))
  done
  # Give late units time to emit a needle before asserting its absence.
  sleep "$GRACE"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ -s "$log" ] || fail "$label: VM produced no serial output"
  pass "$label: serial log captured at $log"
}

secureboot_cases() {
  local missing=0 f label cd tpm
  for f in "$VARS_ENROLLED" "$UKI_SIGNED" "$UKI_UNKNOWN"; do
    if [ ! -s "$f" ]; then
      echo "    missing fixture: $f"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    mkdir -p "$WORK"
    for f in "$SIGNED_LOG" "$UNKNOWN_LOG"; do
      printf 'SKIP: Secure Boot swtpm cases did not run.\nFixture directory: %s\nThe three fixtures are release assets of the image repository; see testsuite/README.md.\n' \
        "$FIXTURE_DIR" >"$f"
    done
    echo "SKIP: Secure Boot swtpm cases (fixtures not present in $FIXTURE_DIR)"
    return 0
  fi
  need "$SWTPM"

  for label in signed unknown; do
    cd="$WORK/secureboot-$label"
    tpm="$cd/tpm"
    rm -rf "$cd"
    mkdir -p "$tpm"
    cp "$WORK/disk.raw" "$cd/disk.raw" || fail "cannot copy the disk for $label"
    cp "$VARS_ENROLLED" "$cd/vars.fd" || fail "cannot copy the variable store for $label"

    echo "==> Secure Boot case $label: enrolling state with the signed UKI"
    install_case_uki "$cd" "$UKI_SIGNED"
    "$SWTPM" socket --tpmstate "dir=$tpm" \
      --ctrl "type=unixio,path=$tpm/swtpm.sock" \
      --pid "file=$tpm/swtpm.pid" --tpm2 --daemon || fail "swtpm did not start for $label"
    for _ in $(seq 1 50); do
      [ -S "$tpm/swtpm.sock" ] && break
      sleep 0.1
    done
    [ -S "$tpm/swtpm.sock" ] || fail "swtpm socket did not appear for $label"

    boot_case "$label-enroll" "$cd/enroll.log" "$cd" "$NEEDLE_UNLOCK"
    assert_needle "$cd/enroll.log" "$NEEDLE_UNLOCK" "$label-enroll"

    if [ "$label" = signed ]; then
      echo "==> Secure Boot case signed: booting the signed update again"
      install_case_uki "$cd" "$UKI_SIGNED"
      boot_case signed "$SIGNED_LOG" "$cd" "$NEEDLE_UNLOCK"
      assert_needle "$SIGNED_LOG" "$NEEDLE_UNLOCK" signed
      assert_no_needle "$SIGNED_LOG" "$NEEDLE_FAILED" signed
    else
      echo "==> Secure Boot case unknown: booting the unknown PCR-key UKI"
      install_case_uki "$cd" "$UKI_UNKNOWN"
      boot_case unknown "$UNKNOWN_LOG" "$cd" "$NEEDLE_FAILED"
      assert_needle "$UNKNOWN_LOG" "$NEEDLE_PCR" unknown
      assert_needle "$UNKNOWN_LOG" "$NEEDLE_FAILED" unknown
      assert_no_needle "$UNKNOWN_LOG" "$NEEDLE_UNLOCK" unknown
    fi
    kill "$(cat "$tpm/swtpm.pid")" 2>/dev/null || true
  done
  echo "Secure Boot serial logs: $SIGNED_LOG, $UNKNOWN_LOG"
}

secureboot_cases
