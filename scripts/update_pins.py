#!/usr/bin/env python3
"""Recompute every pinned source hash/ref from the version keys in versions.yml.

This is the missing half of automated element updates: Renovate (or the
scheduled workflow) changes a version key, then this script rewrites every
dependent sha256 and git ref. Every download is verified, and nothing is
trusted from a mutable ref at build time.

Sources handled:
  - Kubernetes binaries (kubelet/kubeadm/kubectl) from dl.k8s.io
  - cri-tools, containerd, runc, CNI plugins from GitHub release assets
  - FSDK junction ref (git describe of the pinned release branch)
  - bootc git ref
  - BuildStream plugin refs (git and PyPI sdist)

Usage:
  python3 scripts/update_pins.py [--check]   # --check exits 1 if anything would change
"""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSIONS = ROOT / "include/versions.yml"
FSDK_ELEMENT = ROOT / "elements/freedesktop-sdk.bst"
BOOTC_ELEMENT = ROOT / "elements/mgmt/bootc.bst"
PLUGIN_ELEMENT = ROOT / "elements/plugins/buildstream-plugins.bst"
COMMUNITY_PLUGIN_ELEMENT = ROOT / "elements/plugins/buildstream-plugins-community.bst"

TIMEOUT = 120


def sh(cmd: list[str]) -> str:
    return subprocess.run(
        cmd, check=True, capture_output=True, text=True, timeout=TIMEOUT
    ).stdout.strip()


def get_versions() -> dict[str, str]:
    """Parse the flat `variables:` map in include/versions.yml."""
    result: dict[str, str] = {}
    for line in VERSIONS.read_text().splitlines():
        m = re.match(r'^  ([A-Za-z0-9_-]+):\s*"([^"]*)"', line)
        if m:
            result[m.group(1)] = m.group(2)
    return result


def set_key(path: Path, key: str, value: str, *, text: str | None = None) -> str:
    """Replace a `key: "..."` line in a file and return the updated text."""
    content = text if text is not None else path.read_text()
    pattern = re.compile(rf'^(\s*{re.escape(key)}:\s*)"[^"]*"', re.MULTILINE)
    if not pattern.search(content):
        raise RuntimeError(f"{path}: key {key} not found")
    return pattern.sub(lambda m: f'{m.group(1)}"{value}"', content, count=1)


def download_sha256(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "mjolnir-update-pins/1.0"})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        digest = hashlib.sha256()
        while chunk := resp.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def git_describe(repo: str, tag_pattern: str, current: str = "", allow_major: bool = False) -> str:
    """Return `<tag>-0-g<sha>` for the newest matching tag, like BuildStream.

    When current is given and allow_major is false, only patch/minor bumps are
    considered, matching the "patch/minor auto-merge only" policy.
    """
    refs = sh(["git", "ls-remote", "--tags", repo])
    # Annotated tags have a tag-object SHA on refs/tags/<tag> and the commit
    # SHA on refs/tags/<tag>^{}. BuildStream refs always use the commit.
    peeled: dict[str, str] = {}
    plain: list[tuple[str, str]] = []
    for line in refs.splitlines():
        sha, ref = line.split("\t", 1)
        if ref.endswith("^{}"):
            peeled[ref[:-3].removeprefix("refs/tags/")] = sha
        elif ref.startswith("refs/tags/"):
            plain.append((ref.removeprefix("refs/tags/"), sha))
    tags = []
    for tag, sha in plain:
        if re.fullmatch(tag_pattern, tag):
            tags.append((tag, peeled.get(tag, sha)))
    if not tags:
        raise RuntimeError(f"no tags matching {tag_pattern} in {repo}")
    # Prefer the newest release tag by version, not by tag-list order.
    def key(item: tuple[str, str]) -> tuple[int, ...]:
        nums = re.findall(r"\d+", item[0])
        return tuple(int(n) for n in nums[:3])

    if current and not allow_major:
        cur_nums = re.findall(r"\d+", current)
        cur_major = int(cur_nums[0]) if cur_nums else -1
        tags = [t for t in tags if int(re.findall(r"\d+", t[0])[0]) == cur_major]
        if not tags:
            raise RuntimeError(f"no same-major tags matching {tag_pattern} in {repo}")
    tag, sha = max(tags, key=key)
    return f"{tag}-0-g{sha}"


