#!/usr/bin/env python3
"""Check fleet.c's child runner: timeouts, output cap and no-hang error paths.

The test extracts the real run_capture_timeout() from fleet.c and compiles it
into a libc-only probe. No image build, json-c or systemd headers are needed.
Skip cleanly when no C compiler is available.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLEET = ROOT / "plugins/console/src/fleet.c"
RUNNER_END = "\n// Status queries and read-only diagnostics:"

PREAMBLE = r"""
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
"""

CHILD = r"""
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";
    if (!strcmp(mode, "slow")) sleep(30);
    else if (!strcmp(mode, "eof")) { close(1); sleep(30); }
    else if (!strcmp(mode, "cap")) {
        char block[8192];
        memset(block, 'A', sizeof(block));
        for (int i = 0; i < 16; i++) fwrite(block, 1, sizeof(block), stdout);
        fflush(stdout);
    }
    return 7;
}
"""

PROBE = r"""
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    int timeout = atoi(argv[1]);
    size_t cap = (size_t)atoi(argv[2]);
    char *out = malloc(cap);
    const char *const cmd[] = { argv[3], argv[4], NULL };
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    int rc = run_capture_timeout(cmd, out, cap, timeout);
    clock_gettime(CLOCK_MONOTONIC, &b);
    printf("rc=%d elapsed_ms=%ld outlen=%zu\n", rc,
        (long)((b.tv_sec - a.tv_sec) * 1000 + (b.tv_nsec - a.tv_nsec) / 1000000),
        strlen(out));
    return 0;
}
"""

POLL_ERROR = """
static int injected_poll(struct pollfd *f, nfds_t n, int t) {
    (void)f; (void)n; (void)t; errno = EIO; return -1;
}
#define poll(f, n, t) injected_poll(f, n, t)
"""

READ_ERROR = """
static ssize_t injected_read(int fd, void *buf, size_t n) {
    (void)fd; (void)buf; (void)n; errno = EIO; return -1;
}
#define read(fd, buf, n) injected_read(fd, buf, n)
"""


def policy_checks(fleet: str, errors: list[str]) -> None:
    if "#define DIAG_TIMEOUT_MS 5000" not in fleet:
        errors.append("fleet.c no longer sets the 5 s diagnostic deadline")
    if "DEFAULT_TIMEOUT_MS" in fleet:
        errors.append("fleet.c still has the blanket 15 s DEFAULT_TIMEOUT_MS")
    upgrade = fleet.split('method, "io.mjolnir.Fleet.Upgrade"', 1)
    if len(upgrade) != 2:
        errors.append("fleet.c has no Upgrade branch")
    else:
        branch = upgrade[1].split("\n    }", 1)[0]
        if "UPGRADE_TIMEOUT_MS" not in branch:
            errors.append("Upgrade does not use its own long deadline")
        if "run_quiet(argv)" in branch:
            errors.append("Upgrade is back on the short run_quiet deadline")
    match = re.search(r"#define\s+UPGRADE_TIMEOUT_MS\s+\((\d+)\s*\*\s*60\s*\*\s*1000\)", fleet)
    if not match or int(match.group(1)) < 10:
        errors.append("Upgrade deadline must be at least 10 minutes")


def compile_probe(cc: str, workdir: Path, runner: str, name: str, inject: str,
                  errors: list[str]) -> Path | None:
    source = PREAMBLE + inject + runner + PROBE
    (workdir / f"{name}.c").write_text(source)
    binary = workdir / name
    result = subprocess.run(
        [cc, "-Wall", "-Wextra", "-O0", "-o", str(binary), str(workdir / f"{name}.c")],
        capture_output=True, text=True,
    )
    if result.returncode:
        errors.append(f"{name} probe did not compile: {result.stderr.strip()[:400]}")
        return None
    return binary


def probe_run(binary: Path, timeout_ms: int, cap: int, child: Path, mode: str,
              limit: float, errors: list[str], label: str) -> tuple[int, int, int]:
    try:
        result = subprocess.run(
            [str(binary), str(timeout_ms), str(cap), str(child), mode],
            capture_output=True, text=True, timeout=limit,
        )
    except subprocess.TimeoutExpired:
        errors.append(f"{label}: runner hung (killed after {limit:g}s)")
        return -999, -1, -1
    if result.returncode:
        errors.append(f"{label}: probe failed: {result.stderr.strip()[:200]}")
        return -999, -1, -1
    values = dict(part.split("=") for part in result.stdout.strip().split())
    return int(values["rc"]), int(values["elapsed_ms"]), int(values["outlen"])


def main() -> int:
    errors: list[str] = []
    fleet = FLEET.read_text()
    policy_checks(fleet, errors)

    cc = shutil.which("cc") or shutil.which("gcc")
    if not cc:
        print("C compiler not available; runner policy checks only")
        if errors:
            print("Fleet runner policy FAILED:", file=__import__("sys").stderr)
            for error in errors:
                print(f"  - {error}", file=__import__("sys").stderr)
            return 1
        print("Fleet runner policy passed (behavioral probes skipped)")
        return 0

    start = fleet.index("static int run_capture_timeout(")
    runner = fleet[start:fleet.index(RUNNER_END, start)]

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        child_src = workdir / "child.c"
        child_src.write_text(CHILD)
        child = workdir / "child"
        built = subprocess.run(
            [cc, "-O0", "-o", str(child), str(child_src)], capture_output=True, text=True
        )
        if built.returncode:
            print(f"child helper did not compile: {built.stderr.strip()}", file=__import__("sys").stderr)
            return 1

        normal = compile_probe(cc, workdir, runner, "probe_normal", "", errors)
        bad_poll = compile_probe(cc, workdir, runner, "probe_poll", POLL_ERROR, errors)
        bad_read = compile_probe(cc, workdir, runner, "probe_read", READ_ERROR, errors)
        if errors:
            for error in errors:
                print(f"  - {error}", file=__import__("sys").stderr)
            return 1
        assert normal and bad_poll and bad_read

        rc, ms, n = probe_run(normal, 120, 1024, child, "slow", 5, errors, "timeout")
        if rc != 124 or ms > 1500:
            errors.append(f"slow child: rc={rc} elapsed_ms={ms}, want 124 and <=1500")

        rc, _, n = probe_run(normal, 2000, 64, child, "cap", 5, errors, "cap")
        if rc != 7 or n != 63:
            errors.append(f"output cap: rc={rc} outlen={n}, want 7 and 63")

        rc, ms, _ = probe_run(normal, 300, 1024, child, "eof", 5, errors, "eof")
        if rc != 124 or ms > 1500:
            errors.append(f"closed stdout with live child: rc={rc} elapsed_ms={ms}, want 124 and <=1500")

        for label, binary in (("poll error", bad_poll), ("read error", bad_read)):
            rc, ms, _ = probe_run(binary, 10000, 1024, child, "fast", 5, errors, label)
            if rc != -1 or ms > 1500:
                errors.append(f"{label}: rc={rc} elapsed_ms={ms}, want -1 and <=1500")

    if errors:
        print("Fleet runner checks FAILED:", file=__import__("sys").stderr)
        for error in errors:
            print(f"  - {error}", file=__import__("sys").stderr)
        return 1
    print("Fleet runner checks passed (timeout, cap, EOF, poll and read errors)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
