#!/usr/bin/env bash
# Mjolnir host prerequisite doctor. Read-only: never installs or resets anything.
set -uo pipefail
PODMAN=${1:-podman}
BST2=${2:-}
ROOT=${3:-$PWD}
FAILED=0; WARNED=0

pass() { printf 'PASS  %-28s %s\n' "$1" "${2:-}"; }
fail() { printf 'FAIL  %-28s %s\n' "$1" "${2:-}"; printf '  FIX: %s\n' "$3"; FAILED=$((FAILED+1)); }
warn() { printf 'WARN  %-28s %s\n' "$1" "${2:-}"; printf '  FIX: %s\n' "${3:-}"; WARNED=$((WARNED+1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "=== Mjolnir host doctor ==="

if ! have "${PODMAN%% *}"; then
  fail "podman" "not found" "Install Podman 5+ (CI: setup-runner update-podman: true)"
else
  PV=$($PODMAN --version 2>/dev/null | awk '{print $3}')
  if [ "${PV%%.*}" -ge 5 ] 2>/dev/null; then pass "podman version" "v$PV"
  else warn "podman version" "v$PV" "5+ recommended"; fi
  if $PODMAN info >/dev/null 2>&1; then
    pass "podman store" "$($PODMAN info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
  else
    warn "podman store" "rootless info failed" "Try PODMAN='sudo podman'"
  fi
  DRIVER=$($PODMAN info --format '{{.Store.GraphDriverName}}' 2>/dev/null || true)
  [ "$DRIVER" = overlay ] && pass "podman driver" "$DRIVER" \
    || warn "podman driver" "${DRIVER:-unknown}" "CI enforces overlay in setup-runner"
fi

if have just; then pass "just" "$(just --version | awk '{print $2}')"
else fail "just" "not found" "Install just (taiki-e/install-action tool: just)"; fi

if [ -n "$BST2" ]; then
  if $PODMAN image exists "$BST2" 2>/dev/null; then pass "bst2 image" "local"
  else warn "bst2 image" "not local" "First 'just validate' will pull it"; fi
else fail "bst2 image var" "empty" "Set BST2_IMAGE"; fi
have bst && warn "host bst" "found (unused)" "Mjolnir runs bst only in the pinned container" || true

for spec in \
  "xorriso:installer ISO build" "mcopy:mtools for ISO" "cpio:initrd handling" \
  "mksquashfs:squashfs artifacts" "cosign:signature verification" \
  "skopeo:manifest inspection" "jq:CI parsing" "go:Go installer build"; do
  bin=${spec%%:*}; why=${spec#*:}
  if have "$bin"; then pass "$bin" "$(command -v "$bin")"
  else fail "$bin" "not found" "Install $why"; fi
done

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then pass "/dev/kvm" "readable+writable"
elif [ -e /dev/kvm ]; then fail "/dev/kvm" "not writable" "Add user to kvm group: sudo usermod -aG kvm \$USER"
else fail "/dev/kvm" "absent" "Enable KVM in BIOS / install qemu-kvm"; fi
have qemu-system-x86_64 && pass "qemu" "" || fail "qemu" "not found" "Install qemu-system-x86"

FREE=$(df -BG --output=avail "$ROOT" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ "${FREE:-0}" -ge 60 ]; then pass "free disk" "${FREE}G"
else fail "free disk" "${FREE:-?}G" "Need >=60G on $ROOT"; fi
MEM=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo 2>/dev/null || echo 0)
[ "${MEM:-0}" -ge 8 ] && pass "memory" "${MEM}GiB" || warn "memory" "${MEM}GiB" "8GiB+ recommended"

for url in https://cache.freedesktop-sdk.io https://gitlab.com; do
  curl -fsSI --max-time 10 "$url" >/dev/null 2>&1 && pass "reachable" "$url" \
    || warn "reachable" "$url" "Check network; see docs/BUILD.md"
done

if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  pass "git origin" "$(git -C "$ROOT" remote get-url origin)"
else fail "git origin" "missing" "git remote add origin <url>"; fi

echo
echo "=== Summary: $FAILED FAIL, $WARNED WARN ==="
[ "$FAILED" -eq 0 ]
