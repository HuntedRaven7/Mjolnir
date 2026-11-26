#!/usr/bin/env python3
"""Static checks for encrypted state and scoped factory reset.

These assert the public contract of the feature: the partition is encrypted,
its TPM2 policy is signed by a key that never enters the runtime image, and a
reset cannot proceed without the seals, topology checks and a drain.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def text(path: str) -> str:
    p = ROOT / path
    return p.read_text() if p.is_file() else ""


def check() -> list[str]:
    errors: list[str] = []

    repart = text("files/config/repart.d/20-mjolnir-state.conf")
    if not re.search(r"^Encrypt=key-file\s*$", repart, re.MULTILINE):
        errors.append("repart.d: MjolnirState is not encrypted with a key-file slot")
    if not re.search(r"^FactoryReset=yes\s*$", repart, re.MULTILINE):
        errors.append("repart.d: state partition is not factory-resettable")

    # repart.d accepts DPS identifiers or a GPT UUID, not arbitrary names.
    # `Type=state` parses nowhere and made bootc install fail in CI.
    valid_types = {
        "esp", "xbootldr", "swap", "home", "srv", "var", "tmp", "linux-generic",
        "root", "root-verity", "root-verity-sig", "root-secondary",
        "root-secondary-verity", "root-secondary-verity-sig",
        "usr", "usr-verity", "usr-verity-sig", "usr-secondary",
        "usr-secondary-verity", "usr-secondary-verity-sig",
    }
    arch = (r"alpha|arc|arm|arm64|ia64|loongarch64|mips-le|mips64-le|parisc|"
            r"ppc|ppc64|ppc64-le|riscv32|riscv64|s390|s390x|tilegx|x86|x86-64")
    arch_type = re.compile(rf"^(?:root|usr)(?:-(?:{arch}))?(?:-verity(?:-sig)?)?$")
    uuid_type = re.compile(
        r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
        r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )
    for value in re.findall(r"^Type=(\S+)\s*$", repart, re.MULTILINE):
        if value not in valid_types and not arch_type.match(value) and not uuid_type.match(value):
            errors.append(f"repart.d: invalid Type={value} (not a DPS identifier or GPT UUID)")
    if not re.search(r"^Type=linux-generic\s*$", repart, re.MULTILINE):
        errors.append("repart.d: encrypted state must use linux-generic so only the explicit mount binds it")

    crypttab = text("files/config/crypttab")
    if not re.search(
        r"^mjolnir-state\s+/dev/disk/by-partlabel/MjolnirState\s+-\s+"
        r"[^#]*tpm2-device=auto[^#]*x-initrd\.attach\s*$",
        crypttab, re.MULTILINE,
    ):
        errors.append("crypttab: missing discoverable TPM2 early-boot mapping")
    if re.search(r"/dev/(sd|nvme|vd)[a-z0-9]+", crypttab):
        errors.append("crypttab: hardcoded device path")

    mount = text("files/config/systemd/var-lib-mjolnir.mount")
    crypt_unit = "systemd-cryptsetup@mjolnir-state.service"
    if not re.search(r"^After=.*cryptsetup\.target.*$", mount, re.MULTILINE):
        errors.append("var-lib-mjolnir.mount: does not order after cryptsetup.target")
    if not re.search(
        rf"^After=.*\b{re.escape(crypt_unit)}\b.*$", mount, re.MULTILINE
    ):
        errors.append("var-lib-mjolnir.mount: cryptsetup unit is not ordered before the mount")
    if not re.search(
        rf"^Requires={re.escape(crypt_unit)}\s*$", mount, re.MULTILINE
    ):
        errors.append("var-lib-mjolnir.mount: cryptsetup unit is not required")
    if not re.search(
        r"^What=/dev/disk/by-label/MjolnirState\s*$", mount, re.MULTILINE
    ):
        errors.append("var-lib-mjolnir.mount: What= does not use the discoverable label")
    if "/dev/mapper/" in mount:
        errors.append("var-lib-mjolnir.mount: uses the raw mapper path instead of the label")

    dracut = text("files/config/dracut/50-mjolnir-tpm2.conf")
    if "add_dracutmodules+=\" crypt " not in dracut:
        errors.append("dracut config: missing crypt module")
    if "/etc/crypttab" not in dracut:
        errors.append("dracut config: crypttab is not included in the initramfs")
    if "libcryptsetup-token-systemd-tpm2.so" not in dracut:
        errors.append("dracut config: TPM2 token plugin is not an optional install item")

    initramfs = text("elements/kernel/initramfs.bst")
    if "find /usr/lib" not in initramfs:
        errors.append("initramfs element: TPM2 token plugin path is not discovered")
    for dep in ("components/cryptsetup.bst", "components/tpm2-tss.bst"):
        if dep not in initramfs:
            errors.append(f"initramfs element: missing build dependency {dep}")

    uki = text("elements/uki/mjolnir-uki.bst")
    for option in ("--pcr-private-key=", "--pcr-public-key=", "--pcr-banks=sha256"):
        if option not in uki:
            errors.append(f"UKI element: missing {option} (signed PCR 11 policy)")
    if ".pcrsig" not in uki or ".pcrpkey" not in uki:
        errors.append("UKI element: PCR signature/public key section not asserted")
    if "/boot-keys/*.pub" not in uki:
        errors.append("UKI element: PCR public key is not staged for ukify")
    if "components/tpm2-tss.bst" not in uki:
        errors.append("UKI element: missing tpm2-tss for systemd-measure")

    keys = text("elements/uki/boot-keys.bst")
    if "PCR.key" not in keys or "PCR.pub" not in keys:
        errors.append("boot-keys element: PCR signing keypair is not generated")
    for element in ROOT.glob("elements/**/*.bst"):
        if element.name == "boot-keys.bst" or element.name == "mjolnir-uki.bst":
            continue
        body = element.read_text()
        if "uki/boot-keys.bst" not in body:
            continue
        # A signing-only element may consume the keys to sign a public binary.
        # What must never reach a runtime stack is the key material itself, so
        # flag any element that stages a staged key into its own artifact.
        for line in body.splitlines():
            if "/boot-keys/" not in line or not re.search(r"\.(key|pem)\b", line):
                continue
            if "%{install-root}" in line or re.search(r"\$\{?root\}?/", line):
                errors.append(f"{element.name}: private key staged into runtime artifact")
                break

    # Only public PCR material may be committed. Scan tracked files only:
    # BuildStream stages upstream test keys into the gitignored .bst cache,
    # which is build output and not repository content.
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        capture_output=True, check=True,
    ).stdout.decode().split("\0")
    for name in tracked:
        if name.endswith((".key", ".pem", ".crt")) and "boot-keys" not in Path(name).parts:
            errors.append(f"key material in repository: {name}")

    enroll = text("files/config/systemd/mjolnir-state-enroll.service")
    for fragment in (
        "--wipe-slot=empty", "--tpm2-device=auto", "--tpm2-pcrs=7",
        "--tpm2-public-key-pcrs=11", "ConditionPathExists=!/var/lib/mjolnir/.tpm2-enrolled",
    ):
        if fragment not in enroll:
            errors.append(f"state enrollment unit: missing {fragment}")

    helper = text("src/mjolnir.c")
    for fragment in (
        "enum reset_scope", '"reset-confirm"', "control_plane_count",
        "remove_etcd_member", "snapshot_fresh", "cordon_drain", "nftw",
        '"reset-lone-cp"', '"factory-reset:node-identity"',
    ):
        if fragment not in helper:
            errors.append(f"mjolnir-helper: missing reset gate {fragment}")
    if re.search(r'"/bin/sh"|"sh"\s*,', helper):
        errors.append("mjolnir-helper: shell invocation in reset path")

    for scope in ("node-identity", "etcd-data", "full"):
        unit = text(f"files/config/systemd/mjolnir-reset-{scope}.service")
        if "LoadCredentialEncrypted=reset-confirm:/run/credentials/@system/" not in unit:
            errors.append(f"reset {scope}: sealed confirmation is not required")
        if f"mjolnir-helper reset {scope}" not in unit:
            errors.append(f"reset {scope}: unit does not invoke the scoped helper")
    if "mjolnir-etcd-snapshot.timer" not in text("files/config/presets/80-mjolnir.preset"):
        errors.append("snapshot timer is not enabled by preset")

    fleet = text("plugins/console/src/fleet.c")
    for method in ("FactoryReset", "ResetPreflight", "SnapshotNow"):
        if f"io.mjolnir.Fleet.{method}" not in fleet:
            errors.append(f"Varlink: missing {method}")
    if '"node-identity", "etcd-data", "full"' not in fleet:
        errors.append("Varlink: reset scope whitelist is missing")

    for doc in ("docs/SECURITY.md", "docs/PROVISIONING.md",
                "docs/IMPERMANENCE.md", "docs/ARCHITECTURE.md"):
        if not text(doc).strip():
            errors.append(f"missing or empty documentation: {doc}")

    return errors


def main() -> int:
    errors = check()
    if errors:
        print("State/reset static checks FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("State/reset static checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
