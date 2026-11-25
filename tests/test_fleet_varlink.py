#!/usr/bin/env python3
"""Check that an idle Varlink client cannot wedge the single-threaded loop.

The behavioral part extracts the real handle_client() from fleet.c and compiles
it into a libc-only probe with stubbed json-c and dispatch. No image build,
json-c or systemd headers are needed. It skips cleanly without a C compiler.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLEET = ROOT / "plugins/console/src/fleet.c"
HANDLER_END = "\nstatic void cmd_varlink(void)"

PREAMBLE = r"""
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define DIAG_TIMEOUT_MS @@DEADLINE@@
#define JSON_C_TO_STRING_PLAIN 0

struct json_object { int unused; };
typedef struct json_object json_object;
static json_object FAKE;
json_object *json_tokener_parse(const char *s) { (void)s; return &FAKE; }
json_object *json_object_new_object(void) { return &FAKE; }
json_object *json_object_new_string(const char *s) { (void)s; return &FAKE; }
void json_object_object_add(json_object *o, const char *k, json_object *v) {
    (void)o; (void)k; (void)v;
}
void json_object_object_del(json_object *o, const char *k) { (void)o; (void)k; }
int json_object_object_get_ex(json_object *o, const char *k, json_object **v) {
    (void)o; (void)k; if (v) *v = NULL; return 0;
}
json_object *json_object_get(json_object *o) { (void)o; return &FAKE; }
const char *json_object_get_string(json_object *o) { (void)o; return ""; }
const char *json_object_to_json_string_ext(json_object *o, int f) {
    (void)o; (void)f; return "{}";
}
void json_object_put(json_object *o) { (void)o; }
json_object *dispatch(json_object *req) { (void)req; return &FAKE; }
"""

PROBE = r"""
static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int main(void) {
    int idle[2], active[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, idle) != 0) return 2;
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, active) != 0) return 2;

    // The second client sends a complete Status call before the first is read.
    const char *req = "{\"method\":\"io.mjolnir.Fleet.Status\",\"id\":1}";
    size_t nreq = strlen(req);
    if (write(active[1], req, nreq) != (ssize_t)nreq) return 2;
    if (write(active[1], "\0", 1) != 1) return 2;
    shutdown(active[1], SHUT_WR);

    // The accept loop serves one client at a time. An idle first client must
    // be dropped so this call returns instead of blocking forever.
    long t0 = now_ms();
    handle_client(idle[0]);
    long elapsed = now_ms() - t0;

    char c;
    int idle_eof = recv(idle[1], &c, 1, 0);

    handle_client(active[0]);
    char rbuf[256];
    ssize_t bytes = recv(active[1], rbuf, sizeof(rbuf), 0);
    int has_nul = 0;
    for (ssize_t i = 0; i < bytes; i++)
        if (rbuf[i] == '\0') has_nul = 1;

    printf("idle_elapsed_ms=%ld idle_eof=%d active_bytes=%zd active_nul=%d\n",
           elapsed, idle_eof, bytes, has_nul);
    close(idle[1]);
    close(active[1]);
    return 0;
}
"""

DIAGNOSTICS = (
    "JournalTail",
    "UnitStatus",
    "BootcStatus",
    "KubeadmPreflight",
    "NetworkChecks",
)


def policy_checks(fleet: str, handler: str, errors: list[str]) -> int:
    match = re.search(r"^#define\s+DIAG_TIMEOUT_MS\s+(\d+)", fleet, re.MULTILINE)
    deadline = int(match.group(1)) if match else 5000
    if not match:
        errors.append("fleet.c no longer defines DIAG_TIMEOUT_MS")
    if "SO_RCVTIMEO" not in handler or "DIAG_TIMEOUT_MS" not in handler:
        errors.append("handle_client has no receive deadline tied to DIAG_TIMEOUT_MS")
    if "#define DIAG_OUTPUT_MAX 65536" not in fleet:
        errors.append("fleet.c no longer caps diagnostics output at 64 KiB")
    for method in DIAGNOSTICS:
        if f'"io.mjolnir.Fleet.{method}"' not in fleet:
            errors.append(f"fleet.c no longer dispatches {method}")
    return deadline


def main() -> int:
    errors: list[str] = []
    fleet = FLEET.read_text()
    start = fleet.index("static void handle_client(")
    handler = fleet[start:fleet.index(HANDLER_END, start)]
    deadline = policy_checks(fleet, handler, errors)

    cc = shutil.which("cc") or shutil.which("gcc")
    if not cc:
        print("C compiler not available; varlink policy checks only")
        if errors:
            print("Varlink receive-deadline checks FAILED:", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
            return 1
        print("Varlink receive-deadline policy passed (behavioral probe skipped)")
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        source = workdir / "probe.c"
        source.write_text(PREAMBLE.replace("@@DEADLINE@@", str(deadline)) + handler + PROBE)
        binary = workdir / "probe"
        built = subprocess.run(
            [cc, "-Wall", "-Wextra", "-O0", "-o", str(binary), str(source)],
            capture_output=True, text=True,
        )
        if built.returncode:
            errors.append(f"probe did not compile: {built.stderr.strip()[:400]}")
        else:
            try:
                result = subprocess.run(
                    [str(binary)], capture_output=True, text=True, timeout=15
                )
            except subprocess.TimeoutExpired:
                errors.append("idle client wedged handle_client (killed after 15s)")
            else:
                if result.returncode:
                    errors.append(f"probe failed: {result.stderr.strip()[:200]}")
                else:
                    values = dict(
                        part.split("=") for part in result.stdout.strip().split()
                    )
                    elapsed = int(values["idle_elapsed_ms"])
                    if values["idle_eof"] != "0":
                        errors.append("idle client was not disconnected")
                    if not (deadline - 1000 <= elapsed <= deadline + 3000):
                        errors.append(
                            f"idle client dropped after {elapsed} ms, "
                            f"want {deadline} to {deadline + 3000} ms"
                        )
                    if int(values["active_bytes"]) < 3 or values["active_nul"] != "1":
                        errors.append("second client did not get a NUL-terminated reply")

    if errors:
        print("Varlink receive-deadline checks FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("Varlink receive-deadline checks passed (idle drop, deadline, second client)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
