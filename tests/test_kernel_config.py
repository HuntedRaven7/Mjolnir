#!/usr/bin/env python3
"""Verify Cilium's kernel requirements against the pinned FSDK kernel config.

By default this fetches files/linux/fdsdk-config.sh from the FSDK commit pinned
in include/versions.yml. FSDK applies that script to the kernel defconfig and
fails its own build when an `enable`/`module` directive is not satisfied, so a
directive here is a promise about the shipped kernel. Use --config to check a
local copy of the script instead.

What this does not verify: the built image's final .config, module loading, or
Cilium becoming Ready. Those need the boot test documented in docs/BUILD.md.

An option that Cilium needs but the pinned FSDK config does not enable is an
error unless it is listed with --known-gap. A stale --known-gap entry is also
an error, so the accepted-gap list cannot drift silently.
"""

from __future__ import annotations

import argparse
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FSDK_CONFIG_PATH = "files/linux/fdsdk-config.sh"
TIMEOUT = 30

# Option -> why Cilium needs it. The map is the requirement, not the FSDK config.
REQUIRED = {
    "BPF_SYSCALL": "BPF program load and map syscalls",
    "CGROUP_BPF": "cgroup BPF hooks for kube-proxy replacement",
    "BPF_JIT": "JIT-compiled BPF datapath",
    "NETFILTER": "iptables/nftables fallback path",
    "NF_CONNTRACK": "connection tracking for NAT and policy",
    "VXLAN": "Cilium tunnel-protocol: vxlan in files/manifests/cilium/00-cilium.yaml",
}

DIRECTIVE = re.compile(r"^\s*(?:enable|module)\s+([A-Z][A-Z0-9_]*)\b", re.MULTILINE)


def fsdk_ref() -> str:
    text = (ROOT / "include/versions.yml").read_text()
    m = re.search(r'^\s*fsdk-ref:\s*"[^"]*-g([0-9a-f]{40})"', text, re.MULTILINE)
    if not m:
        raise ValueError("no pinned fsdk-ref commit in include/versions.yml")
    return m.group(1)


def alias(name: str) -> str:
    for line in (ROOT / "include/aliases.yml").read_text().splitlines():
        m = re.match(rf"^  {re.escape(name)}:\s*(\S+)\s*$", line)
        if m:
            return m.group(1)
    raise ValueError(f"no {name} alias in include/aliases.yml")


def fetch_config() -> str:
    base = alias("gitlab") + "freedesktop-sdk/freedesktop-sdk/-/raw"
    url = f"{base}/{fsdk_ref()}/{FSDK_CONFIG_PATH}"
    request = urllib.request.Request(url, headers={"User-Agent": "mjolnir-ci/1"})
    with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
        return response.read().decode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, help="check a local FSDK config script")
    parser.add_argument(
        "--known-gap", action="append", default=[], metavar="OPTION",
        help="accept one missing option (must be in REQUIRED); stale entries fail",
    )
    args = parser.parse_args()

    text = args.config.read_text() if args.config else fetch_config()
    enabled = set(DIRECTIVE.findall(text))
    errors: list[str] = []

    for option, reason in REQUIRED.items():
        present = option in enabled
        accepted = option in args.known_gap
        if present and accepted:
            errors.append(f"{option} is now enabled; remove it from --known-gap")
        elif present:
            print(f"OK        {option}: {reason}")
        elif accepted:
            print(f"KNOWN GAP {option}: {reason}")
        else:
            errors.append(f"{option} is not enabled by the pinned FSDK config: {reason}")

    unknown = set(args.known_gap) - set(REQUIRED)
    for option in sorted(unknown):
        errors.append(f"unknown --known-gap option: {option}")

    if errors:
        print("Kernel config check FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("Kernel config check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
