#!/usr/bin/env python3
"""Static checks on the bootc blkid fallback used by the install harness.

bootc reads partition metadata from lsblk. Under --pid=host the udev database
has no record for partitions created during install, so parttype, fstype and
the filesystem UUID can all be null. The patch backfills each from a direct
blkid probe; dropping any one of them breaks a different stage of the install.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    errors: list[str] = []
    patch = ROOT / "files/patches/bootc-parttype-blkid.patch"
    if not patch.is_file():
        print("bootc blkid patch is missing", flush=True)
        return 1
    body = patch.read_text()
    # Only added lines describe the new behaviour; removed lines quote the old
    # udev-only gate and would give a false positive below.
    added = "\n".join(
        line[1:] for line in body.splitlines()
        if line.startswith("+") and not line.startswith("+++")
    )

    for field, tag in (
        ("parttype", "PART_ENTRY_TYPE"),
        ("pttype", "PTTYPE"),
        ("fstype", "TYPE"),
        ("uuid", "UUID"),
    ):
        if f"self.{field}.is_none()" not in body or f'props.get("{tag}")' not in body:
            errors.append(f"patch no longer backfills {field} from blkid tag {tag}")
        if f"self.{field}.is_none()" not in added.split("let props", 1)[0]:
            errors.append(f"patch no longer probes when {field} is missing")

    if "PART_ENTRY_TYPE" not in body:
        errors.append("patch lost the DPS parttype probe")
    if "!have_udev()" in added:
        errors.append("patch reintroduced the udev-only probe gate")

    for error in errors:
        print(error, flush=True)
    if errors:
        return 1
    print("bootc blkid fallback checks passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
