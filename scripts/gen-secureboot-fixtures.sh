#!/usr/bin/env bash
# Build the three public Secure Boot unlock fixtures from signing-only BST
# artifacts. Runs on the CI runner, never inside the runtime image.
#
# The only downloaded tool is virt-firmware's virt-fw-vars, pinned by version
# and sha256 in include/versions.yml and verified before use. The OVMF template
# comes from the runner's ovmf package, as in testsuite/boot/test-boot.sh.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

ROOT="${1:?usage: gen-secureboot-fixtures.sh ROOT KEYS_DIR UKI_DIR OUT_DIR}"
KEYS="${2:?missing boot-keys checkout}"
UKI="${3:?missing mjolnir-uki checkout}"
OUT="${4:?missing output directory}"

command -v openssl >/dev/null || fail "openssl is required"
command -v objcopy >/dev/null || fail "objcopy is required"
command -v curl >/dev/null || fail "curl is required"
command -v unzip >/dev/null || fail "unzip is required"

read_version() {
  local key="$1"
  sed -n "s/^[[:space:]]*${key}:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    "$ROOT/include/versions.yml" | head -1
}

VER=$(read_version virt-firmware-version)
SHA=$(read_version virt-firmware-wheel-sha256)
[ -n "$VER" ] || fail "virt-firmware-version is missing from include/versions.yml"
[[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid virt-firmware-wheel-sha256: $SHA"

for f in VENDOR.crt DEBUG.crt PCR.pub UNKNOWN_PCR.pub; do
  [ -s "$KEYS/$f" ] || fail "missing public key material: $KEYS/$f"
done
SIGNED="$UKI/fixtures/uki-signed.efi"
UNKNOWN="$UKI/fixtures/uki-unknown.efi"
[ -s "$SIGNED" ] || fail "missing staged signed UKI: $SIGNED"
[ -s "$UNKNOWN" ] || fail "missing staged unknown UKI: $UNKNOWN"

OVMF_VARS=""
for candidate in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
                 /usr/share/edk2/ovmf/OVMF_VARS_4M.fd; do
  if [ -f "$candidate" ]; then OVMF_VARS="$candidate"; break; fi
done
[ -n "$OVMF_VARS" ] || fail "no blank OVMF_VARS template found; install the ovmf package"

WORK="${TMPDIR:-/tmp}/mjolnir-secureboot-fixtures"
rm -rf "$WORK" "$OUT"
mkdir -p "$WORK/vf" "$OUT"
trap 'rm -rf "$WORK"' EXIT

# Resolve the wheel URL for the pinned version, then verify its digest. The
# URL is discovered at run time; the pinned sha256 is what makes it trusted.
URL=$(python3 - "$VER" <<'PY'
import json, sys, urllib.request
version = sys.argv[1]
url = f"https://pypi.org/pypi/virt-firmware/{version}/json"
with urllib.request.urlopen(url, timeout=60) as resp:
    data = json.load(resp)
wheels = [f["url"] for f in data["urls"]
          if f["packagetype"] == "bdist_wheel"
          and f["filename"].endswith("-py3-none-any.whl")]
if len(wheels) != 1:
    sys.exit(f"expected one py3-none-any wheel, found {len(wheels)}")
print(wheels[0])
PY
) || fail "could not resolve virt-firmware $VER wheel"

curl -fsSL "$URL" -o "$WORK/virt_firmware.whl" || fail "could not download virt-firmware wheel"
echo "$SHA  $WORK/virt_firmware.whl" | sha256sum -c - || fail "virt-firmware sha256 mismatch"
unzip -q "$WORK/virt_firmware.whl" -d "$WORK/vf" || fail "could not unpack virt-firmware wheel"

# The owner GUID identifies the signature owner; it is not a secret. OVMF's
# own enrollment GUID makes the store look like a normally enrolled varstore.
OWNER="a0baa8a3-041d-48a8-bc87-c36d121b5e3d"
PYTHONPATH="$WORK/vf" python3 -m virt.firmware.vars \
  --input "$OVMF_VARS" \
  --output "$OUT/OVMF_VARS.enrolled.fd" \
  --set-pk "$OWNER" "$KEYS/VENDOR.crt" \
  --add-kek "$OWNER" "$KEYS/VENDOR.crt" \
  --add-db "$OWNER" "$KEYS/VENDOR.crt" \
  --add-db "$OWNER" "$KEYS/DEBUG.crt" \
  --secure-boot || fail "virt-fw-vars could not enroll the test keys"

# Assert the enrolled store instead of trusting the tool's exit status.
VARS_DUMP="$WORK/vars.txt"
PYTHONPATH="$WORK/vf" python3 -m virt.firmware.vars \
  --input "$OUT/OVMF_VARS.enrolled.fd" --print --verbose >"$VARS_DUMP" \
  || fail "could not read back the enrolled varstore"
PYTHONPATH="$WORK/vf" python3 -m virt.firmware.vars \
  --input "$OUT/OVMF_VARS.enrolled.fd" --print >"$WORK/vars-compact.txt" \
  || fail "could not read back the enrolled varstore"
grep -q 'SecureBootEnable.*bool: ON' "$WORK/vars-compact.txt" || \
  fail "Secure Boot is not enabled in OVMF_VARS.enrolled.fd"
cn() {
  openssl x509 -in "$1" -noout -subject -nameopt multiline |
    sed -n 's/^ *commonName *= *//p'
}
VENDOR_CN=$(cn "$KEYS/VENDOR.crt")
DEBUG_CN=$(cn "$KEYS/DEBUG.crt")
[ -n "$VENDOR_CN" ] && [ -n "$DEBUG_CN" ] || fail "could not read certificate CNs"
grep -Fq "subject CN=$VENDOR_CN" "$VARS_DUMP" || fail "VENDOR cert not in enrolled db"
grep -Fq "subject CN=$DEBUG_CN" "$VARS_DUMP" || fail "DEBUG cert not in enrolled db"

cp "$SIGNED" "$OUT/uki-signed.efi"
cp "$UNKNOWN" "$OUT/uki-unknown.efi"

# Both UKIs must boot the same verified root. Only the PCR signing key differs.
objcopy -O binary -j .pcrpkey "$OUT/uki-signed.efi" "$WORK/signed-pcr.pem"
objcopy -O binary -j .pcrpkey "$OUT/uki-unknown.efi" "$WORK/unknown-pcr.pem"
cmp "$WORK/signed-pcr.pem" "$KEYS/PCR.pub" || fail "signed UKI has the wrong PCR public key"
cmp "$WORK/unknown-pcr.pem" "$KEYS/UNKNOWN_PCR.pub" || fail "unknown UKI has the wrong PCR public key"
if cmp -s "$WORK/signed-pcr.pem" "$WORK/unknown-pcr.pem"; then
  fail "both UKIs use the same PCR signing key"
fi
objcopy -O binary -j .cmdline "$OUT/uki-signed.efi" "$WORK/signed-cmdline"
objcopy -O binary -j .cmdline "$OUT/uki-unknown.efi" "$WORK/unknown-cmdline"
tr -d '\000' <"$WORK/signed-cmdline" >"$WORK/signed-cmdline.txt"
tr -d '\000' <"$WORK/unknown-cmdline" >"$WORK/unknown-cmdline.txt"
cmp "$WORK/signed-cmdline.txt" "$WORK/unknown-cmdline.txt" || \
  fail "UKIs pin different cmdlines"

if compgen -G "$OUT/*.key" >/dev/null; then
  fail "private key material would be published from $OUT"
fi
(cd "$OUT" && sha256sum OVMF_VARS.enrolled.fd uki-signed.efi uki-unknown.efi >SHA256SUMS)
echo "Fixtures written to $OUT"
