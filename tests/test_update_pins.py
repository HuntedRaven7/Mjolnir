#!/usr/bin/env python3
"""Offline checks for scripts/update_pins.py (no network calls)."""
from __future__ import annotations

import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("update_pins", ROOT / "scripts/update_pins.py")
mod = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(mod)


def main() -> int:
    versions = mod.get_versions()
    for key in (
        "fsdk-ref", "kubernetes-version", "kubelet-amd64-sha256",
        "crictl-version", "containerd-version", "runc-version",
        "cni-plugins-version", "kured-image-digest",
        "virt-firmware-version", "virt-firmware-wheel-sha256",
    ):
        if key not in versions:
            print(f"missing version key: {key}")
            return 1

    # Every binary sha256 must be 64 hex chars.
    for key, value in versions.items():
        if key.endswith("-sha256"):
            if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
                print(f"invalid sha256 for {key}: {value}")
                return 1
        if key.endswith("-digest") and not value.startswith("sha256:"):
            print(f"invalid digest for {key}: {value}")
            return 1

    out = mod.set_key(Path("unused"), "a", "new", text='a: "old"\nb: "keep"\n')
    if out != 'a: "new"\nb: "keep"\n':
        print("set_key failed")
        return 1
    print("Update-pins check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
