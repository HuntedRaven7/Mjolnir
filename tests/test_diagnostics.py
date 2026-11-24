#!/usr/bin/env python3
"""Check the fleet diagnostics contract and journal forwarding setup.

This is a static check plus a real run of the provisioning credential tool.
Image content is checked by test_boot_assets.py after the CI build.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
METHODS = (
    "JournalTail",
    "UnitStatus",
    "BootcStatus",
    "KubeadmPreflight",
    "NetworkChecks",
)


def credential_run(out: Path, socket: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts/make-credentials.py"),
            "--out", str(out),
            "--role", "control-plane",
            "--journal-forward-socket", socket,
        ],
        capture_output=True,
        text=True,
    )


def main() -> int:
    errors: list[str] = []
    fleet = (ROOT / "plugins/console/src/fleet.c").read_text()
    readme = (ROOT / "plugins/console/README.md").read_text()

    for method in METHODS:
        qualified = f'"io.mjolnir.Fleet.{method}"'
        # Once in dispatch, once in the GetInfo methods array.
        if fleet.count(qualified) < 2:
            errors.append(f"fleet.c does not both dispatch and advertise {qualified}")
        if f"`{method}`" not in readme:
            errors.append(f"README does not document {method}")

    karg = ROOT / "files/config/bootc/kargs.d/60-journal-console.toml"
    karg_text = karg.read_text() if karg.is_file() else ""
    for token in ("console=ttyS0,115200", "systemd.journald.forward_to_console=1"):
        if token not in karg_text:
            errors.append(f"{karg.name} is missing {token}")
    files_bst = (ROOT / "elements/config/files.bst").read_text()
    if "60-journal-console.toml" not in files_bst:
        errors.append("files.bst does not install 60-journal-console.toml")
    uki = (ROOT / "elements/uki/mjolnir-uki.bst").read_text()
    if "systemd.journald.forward_to_console=1" not in uki:
        errors.append("UKI does not assert the signed console karg")

    provisioning = (ROOT / "docs/PROVISIONING.md").read_text()
    if "journal.forward_to_socket" not in provisioning:
        errors.append("PROVISIONING.md does not list journal.forward_to_socket")

    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "cred"
        result = credential_run(out, "collector.example:19532")
        if result.returncode != 0:
            errors.append(f"make-credentials.py failed: {result.stderr.strip()}")
        else:
            credential = out / "journal.forward_to_socket"
            if not credential.is_file():
                errors.append("journal.forward_to_socket credential was not written")
            else:
                if credential.read_text().strip() != "collector.example:19532":
                    errors.append("journal.forward_to_socket has the wrong value")
                if credential.stat().st_mode & 0o077:
                    errors.append("journal.forward_to_socket is not mode 0600")
            if "journal.forward_to_socket" not in result.stdout:
                errors.append("make-credentials.py did not report the credential name")

        bad = credential_run(Path(tmp) / "bad", "collector.example:19532 extra")
        if bad.returncode == 0:
            errors.append("make-credentials.py accepted whitespace in a socket address")

    architecture = (ROOT / "docs/ARCHITECTURE.md").read_text()
    if "rolls back a staged deployment" not in architecture:
        errors.append("ARCHITECTURE.md does not record bootc rollback")

    if errors:
        print("Diagnostics contract check FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("Diagnostics contract check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
