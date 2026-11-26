#!/usr/bin/env python3
"""Verify that committed binaries match the sha256 recorded in versions.yml."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSIONS = ROOT / "include/versions.yml"
BINARIES = {
    "amd64": ROOT / "files/varlink/varlink-httpd-amd64",
    "arm64": ROOT / "files/varlink/varlink-httpd-arm64",
}


def main() -> int:
    text = VERSIONS.read_text()
    errors: list[str] = []
    for arch, path in BINARIES.items():
        m = re.search(rf'varlink-httpd-{arch}-sha256:\s*"([0-9a-f]{{64}})"', text)
        if not m:
            errors.append(f"no varlink-httpd {arch} sha256 in include/versions.yml")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != m.group(1):
            errors.append(
                f"varlink-httpd {arch} checksum mismatch: "
                f"expected {m.group(1)}, got {actual}"
            )
    if errors:
        for e in errors:
            print(e, file=__import__("sys").stderr)
        return 1
    print("Binary pins OK (amd64, arm64)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
