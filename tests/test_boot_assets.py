#!/usr/bin/env python3
"""Verify that the image contains everything bootc needs to install and boot.

This is a static check; the full install+boot test (`just disk`, `just vm`)
requires a real root user namespace and is documented in docs/BUILD.md.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

PODMAN = os.environ.get("PODMAN", "podman").split()
image = sys.argv[1] if len(sys.argv) > 1 else "mjolnir:latest"

required = [
    "/usr/lib/bootc/install/00-defaults.toml",
    "/usr/lib/systemd/systemd",
    "/usr/bin/bootc",
    "/usr/bin/kubeadm",
    "/usr/bin/kubelet",
    "/usr/bin/containerd",
    "/usr/bin/runc",
    "/usr/bin/varlink-httpd",
    "/usr/bin/mjolnir-helper",
    "/usr/libexec/iwd",
    "/etc/mjolnir/kubeadm-init.yaml",
    "/usr/share/mjolnir/manifests/cilium/00-cilium.yaml",
    "/usr/lib/systemd/system/mjolnir-init.service",
    "/usr/lib/systemd/system/varlink-httpd.socket",
]

# Use podman mount from a created container to inspect the full tree quickly.
name = "mjolnir-boot-assets"
subprocess.run(PODMAN + ["rm", "-f", name], capture_output=True)
subprocess.run(PODMAN + ["create", "--name", name, image], check=True)
try:
    out = subprocess.run(
        PODMAN + ["export", name], check=True, stdout=subprocess.PIPE
    ).stdout
except Exception as exc:
    print(f"failed to export image: {exc}", file=sys.stderr)
    raise SystemExit(1)
finally:
    subprocess.run(PODMAN + ["rm", "-f", name], capture_output=True)

# tarfile can read from a bytes buffer; import here to keep the top small.
import io  # noqa: E402
import tarfile  # noqa: E402

with tarfile.open(fileobj=io.BytesIO(out), mode="r:") as tf:
    names = set(m.name.lstrip("./") for m in tf.getmembers())

errors = [f"missing {p}" for p in required if p.lstrip("/") not in names]

kernels = [n for n in names if n.startswith("usr/lib/modules/") and n.endswith("/vmlinuz")]
if not kernels:
    errors.append("missing kernel (usr/lib/modules/<ver>/vmlinuz)")
else:
    for k in kernels:
        initramfs = k.rsplit("/", 1)[0] + "/initramfs.img"
        if initramfs not in names:
            errors.append(f"missing initramfs for {k}")

inspect = subprocess.run(
    PODMAN + ["inspect", image], check=True, capture_output=True, text=True
).stdout
meta = json.loads(inspect)[0]
cfg = meta.get("Config", {})
labels = cfg.get("Labels", {})
if labels.get("containers.bootc") != "1":
    errors.append("missing containers.bootc=1 label")

if errors:
    print("Boot asset check FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    raise SystemExit(1)
print("Boot asset check passed")
