#!/usr/bin/env python3
"""Fail the build if the image violates Mjolnir's hard rules.

The image has no shell, so it is inspected from the host via `podman export`.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tarfile

PODMAN = os.environ.get("PODMAN", "podman").split()


FORBIDDEN_EXACT = {
    "bin/sh", "usr/bin/sh", "usr/bin/bash", "bin/bash", "usr/bin/dash",
    "usr/bin/zsh", "usr/bin/fish", "usr/bin/python", "usr/bin/python3",
    "usr/bin/perl", "usr/bin/ruby", "usr/bin/node", "usr/bin/php",
    "usr/bin/lua", "usr/bin/awk", "usr/bin/gawk", "usr/bin/ssh",
    "usr/libexec/iwd", "usr/lib/systemd/system/iwd.service",
    "usr/bin/sshd", "usr/sbin/sshd", "usr/bin/scp", "usr/bin/sftp",
}

FORBIDDEN_PATTERNS = [
    re.compile(r"(^|/)python3?(\.\d+)?$"),
    re.compile(r"(^|/)perl(-?5[^/]*)?$"),
    re.compile(r"(^|/)sshd?$"),
    re.compile(r"(^|/)ssh-keygen$"),
    re.compile(r"\.pyc?$"),
    re.compile(r"\.pl$"),
]

FORBIDDEN_DIRS = (
    "usr/lib/python3", "usr/lib/python2", "usr/lib/perl5",
    "usr/libexec/openssh", "etc/ssh",
)


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=True, capture_output=True, **kw)


def image_files(image: str) -> tuple[list[str], list[tuple[str, int]]]:
    """Return (paths, suid_sgid) from the image tar stream."""
    name = f"mjolnir-inspect-{image.replace('/', '_').replace(':', '_')}"
    sh(PODMAN + ["rm", "-f", name])
    sh(PODMAN + ["create", "--name", name, image])
    try:
        proc = subprocess.Popen(
            PODMAN + ["export", name],
            stdout=subprocess.PIPE,
        )
        assert proc.stdout is not None
        paths: list[str] = []
        suid: list[tuple[str, int]] = []
        with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
            for member in tf:
                p = member.name.lstrip("./")
                paths.append(p)
                if member.isfile() and member.mode & 0o6000:
                    suid.append((p, member.mode))
        rc = proc.wait()
        if rc != 0:
            raise RuntimeError(f"podman export failed: {rc}")
        return paths, suid
    finally:
        sh(PODMAN + ["rm", "-f", name])


def check(image: str) -> list[str]:
    errors: list[str] = []
    paths, suid = image_files(image)
    pathset = set(paths)

    for exact in FORBIDDEN_EXACT:
        if exact in pathset:
            errors.append(f"forbidden binary present: /{exact}")
    for path in paths:
        if path.startswith(("usr/share/licenses/", "usr/share/doc/")):
            continue
        for pattern in FORBIDDEN_PATTERNS:
            if pattern.search(path):
                errors.append(f"forbidden path pattern: /{path}")
                break
    for d in FORBIDDEN_DIRS:
        if any(p == d or p.startswith(d + "/") for p in paths):
            errors.append(f"forbidden directory present: /{d}")

    for path, mode in suid:
        errors.append(f"SUID/SGID bit set: /{path} ({oct(mode)})")

    units = [p for p in paths if p.startswith("usr/lib/systemd/system/")]
    if any("sshd" in u for u in units):
        errors.append("sshd unit present")

    lid_conf = "usr/lib/systemd/logind.conf.d/50-ignore-lid.conf"
    if lid_conf not in pathset:
        errors.append(f"missing required config: /{lid_conf}")
    return errors


def main() -> int:
    image = sys.argv[1] if len(sys.argv) > 1 else "mjolnir:latest"
    errors = check(image)
    if errors:
        print("Mjolnir image content check FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("Mjolnir image content check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