def version_tuple(v: str) -> tuple[int, ...]:
    return tuple(int(n) for n in re.findall(r"\d+", v)[:3])


def pypi_sdist(package: str, current: str, allow_major: bool) -> tuple[str, str]:
    """Return (version, sdist URL) for the newest same-major PyPI release."""
    req = urllib.request.Request(
        f"https://pypi.org/pypi/{package}/json",
        headers={"User-Agent": "mjolnir-update-pins/1.0"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        data = json.load(resp)
    releases = data.get("releases", {})
    versions = [v for v in releases if re.fullmatch(r"\d+(?:\.\d+)+", v)]
    if current and not allow_major:
        major = version_tuple(current)[0]
        versions = [v for v in versions if version_tuple(v)[0] == major]
    if not versions:
        raise RuntimeError(f"no suitable versions for {package}")
    latest = max(versions, key=version_tuple)
    sdists = [f for f in releases[latest] if f.get("packagetype") == "sdist"]
    if not sdists:
        raise RuntimeError(f"no sdist for {package} {latest}")
    return latest, sdists[0]["url"]


BINARY_SOURCES = [
    # (version key, sha256 key prefix, URL template)
    ("kubernetes-version", "kubelet", "https://dl.k8s.io/release/v{v}/bin/linux/{arch}/kubelet"),
    ("kubernetes-version", "kubeadm", "https://dl.k8s.io/release/v{v}/bin/linux/{arch}/kubeadm"),
    ("kubernetes-version", "kubectl", "https://dl.k8s.io/release/v{v}/bin/linux/{arch}/kubectl"),
    ("crictl-version", "crictl", "https://github.com/kubernetes-sigs/cri-tools/releases/download/v{v}/crictl-v{v}-linux-{arch}.tar.gz"),
    ("containerd-version", "containerd", "https://github.com/containerd/containerd/releases/download/v{v}/containerd-{v}-linux-{arch}.tar.gz"),
    ("runc-version", "runc", "https://github.com/opencontainers/runc/releases/download/v{v}/runc.{bst_arch}"),
    ("cni-plugins-version", "cni-plugins", "https://github.com/containernetworking/plugins/releases/download/v{v}/cni-plugins-linux-{arch}-v{v}.tgz"),
]

ARCHES = {"amd64": "amd64", "arm64": "arm64"}


def recompute_binary(ver_key: str, prefix: str, template: str, versions: dict[str, str]) -> dict[str, str]:
    v = versions[ver_key]
    updates: dict[str, str] = {}
    for arch, bst_arch in ARCHES.items():
        url = template.format(v=v, arch=arch, bst_arch=bst_arch)
        updates[f"{prefix}-{arch}-sha256"] = download_sha256(url)
    return updates


def write_results(versions: dict[str, str], new_versions: dict[str, str],
                  changes: list[str], args: argparse.Namespace) -> int:
    """Write recomputed versions.yml and report changes (or fail with --check)."""
    if not args.check:
        text = VERSIONS.read_text()
        for key, value in new_versions.items():
            if key in versions and versions[key] != value:
                text = set_key(VERSIONS, key, value, text=text)
        if text != VERSIONS.read_text():
            VERSIONS.write_text(text)
    if not changes:
        print("All pins are current")
        return 0
    print("Updated pins:")
    for line in changes:
        print(f"  - {line}")
    if args.check:
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if pins would change")
    ap.add_argument("--allow-major", action="store_true", help="allow major-version bumps for git refs")
    ap.add_argument("--binary-only", action="store_true",
                    help="only recompute binary sha256 pins; do not update git refs "
                         "(used by the PR auto-pins workflow, where ref bumps are handled by the weekly workflow)")
    args = ap.parse_args()

    versions = get_versions()
    new_versions = dict(versions)
    changes: list[str] = []

    # Binary sha256 pins (parallel downloads).
    jobs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        for ver_key, prefix, template in BINARY_SOURCES:
            jobs.append((prefix, pool.submit(recompute_binary, ver_key, prefix, template, versions)))
        for prefix, future in jobs:
            for key, value in future.result().items():
                if new_versions.get(key) != value:
                    changes.append(f"{key}: {new_versions.get(key)} -> {value}")
                    new_versions[key] = value

    if args.binary_only:
        return write_results(versions, new_versions, changes, args)

    # FSDK git ref from the pinned branch.
    m = re.match(r"^freedesktop-sdk-([0-9.]+)-0-g", versions["fsdk-ref"])
    if not m:
        print("warning: cannot parse fsdk-ref version", file=sys.stderr)
        fsdk_version = ""
    else:
        fsdk_version = m.group(1)
    try:
        fsdk_ref = git_describe(
            "https://gitlab.com/freedesktop-sdk/freedesktop-sdk.git",
            rf"freedesktop-sdk-{re.escape(fsdk_version)}",
            current=versions["fsdk-ref"],
            allow_major=args.allow_major,
        )
        if new_versions.get("fsdk-ref") != fsdk_ref:
            changes.append(f"fsdk-ref: {versions['fsdk-ref']} -> {fsdk_ref}")
            new_versions["fsdk-ref"] = fsdk_ref
    except Exception as exc:
        print(f"warning: FSDK ref lookup failed: {exc}", file=sys.stderr)

    # bootc and buildstream-plugins git refs from their .bst files.
    try:
        old_bootc = re.search(r"^  ref: (\S+)$", BOOTC_ELEMENT.read_text(), re.MULTILINE)
        bootc_ref = git_describe(
            "https://github.com/bootc-dev/bootc.git", r"v\d+\.\d+\.\d+",
            current=old_bootc.group(1) if old_bootc else "",
            allow_major=args.allow_major,
        )
        if bootc_ref:
            text = BOOTC_ELEMENT.read_text()
            old = re.search(r"^  ref: (\S+)$", text, re.MULTILINE)
            if old and old.group(1) != bootc_ref:
                changes.append(f"bootc ref: {old.group(1)} -> {bootc_ref}")
                if not args.check:
                    BOOTC_ELEMENT.write_text(
                        re.sub(r"^  ref: \S+$", f"  ref: {bootc_ref}", text, count=1, flags=re.MULTILINE)
                    )
    except Exception as exc:
        print(f"warning: bootc ref lookup failed: {exc}", file=sys.stderr)

    # Plugin refs: derive from the version in the .bst URL/ref string.
    for element, repo, pattern in [
        (PLUGIN_ELEMENT, "https://github.com/apache/buildstream-plugins.git", r"\d+\.\d+\.\d+"),
    ]:
        try:
            text = element.read_text()
            version_match = re.search(r"ref:\s*(\d+\.\d+\.\d+)-0-g", text)
            if not version_match:
                continue
            current = version_match.group(0).split("-")[0]
            ref = git_describe(repo, pattern, current=current, allow_major=args.allow_major)
            old = re.search(r"^  ref: (\S+)$", text, re.MULTILINE)
            if old and old.group(1) != ref:
                changes.append(f"{element.name}: {old.group(1)} -> {ref}")
                if not args.check:
                    element.write_text(
                        re.sub(r"^  ref: \S+$", f"  ref: {ref}", text, count=1, flags=re.MULTILINE)
                    )
        except Exception as exc:
            print(f"warning: {element.name} ref lookup failed: {exc}", file=sys.stderr)

    # PyPI sdist plugin: the version is in the tarball URL and the ref is its
    # sha256. Keep both in sync so Renovate never has to touch a raw hash.
    try:
        text = COMMUNITY_PLUGIN_ELEMENT.read_text()
        current = re.search(
            r"buildstream_plugins_community-([0-9.]+)\.tar\.gz", text
        ).group(1)
        version, url = pypi_sdist(
            "buildstream-plugins-community", current, args.allow_major
        )
        if version != current:
            sha = download_sha256(url)
            filename = f"buildstream_plugins_community-{version}.tar.gz"
            updated = re.sub(
                r"buildstream_plugins_community-[0-9.]+\.tar\.gz", filename, text
            )
            updated = re.sub(
                r"^  ref: \S+$", f"  ref: {sha}", updated, count=1, flags=re.MULTILINE
            )
            changes.append(
                f"{COMMUNITY_PLUGIN_ELEMENT.name}: {current} -> {version} ({sha})"
            )
            if not args.check:
                COMMUNITY_PLUGIN_ELEMENT.write_text(updated)
    except Exception as exc:
        print(f"warning: {COMMUNITY_PLUGIN_ELEMENT.name} lookup failed: {exc}", file=sys.stderr)

    return write_results(versions, new_versions, changes, args)


if __name__ == "__main__":
    raise SystemExit(main())
