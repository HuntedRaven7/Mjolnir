#!/usr/bin/env python3
"""Compile the shipped member-id parser and exercise it with etcdctl output.

The reset helper deletes the etcd member it finds, so a parser that rejects a
real `-o simple` row would block multi-control-plane factory reset.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Verbatim shape of `etcdctl member list -o simple` (comma-delimited fields).
SIMPLE = """\
8211f1d0f64f3269, started, mjolnir-1, https://10.0.0.1:2380, https://10.0.0.1:2379, false
b6b6c8e2f0a4d9e1, started, mjolnir-2, https://10.0.0.2:2380, https://10.0.0.2:2379, false
e1d2c3b4a5968778, started, mjolnir-3, https://10.0.0.3:2380, https://10.0.0.3:2379, false
"""

MALFORMED_HEX = "zzzz1234, started, mjolnir-1, https://10.0.0.1:2380\n"
COLON_FORMAT = "8211f1d0f64f3269: started mjolnir-1\n"


def main() -> int:
    errors: list[str] = []
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "member_id_harness"
        compile_result = subprocess.run(
            [
                "cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                "-I", str(ROOT / "src"),
                "-o", str(binary),
                str(ROOT / "tests" / "member_id_harness.c"),
            ],
            capture_output=True,
            text=True,
        )
        if compile_result.returncode != 0:
            print(compile_result.stderr, file=sys.stderr)
            return 1

        def run(stdin: str, self: str = "mjolnir-1") -> str:
            result = subprocess.run(
                [str(binary), self], input=stdin, capture_output=True, text=True
            )
            if result.returncode != 0:
                errors.append(f"harness exited {result.returncode}: {result.stderr.strip()}")
            return result.stdout.strip()

        cases = (
            (SIMPLE, "mjolnir-1", "8211f1d0f64f3269"),
            (SIMPLE, "mjolnir-3", "e1d2c3b4a5968778"),
            (MALFORMED_HEX, "mjolnir-1", "REJECT"),
            (COLON_FORMAT, "mjolnir-1", "REJECT"),
            (SIMPLE, "mjolnir-not-a-member", "REJECT"),
        )
        for stdin, self, expected in cases:
            actual = run(stdin, self)
            if actual != expected:
                errors.append(
                    f"member_id({self!r}) returned {actual!r}, expected {expected!r}"
                )

    if errors:
        print("etcd member-id parser checks FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("etcd member-id parser checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
