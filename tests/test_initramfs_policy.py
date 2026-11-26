#!/usr/bin/env python3
"""Unit tests for the initramfs interpreter gate; no image build required."""

from __future__ import annotations

import compression.zstd
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import interpreter_policy as policy


def newc(path: str, payload: bytes = b"", mode: int = 0o100644) -> bytes:
    fields = [
        b"070701", b"00000001", f"{mode:08x}".encode(), b"00000000",
        b"00000000", b"00000001", b"00000000", f"{len(payload):08x}".encode(),
        b"00000000", b"00000000", b"00000000", b"00000000",
        f"{len(path) + 1:08x}".encode(), b"00000000",
    ]
    out = b"".join(fields) + path.encode() + b"\0"
    out += b"\0" * ((-len(out)) % 4)
    out += payload
    out += b"\0" * ((-len(out)) % 4)
    return out


def cpio(entries: list[bytes]) -> bytes:
    return b"".join(entries) + newc("TRAILER!!!", mode=0)


def initramfs(entries: list[bytes], microcode: bool = False) -> bytes:
    prefix = cpio([newc("kernel/x86/microcode/ucode.bin", b"ucode")]) if microcode else b""
    # dracut pads the microcode archive before the compressed one.
    return prefix + (b"\0" * 64 if microcode else b"") + compression.zstd.compress(cpio(entries))


def check(blob: bytes):
    members = policy.iter_initramfs_members(blob)
    return policy.check_initramfs(members)


def test_clean_initramfs_passes() -> None:
    blob = initramfs([
        newc("usr/bin/mjolnir-helper", b"\x7fELFcompiled", mode=0o100755),
        newc("etc/hostname", b"mjolnir\n"),
    ])
    assert check(blob) == []


def test_shell_and_hook_script_fail() -> None:
    blob = initramfs([
        newc("usr/bin/bash", b"\x7fELFcompiled", mode=0o100755),
        newc("bin/sh", b"bash", mode=0o120777),
        newc("usr/lib/dracut/hooks/initqueue/50mount.sh", b"#!/bin/sh\nmount /dev/root\n"),
    ])
    errors = check(blob)
    assert len(errors) == 3, errors
    assert any("/usr/bin/bash" in e and "interpreter binary" in e for e in errors)
    assert any("/bin/sh" in e for e in errors)
    assert any("50mount.sh" in e and "#!/bin/sh" in e for e in errors)


def test_microcode_prefix_is_walked() -> None:
    blob = initramfs([newc("bin/sh", b"bash", mode=0o120777)], microcode=True)
    assert any("/bin/sh" in e for e in check(blob))


def test_no_allowlist_escape_hatch() -> None:
    assert "initramfs" not in policy.SECTIONS
    blob = initramfs([newc("usr/bin/bash", b"\x7fELF", mode=0o100755)])
    assert check(blob)


def test_malformed_initramfs_fails_loudly() -> None:
    try:
        policy.iter_initramfs_members(b"not an initramfs")
    except ValueError:
        return
    raise AssertionError("malformed initramfs did not raise")


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for test in tests:
        test()
        print(f"ok {test.__name__}")
    print(f"{len(tests)} initramfs policy tests passed")
