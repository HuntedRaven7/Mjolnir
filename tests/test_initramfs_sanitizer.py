#!/usr/bin/env python3
"""Prove the initramfs sanitizer removes shells but keeps the compiled boot path."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import interpreter_policy as policy

SANITIZER = ROOT / "scripts" / "sanitize-initramfs.sh"


def write(path: Path, text: str = "") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def cpio_of(tree: Path) -> bytes:
    files = subprocess.run(
        ["find", ".", "-print0"], cwd=tree, check=True, stdout=subprocess.PIPE
    ).stdout
    return subprocess.run(
        ["cpio", "--null", "-o", "-H", "newc", "--quiet",
         "--owner=0:0", "--numeric-uid-gid"],
        cwd=tree, input=files, check=True, stdout=subprocess.PIPE,
    ).stdout


def test_sanitizer_strips_shells_and_keeps_compiled_boot() -> None:
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        tree = work / "tree"
        write(tree / "usr/lib/bootc/initramfs-setup", "ELF")
        write(tree / "usr/lib/systemd/system/bootc-root-setup.service",
              "[Service]\nExecStart=/usr/lib/bootc/initramfs-setup setup-root\n")
        write(tree / "usr/lib/systemd/system/dracut-cmdline.service",
              "[Service]\nExecStart=-/usr/bin/dracut-cmdline\n")
        (tree / "etc/systemd/system/initrd.target.wants/dracut-cmdline.service").parent.mkdir(
            parents=True, exist_ok=True
        )
        (tree / "etc/systemd/system/initrd.target.wants/dracut-cmdline.service").symlink_to(
            "../../../usr/lib/systemd/system/dracut-cmdline.service"
        )
        write(tree / "usr/bin/dracut-cmdline", "#!/bin/sh\nexit 0\n")
        write(tree / "usr/bin/bash", "ELF")
        (tree / "usr/bin/sh").symlink_to("bash")
        write(tree / "var/lib/dracut/hooks/cmdline/00-parse-root.sh", "#!/bin/sh\n")

        raw = work / "raw.img"
        raw.write_bytes(subprocess.run(
            ["zstd", "-q", "-19", "-f", "-c"], input=cpio_of(tree),
            check=True, stdout=subprocess.PIPE,
        ).stdout)

        # Control: the generated archive must fail the strict gate before the fix.
        assert policy.check_initramfs(policy.iter_initramfs_members(raw.read_bytes()))

        clean = work / "clean.img"
        subprocess.run([str(SANITIZER), str(raw), str(clean)], check=True)
        members = policy.iter_initramfs_members(clean.read_bytes())
        assert policy.check_initramfs(members) == []
        paths = {m.path for m in members}
        assert "usr/lib/bootc/initramfs-setup" in paths
        assert "usr/lib/systemd/system/bootc-root-setup.service" in paths
        assert "usr/lib/systemd/system/dracut-cmdline.service" not in paths
        assert "usr/bin/bash" not in paths
        assert "usr/bin/sh" not in paths


def test_sanitizer_preserves_microcode_prefix() -> None:
    with tempfile.TemporaryDirectory() as td:
        work = Path(td)
        tree = work / "tree"
        write(tree / "usr/lib/bootc/initramfs-setup", "ELF")
        prefix = cpio_of(tree)
        payload = subprocess.run(
            ["zstd", "-q", "-19", "-f", "-c"], input=prefix,
            check=True, stdout=subprocess.PIPE,
        ).stdout
        raw = work / "raw.img"
        raw.write_bytes(prefix + b"\0" * 64 + payload)
        clean = work / "clean.img"
        subprocess.run([str(SANITIZER), str(raw), str(clean)], check=True)
        assert clean.read_bytes().startswith(prefix)


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok {name}")
    print("sanitizer tests passed")
