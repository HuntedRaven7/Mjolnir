#!/usr/bin/env python3
"""Check that the arm64 sources pinned for the aarch64 graph are still served.

This mirrors the URLs in elements/k8s/binaries-src.bst for arch=aarch64. It
issues one HTTP HEAD per source; it does not download, compile, or run a binary,
and it does not build an aarch64 image. BuildStream verifies each sha256 when it
fetches the source, so a changed artifact still fails the real build.

Run in CI by the validate-arm64 job in .github/workflows/build.yml.
"""

from __future__ import annotations

import importlib.util
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TIMEOUT = 30

# (label, URL template, sha256 key in include/versions.yml). Templates use the
# same BuildStream source aliases as k8s/binaries-src.bst, with %{go-arch}
# resolved to arm64 by project.conf for arch=aarch64.
SOURCES = [
    ("kubelet", "k8s:v{kubernetes-version}/bin/linux/arm64/kubelet",
     "kubelet-arm64-sha256"),
    ("kubeadm", "k8s:v{kubernetes-version}/bin/linux/arm64/kubeadm",
     "kubeadm-arm64-sha256"),
    ("kubectl", "k8s:v{kubernetes-version}/bin/linux/arm64/kubectl",
     "kubectl-arm64-sha256"),
    ("crictl", "github:kubernetes-sigs/cri-tools/releases/download/v{crictl-version}/"
     "crictl-v{crictl-version}-linux-arm64.tar.gz", "crictl-arm64-sha256"),
    ("containerd", "github:containerd/containerd/releases/download/v{containerd-version}/"
     "containerd-{containerd-version}-linux-arm64.tar.gz", "containerd-arm64-sha256"),
    ("runc", "github:opencontainers/runc/releases/download/v{runc-version}/runc.arm64",
     "runc-arm64-sha256"),
    ("cni-plugins", "github:containernetworking/plugins/releases/download/"
     "v{cni-plugins-version}/cni-plugins-linux-arm64-v{cni-plugins-version}.tgz",
     "cni-plugins-arm64-sha256"),
]


def load_versions() -> dict[str, str]:
    spec = importlib.util.spec_from_file_location(
        "update_pins", ROOT / "scripts/update_pins.py"
    )
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(mod)
    return mod.get_versions()


def load_aliases() -> dict[str, str]:
    aliases: dict[str, str] = {}
    for line in (ROOT / "include/aliases.yml").read_text().splitlines():
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(\S+)\s*$", line)
        if m:
            aliases[m.group(1)] = m.group(2)
    return aliases


def resolve(url: str, aliases: dict[str, str]) -> str:
    prefix, sep, rest = url.partition(":")
    if not sep:
        return url
    if prefix not in aliases:
        raise KeyError(f"unknown source alias: {prefix}")
    return aliases[prefix] + rest


def available(url: str) -> tuple[bool, str]:
    request = urllib.request.Request(
        url, method="HEAD", headers={"User-Agent": "mjolnir-ci/1"}
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return 200 <= response.status < 400, f"HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        # A few release mirrors reject HEAD; a ranged GET still proves the
        # artifact is served without pulling the whole binary.
        if exc.code in (403, 405, 501):
            ranged = urllib.request.Request(
                url, headers={"User-Agent": "mjolnir-ci/1", "Range": "bytes=0-0"}
            )
            try:
                with urllib.request.urlopen(ranged, timeout=TIMEOUT) as response:
                    return 200 <= response.status < 400, f"HTTP {response.status} (GET range)"
            except urllib.error.HTTPError as exc2:
                return False, f"HTTP {exc2.code} (GET range)"
        return False, f"HTTP {exc.code}"
    except Exception as exc:
        return False, str(exc)


def main() -> int:
    versions = load_versions()
    aliases = load_aliases()
    errors: list[str] = []
    for label, template, sha_key in SOURCES:
        if re.fullmatch(r"[0-9a-f]{64}", versions.get(sha_key, "")) is None:
            errors.append(f"{label}: missing or invalid {sha_key}")
        url = resolve(template.format(**versions), aliases)
        ok, detail = available(url)
        print(f"{'OK  ' if ok else 'FAIL'} {label:12} {detail}  {url}")
        if not ok:
            errors.append(f"{label}: {detail} at {url}")
    if errors:
        print("arm64 pinned-source availability FAILED:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("arm64 pinned-source availability OK")
    print(
        "Not verified here: sha256 (BuildStream at fetch), compilation, "
        "or an aarch64 image build."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
