#!/usr/bin/env python3
"""Build a systemd credential directory for provisioning a Mjolnir node.

The output directory is meant to be handed to the provisioning system (mounted
at /run/credentials/@system/, or used with systemd's credential tooling). No
credential value is ever written to stdout or to the repository.
"""
from __future__ import annotations

import argparse
import os
import re
import stat
import sys
from pathlib import Path

PSK = re.compile(r"^[0-9a-fA-F]{64}$")
CA_HASH = re.compile(r"^sha256:[0-9a-fA-F]{32,}$")
ENDPOINT = re.compile(r"^[^:\s]+:\d{1,5}$")


def write_secret(directory: Path, name: str, value: str) -> None:
    if not value:
        return
    path = directory / name
    path.write_text(value.rstrip("\n") + "\n", encoding="utf-8")
    path.chmod(stat.S_IRUSR | stat.S_IWUSR)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", required=True, type=Path, help="credential directory to create")
    ap.add_argument("--role", required=True, choices=("control-plane", "worker"))
    ap.add_argument("--join-token")
    ap.add_argument("--ca-cert-hash")
    ap.add_argument("--endpoint")
    ap.add_argument("--wifi-ssid")
    ap.add_argument("--wifi-psk")
    ap.add_argument("--tls-ca", type=Path, help="PEM CA for varlink mTLS client verification")
    ap.add_argument("--registry-user")
    ap.add_argument("--registry-token")
    args = ap.parse_args()

    errors: list[str] = []
    if args.role == "worker":
        for label, value, pattern in (
            ("--join-token", args.join_token, None),
            ("--ca-cert-hash", args.ca_cert_hash, CA_HASH),
            ("--endpoint", args.endpoint, ENDPOINT),
        ):
            if not value:
                errors.append(f"{label} is required for role worker")
            elif pattern and not pattern.fullmatch(value):
                errors.append(f"{label} has an invalid format")
    if bool(args.wifi_ssid) != bool(args.wifi_psk):
        errors.append("--wifi-ssid and --wifi-psk must be given together")
    if args.wifi_psk and not PSK.fullmatch(args.wifi_psk):
        errors.append("--wifi-psk must be exactly 64 hex characters")
    if args.tls_ca and not args.tls_ca.is_file():
        errors.append(f"--tls-ca file not found: {args.tls_ca}")
    if args.registry_user and not args.registry_token:
        errors.append("--registry-token is required with --registry-user")
    if args.registry_token and not args.registry_user:
        errors.append("--registry-user is required with --registry-token")
    if errors:
        for error in errors:
            print(f"error: {error}", file=sys.stderr)
        return 1

    args.out.mkdir(mode=0o700, parents=True, exist_ok=True)
    for entry in args.out.iterdir():
        if entry.is_file():
            entry.unlink()
    args.out.chmod(0o700)

    write_secret(args.out, "mjolnir.role", args.role)
    write_secret(args.out, "mjolnir.join-token", args.join_token)
    write_secret(args.out, "mjolnir.ca-cert-hash", args.ca_cert_hash)
    write_secret(args.out, "mjolnir.control-plane-endpoint", args.endpoint)
    write_secret(args.out, "mjolnir.wifi-ssid", args.wifi_ssid)
    write_secret(args.out, "mjolnir.wifi-psk", args.wifi_psk)
    write_secret(args.out, "registry-user", args.registry_user)
    write_secret(args.out, "registry-token", args.registry_token)
    if args.tls_ca:
        (args.out / "varlink-httpd.tls.trust").write_bytes(args.tls_ca.read_bytes())
        (args.out / "varlink-httpd.tls.trust").chmod(stat.S_IRUSR)

    names = sorted(p.name for p in args.out.iterdir() if p.is_file())
    print(f"Wrote {len(names)} credentials to {args.out} (mode 0700, files 0600):")
    for name in names:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
