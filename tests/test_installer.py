#!/usr/bin/env python3
"""Smoke-test the static Go installer without executing a real install."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GO = os.environ.get("GO", "go")
binary = Path(tempfile.gettempdir()) / "mjolnir-installer-test"


def main() -> int:
    # Keep the Go module versions in sync with the canonical pins. go.sum holds
    # the exact module checksums; versions.yml owns the version facts.
    versions_text = (ROOT / "include/versions.yml").read_text()
    gomod_text = (ROOT / "installer/go.mod").read_text()
    for key, module in (
        ("installer-tui-bubbletea-ref", "github.com/charmbracelet/bubbletea"),
        ("installer-tui-huh-ref", "github.com/charmbracelet/huh"),
        ("installer-tui-lipgloss-ref", "github.com/charmbracelet/lipgloss"),
    ):
        m = re.search(rf'^\s*{key}:\s*"([^"]+)"', versions_text, re.MULTILINE)
        if not m or f"{module} {m.group(1)}" not in gomod_text:
            print(f"{key} does not match installer/go.mod", file=sys.stderr)
            return 1

    # Go is not present on every build host (CI installs it explicitly).
    # Skip the installer build smoke-test rather than failing `just test` when
    # the toolchain is absent; the ISO workflow exercises it where it matters.
    if shutil.which(GO) is None:
        print(f"SKIP: installer check ({GO} not installed)")
        return 0

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
        "image": "ghcr.io/huntedraven7/mjolnir:latest",
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
