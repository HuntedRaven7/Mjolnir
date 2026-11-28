#!/usr/bin/env python3
"""Static checks for the published Secure Boot unlock fixtures.

Only checks the contract downstream consumers rely on: stable URL, asset
names, sha256 pinning, CI gating, and absence of private keys in the repo.
The fixtures themselves are generated and verified in CI.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE_URL = ("https://github.com/HuntedRaven7/Mjolnir/releases/download/"
            "secureboot-fixtures-v1")
ASSETS = ("OVMF_VARS.enrolled.fd", "uki-signed.efi", "uki-unknown.efi")


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def main() -> int:
    errors: list[str] = []

    versions = read("include/versions.yml")
    if not re.search(r'virt-firmware-version:\s*"[0-9.]+"', versions):
        errors.append("virt-firmware version is not pinned in include/versions.yml")
    if not re.search(r'virt-firmware-wheel-sha256:\s*"[0-9a-f]{64}"', versions):
        errors.append("virt-firmware wheel sha256 is not pinned in include/versions.yml")

    gen = read("scripts/gen-secureboot-fixtures.sh")
    if "sha256sum -c" not in gen:
        errors.append("fixture generator does not verify the tool sha256")
    if 'compgen -G "$OUT/*.key"' not in gen:
        errors.append("fixture generator does not reject private keys in its output")
    if not all(f in gen for f in ("VENDOR.crt", "DEBUG.crt", "UNKNOWN_PCR.pub")):
        errors.append("fixture generator is missing a required public key or cert")

    pub = read("scripts/publish-secureboot-fixtures.sh")
    if 'TAG="secureboot-fixtures-v1"' not in pub or "releases/download/${TAG}" not in pub:
        errors.append("publish script does not use the stable release URL base")
    if "--clobber" not in pub:
        errors.append("publish script does not replace assets in place")
    if not all(f in pub for f in ASSETS):
        errors.append("publish script does not upload all three fixtures")

    workflow = read(".github/workflows/build.yml")
    if "publish-fixtures:" not in workflow or "needs: image" not in workflow:
        errors.append("build.yml has no publish-fixtures job after the image build")
    publish_block = workflow.split("publish-fixtures:", 1)[1].split("\n  validate-arm64:", 1)[0]
    if "if: github.event_name != 'pull_request'" not in publish_block:
        errors.append("fixtures would be published from a pull request run")
    if "contents: write" not in publish_block:
        errors.append("publish job cannot write the release")

    docs = read("docs/SECUREBOOT-FIXTURES.md")
    if BASE_URL not in docs or not all(f in docs for f in ASSETS):
        errors.append("fixture docs do not document the stable URLs")

    keys = ROOT / "files" / "boot-keys"
    if any(keys.glob("*.key")):
        errors.append("private keys are committed under files/boot-keys")

    if errors:
        for error in errors:
            print(f"  - {error}")
        raise SystemExit(1)
    print("Secure Boot fixture contract OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
