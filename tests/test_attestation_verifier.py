#!/usr/bin/env python3
"""Test the attestation verifier's positive-evidence contract."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "verify-attestation.py"

spec = importlib.util.spec_from_file_location("verify_attestation", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ARGS = SimpleNamespace(
    expect_method="tpm2",
    expect_composefs=None,
    expect_uki_pe=None,
    expect_image_digest=None,
    expect_pcr11=None,
    require_event_log=False,
)

FULL = {
    "method": "tpm2",
    "usrVerityRootHash": "a" * 64,
    "uki": {"peHashSha256": "b" * 64},
    "imageDigest": "sha256:" + "c" * 64,
    "pcrValues": {"11": "d" * 96},
    "eventLogHashSha256": "e" * 64,
}


def main() -> int:
    errors: list[str] = []

    empty = mod.verify({"method": "tpm2"}, ARGS)
    if not empty:
        errors.append("evidence-free tpm2 report verified with no reasons")

    for field in ("usrVerityRootHash", "imageDigest", "eventLogHashSha256"):
        report = {k: v for k, v in FULL.items() if k != field}
        if not mod.verify(report, ARGS):
            errors.append(f"missing {field} verified")
    for field, container in (("peHashSha256", "uki"), ("11", "pcrValues")):
        report = dict(FULL)
        report[container] = {}
        if not mod.verify(report, ARGS):
            errors.append(f"missing {container}.{field} verified")

    if mod.verify(FULL, ARGS):
        errors.append("complete report did not verify")

    mismatch_args = vars(ARGS).copy()
    mismatch_args["expect_pcr11"] = "f" * 96
    mismatch = SimpleNamespace(**mismatch_args)
    if not mod.verify(FULL, mismatch):
        errors.append("wrong expected PCR 11 verified")

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        handle.write('{"method":"tpm2"}')
        path = handle.name
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--report", path, "--expect-method", "tpm2"],
        capture_output=True, text=True,
    )
    Path(path).unlink()
    if proc.returncode != 1 or '"verified": false' not in proc.stdout:
        errors.append(f"CLI did not reject evidence-free report: rc={proc.returncode} {proc.stdout}")

    if errors:
        print("Attestation verifier checks FAILED:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    print("Attestation verifier checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
