#!/usr/bin/env python3
"""Verify a Mjolnir attestation report against pinned expectations.

The node only publishes evidence. This tool is the verifier side: it compares
the report with values from the release (composefs digest, UKI PE hash, image
digest, PCR 11) and can write the resulting `verified` field back to a
MjolnirNode's status when run by a fleet controller.

Example:
  python3 scripts/verify-attestation.py --report report.json \
    --expect-composefs "$COMPOSEFS_DIGEST" \
    --expect-image-digest "$IMAGE_DIGEST" \
    --patch-node mjolnir-1
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from typing import Any

METHODS = ("tpm2", "software", "none")


def compare(label: str, expected: str, actual: Any, reasons: list[str]) -> None:
    got = actual if isinstance(actual, str) else ""
    if expected.lower() != got.lower():
        reasons.append(f"{label}: expected {expected}, got {got or '<missing>'}")


def verify(report: dict[str, Any], args: argparse.Namespace) -> list[str]:
    reasons: list[str] = []
    method = report.get("method", "")
    if method not in METHODS:
        reasons.append(f"method: unknown value {method!r}")
    if args.expect_method != "any" and method != args.expect_method:
        reasons.append(f"method: expected {args.expect_method}, got {method}")
    if args.expect_method == "tpm2" and method != "tpm2":
        reasons.append("method: TPM2 evidence required")

    if args.expect_composefs:
        compare("usrVerityRootHash", args.expect_composefs,
                report.get("usrVerityRootHash"), reasons)
    if args.expect_uki_pe:
        compare("uki.peHashSha256", args.expect_uki_pe,
                (report.get("uki") or {}).get("peHashSha256"), reasons)
    if args.expect_image_digest:
        compare("imageDigest", args.expect_image_digest,
                report.get("imageDigest"), reasons)
    if args.expect_pcr11:
        compare('pcrValues["11"]', args.expect_pcr11,
                (report.get("pcrValues") or {}).get("11"), reasons)
    if args.require_event_log and not report.get("eventLogHashSha256"):
        reasons.append("eventLogHashSha256: missing")
    return reasons


def patch_node(name: str, namespace: str, kubectl: str, verified: bool) -> None:
    patch = {
        "status": {
            "attestation": {
                "verified": verified,
            }
        }
    }
    cmd = [
        kubectl, "-n", namespace, "patch", "mjolnirnode", name,
        "--subresource=status", "--type=merge", "-p", json.dumps(patch),
    ]
    subprocess.run(cmd, check=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--report", help="JSON report file (default: stdin)")
    ap.add_argument("--expect-method", choices=("any",) + METHODS, default="any")
    ap.add_argument("--expect-composefs")
    ap.add_argument("--expect-uki-pe")
    ap.add_argument("--expect-image-digest")
    ap.add_argument("--expect-pcr11")
    ap.add_argument("--require-event-log", action="store_true")
    ap.add_argument("--patch-node", help="MjolnirNode to patch with the verdict")
    ap.add_argument("--namespace", default="default")
    ap.add_argument("--kubectl", default="kubectl")
    args = ap.parse_args()

    if args.patch_node and shutil.which(args.kubectl) is None:
        print(f"error: {args.kubectl} not found", file=sys.stderr)
        return 2

    try:
        if args.report:
            with open(args.report, encoding="utf-8") as handle:
                report = json.load(handle)
        else:
            report = json.load(sys.stdin)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: cannot read report: {exc}", file=sys.stderr)
        return 2

    reasons = verify(report, args)
    verified = not reasons
    result = {
        "verified": verified,
        "method": report.get("method", "none"),
        "reasons": reasons,
    }
    print(json.dumps(result, sort_keys=True))
    if args.patch_node:
        patch_node(args.patch_node, args.namespace, args.kubectl, verified)
        print(f"patched {args.patch_node}: verified={verified}", file=sys.stderr)
    return 0 if verified else 1


if __name__ == "__main__":
    raise SystemExit(main())
