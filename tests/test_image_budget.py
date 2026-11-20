#!/usr/bin/env python3
"""Assert the built image stays within its compressed-size and layer budget.

Run against the locally loaded image:  python3 tests/test_image_budget.py
Can be run in CI as part of `just test` or as a standalone gate.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys

IMAGE = os.environ.get("IMAGE", "localhost/mjolnir:latest")
PODMAN = os.environ.get("PODMAN", "podman").split()

# Budget: uncompressed image size and OCI layer count. A signed UKI adds a
# small PE file; the budget leaves headroom for that plus KubeStellar updates.
MAX_LAYERS = 128
MAX_SIZE_BYTES = 3 * 1024 * 1024 * 1024  # 3 GiB uncompressed


def main() -> int:
    try:
        out = subprocess.check_output(
            PODMAN + ["image", "inspect", "--format", "{{json .RootFS.Layers}}", IMAGE],
            text=True,
        )
        layers = json.loads(out)
    except Exception as e:  # pragma: no cover - local only
        print(f"cannot inspect image layers: {e}")
        return 1

    try:
        size_out = subprocess.check_output(
            PODMAN + ["image", "inspect", "--format", "{{.Size}}", IMAGE], text=True
        )
        size = int(size_out.strip())
    except Exception as e:  # pragma: no cover - local only
        print(f"cannot inspect image size: {e}")
        return 1

    failures = []
    if len(layers) > MAX_LAYERS:
        failures.append(f"layer count {len(layers)} > budget {MAX_LAYERS}")
    if size > MAX_SIZE_BYTES:
        failures.append(f"image size {size} > budget {MAX_SIZE_BYTES}")

    if failures:
        for f in failures:
            print("FAIL:", f)
        return 1
    print(f"Image budget OK: {len(layers)} layers, {size} bytes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
