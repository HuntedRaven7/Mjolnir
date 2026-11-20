#!/usr/bin/env python3
"""Smoke-test the static Go installer without executing a real install."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GO = os.environ.get("GO", "go")
binary = Path(tempfile.gettempdir()) / "mjolnir-installer-test"


def main() -> int:
    build = subprocess.run(
        [GO, "build", "-o", str(binary), "."],
        cwd=ROOT / "installer",
        capture_output=True,
        text=True,
    )
    if build.returncode != 0:
        print(build.stderr, file=sys.stderr)
        return 1

    version = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=True)
    if "mjolnir-installer" not in version.stdout:
        print("unexpected --version output", file=sys.stderr)
        return 1

    cfg = {
        "image": "ghcr.io/HuntedRaven7/Mjolnir:latest",
        "disk": "/dev/vda",
        "role": "worker",
        "ssid": "test",
        "psk": "0" * 64,
        "filesystem": "btrfs",
    }
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(cfg, f)
        path = f.name
    try:
        result = subprocess.run(
            [str(binary), "--dry-run", "--config", path],
            capture_output=True,
            text=True,
        )
    finally:
        os.unlink(path)

    out = result.stdout + result.stderr
    if result.returncode != 0:
        print(out, file=sys.stderr)
        return 1
    for expected in ("podman pull", "bootc install to-disk", "WiFi keyfile", "to-disk"):
        if expected not in out:
            print(f"missing expected dry-run output: {expected}", file=sys.stderr)
            return 1
    print("Installer check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
