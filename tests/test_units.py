#!/usr/bin/env python3
"""Static checks on shipped systemd units and configuration."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UNIT_DIRS = [
    ROOT / "files/config/systemd",
    ROOT / "files/varlink/units",
    ROOT / "plugins/console/files/systemd",
    ROOT / "installer/systemd",
]

FORBIDDEN = [
    re.compile(r"/bin/sh\b"),
    re.compile(r"\bsh\s+-c\b"),
    re.compile(r"/usr/bin/python"),
    re.compile(r"/usr/bin/perl"),
    re.compile(r"\bExecStart=.*\bsshd\b"),
]

PIN = re.compile(r"image:\s*\"?[^\s\"]*[/:][^\s\"]*\"")


def main() -> int:
    errors: list[str] = []
    for d in UNIT_DIRS:
        for unit in d.glob("*"):
            if not unit.is_file():
                continue
            text = unit.read_text()
            for pattern in FORBIDDEN:
                if pattern.search(text):
                    errors.append(f"{unit.relative_to(ROOT)}: matches {pattern.pattern}")
    import interpreter_policy as policy

    allow = policy.load_allowlist()
    units: list[tuple[str, str]] = []
    for d in UNIT_DIRS:
        for unit in d.glob("*"):
            if unit.is_file():
                units.append((str(unit.relative_to(ROOT)), unit.read_text()))
    errors.extend(policy.check_units(units, allow))

    sysusers = ROOT / "files/config/sysusers.d/mjolnir.conf"
    errors.extend(policy.check_login_shells(
        sysusers.read_text() if sysusers.is_file() else "", allow
    ))

    for manifest in (ROOT / "files/manifests").rglob("*.yaml"):
        for lineno, line in enumerate(manifest.read_text().splitlines(), 1):
            if "image:" in line and "@sha256:" not in line:
                errors.append(f"{manifest.relative_to(ROOT)}:{lineno}: unpinned image")

    # The opt-in boot-report unit is gated on a system credential with a
    # dotted name. A rename silently disables the diagnostic, so check the
    # static contract here instead of relying on console text in the VM.
    report = ROOT / "files/config/systemd/mjolnir-boot-report.service"
    report_text = report.read_text() if report.is_file() else ""
    if "/run/credentials/@system/mjolnir.boot-report" not in report_text:
        errors.append("mjolnir-boot-report.service: missing dotted boot-report credential gate")

    # Secure Boot serial needles are an external contract: Gram greps for the
    # exact strings. Check the units, the drop-in that fires on a cryptsetup
    # failure, and the boot assertions that consume them.
    def text_at(relative: str) -> str:
        path = ROOT / relative
        return path.read_text() if path.is_file() else ""

    def require(relative: str, needle: str, label: str) -> None:
        if needle not in text_at(relative):
            errors.append(f"{relative}: missing {label}: {needle!r}")

    unlocked = "files/config/systemd/mjolnir-state-unlocked.service"
    failed = "files/config/systemd/mjolnir-state-unseal-failed.service"
    dropin = ("files/config/systemd/systemd-cryptsetup@mjolnir-state.service.d/"
              "10-mjolnir-failure.conf")
    dracut = "files/config/dracut/50-mjolnir-tpm2.conf"
    boot = "testsuite/boot/test-boot.sh"

    require(unlocked, "ExecStart=/usr/bin/echo MjolnirState: unlocked", "unlock needle")
    require(unlocked, "After=var-lib-mjolnir.mount", "unlock ordering")
    require("files/config/presets/80-mjolnir.preset",
            "enable mjolnir-state-unlocked.service", "unlock preset")
    require(failed, "ExecStart=/usr/bin/echo PCR policy", "PCR needle")
    require(failed, "ExecStart=/usr/bin/echo Failed to unseal", "unseal failure needle")
    # A bare `console` is not a valid StandardOutput= specifier: systemd drops
    # it and the needle never reaches the serial log. Both units must forward
    # through journald *and* the console (enabled by the signed cmdline).
    for unit in (unlocked, failed):
        require(unit, "StandardOutput=journal+console", "journal+console output")
        require(unit, "StandardError=journal+console", "journal+console error output")
        for key in ("StandardOutput", "StandardError"):
            if re.search(rf"^{key}=console\s*$", text_at(unit), re.MULTILINE):
                errors.append(f"{unit}: invalid bare '{key}=console' specifier")
    require(dropin, "OnFailure=mjolnir-state-unseal-failed.service", "failure wiring")
    require(dracut, "mjolnir-state-unseal-failed.service", "initramfs failure unit")
    require(dracut, "10-mjolnir-failure.conf", "initramfs drop-in")
    require(dracut, "/usr/bin/echo", "initramfs echo binary")
    for needle in ("MjolnirState: unlocked", "PCR policy", "Failed to unseal"):
        require(boot, needle, "boot assertion needle")
    # The cases start from a disk whose encrypted state partition already
    # exists; otherwise repart creates it after cryptsetup has timed out.
    require(boot, "provision_state_partition", "state partition provisioning")

    # Lid switches must never suspend an unattended node.
    logind = ROOT / "files/config/logind/50-ignore-lid.conf"
    logind_text = logind.read_text() if logind.is_file() else ""
    for key in ("HandleLidSwitch", "HandleLidSwitchExternalPower", "HandleLidSwitchDocked"):
        if not re.search(rf"^{key}\s*=\s*ignore\s*$", logind_text, re.MULTILINE):
            errors.append(f"{logind.relative_to(ROOT)}: {key} is not set to ignore")
    if errors:
        print("Static configuration checks FAILED:", file=__import__("sys").stderr)
        for e in errors:
            print(f"  - {e}", file=__import__("sys").stderr)
        return 1
    print("Static configuration checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
