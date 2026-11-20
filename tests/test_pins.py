#!/usr/bin/env python3
"""Verify that committed binaries match the sha256 recorded in versions.yml."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSIONS = ROOT / "include/versions.yml"
BINARY = ROOT / "files/varlink/varlink-httpd-amd64"


def main() -> int:
    text = VERSIONS.read_text()
    m = re.search(r'varlink-httpd-amd64-sha256:\s*"([0-9a-f]{64})"', text)
    if not m:
        print("no varlink-httpd sha256 in include/versions.yml", file=__import__("sys").stderr)
        return 1
    actual = hashlib.sha256(BINARY.read_bytes()).hexdigest()
    if actual != m.group(1):
        print(f"varlink-httpd checksum mismatch: expected {m.group(1)}, got {actual}",
              file=__import__("sys").stderr)
        return 1
    print("Binary pins OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
