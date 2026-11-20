#!/usr/bin/env python3
"""Static checks on shipped systemd units and configuration."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UNIT_DIRS = [ROOT / "files/config/systemd", ROOT / "files/varlink/units"]

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
    for manifest in (ROOT / "files/manifests").rglob("*.yaml"):
        for lineno, line in enumerate(manifest.read_text().splitlines(), 1):
            if "image:" in line and "@sha256:" not in line:
                errors.append(f"{manifest.relative_to(ROOT)}:{lineno}: unpinned image")
    if errors:
        print("Static configuration checks FAILED:", file=__import__("sys").stderr)
        for e in errors:
            print(f"  - {e}", file=__import__("sys").stderr)
        return 1
    print("Static configuration checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
