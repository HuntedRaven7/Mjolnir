# Building Mjolnir

## Prerequisites

- Podman 5+ with rootless storage available; `just`; at least 60 GB free disk.
  The recipes use rootless Podman by default; set `PODMAN="sudo podman"` if your
  environment requires root.
- Network access to `gitlab.com`, `github.com`, `dl.k8s.io`, the FSDK BuildStream
  caches and the pinned FSDK `bst2` container image.
- QEMU with KVM for the boot test (optional; requires a real root user namespace).

BuildStream itself is not installed on the host. Every `bst` invocation runs
inside the pinned `bst2` container via `just bst`.

The FSDK artifact cache at `cache.freedesktop-sdk.io` occasionally returns a
broken large blob; pull the affected element from the Bluefin mirror as shown
in Troubleshooting below and resume the build.

## Commands

```sh
just validate     # resolve the element graph (fast, no compile)
just bst build oci/mjolnir.bst   # build the BuildStream target
just export       # checkout the OCI layout and load it into podman
just lint         # bootc container lint
just test         # static config checks + image content assertions
just disk         # bootc install to-disk into build/bootable.raw
just vm           # boot that disk in QEMU with a serial console
just boot-test    # full install + OVMF boot proof (root, KVM, OVMF required)
```

`just build` runs the build and export steps together.

## CI verification scope

Two static gates run on every PR; neither builds an image locally.

- **Cilium kernel options** — `tests/test_kernel_config.py` reads the kernel
  config script from the FSDK commit pinned in `include/versions.yml`. It checks
  the BPF options Cilium needs and reports VXLAN as an accepted gap
  (`--known-gap VXLAN` in `build.yml`): Cilium requests `tunnel-protocol: vxlan`,
  but FSDK does not enable `CONFIG_VXLAN`. It does not check the built kernel,
  loaded modules, or Cilium readiness; the boot test must cover those.
- **aarch64** — the `validate-arm64` job checks the committed arm64 varlink
  pin, confirms every arm64 source URL in `binaries-src.bst` still serves an
  artifact, and resolves the aarch64 element graph. A missing source or changed
  committed pin fails the job. It does **not** verify downloaded sha256 values
  (BuildStream does that at fetch time), compile or link anything, build an
  aarch64 OCI image, or boot it: the pinned `bst2` image cannot cross-compile.

## What the build does

1. Junctions FSDK 26.08.4 at a pinned git ref.
2. Composes a payload from `runtime-minimal` (no bash/coreutils), systemd,
   NetworkManager + wpa-supplicant, firmware, kernel/initramfs, and the
   compiled Mjolnir components.
3. Sanitizes the composition: denies shells, SSH and interpreters; clears
   SUID/SGID bits and file capabilities.
4. Emits an OCI layout with `containers.bootc=1` and the `ref.name` annotation
   used as the `bootc upgrade` origin.
5. Squashes the image and injects a date-based `VERSION_ID` (BuildStream has no
   string option type, so the element fixes it to `"0"`).

## Reproducibility notes

- All third-party downloads are pinned by sha256 in `include/versions.yml`.
- `varlink-httpd` has no upstream release tarball; `scripts/build-varlink.sh`
  builds a pinned commit with a pinned Rust toolchain and records the resulting
  sha256. The binary is committed under `files/varlink/`.
- KubeStellar manifests are copied from projectbluefin/server with attribution
  in `files/manifests/NOTICE`; every image reference is pinned by digest.
- The Cilium manifest was rendered from the pinned Helm chart with
  `kubeProxyReplacement=true`.

## Branches and releases

Mjolnir follows the dakota-style two-branch model (adapted from
[projectbluefin/dakota](https://github.com/projectbluefin/dakota)):

| Branch | Purpose | Image tag |
| --- | --- | --- |
| `testing` | Default branch and integration trunk. All development and automated checks land here. | `:testing` |
| `stable` | Production pointer. Never rebuilt from source; updated by digest promotion only. | `:stable` |

Development happens on `testing`. A successful build there publishes a
keyless-signed `:testing` image and runs the blocking content, plugin, multinode
and quality gates. `main` is kept as a historical pointer and is not built or
promoted.

Stable is cut **on demand by a maintainer**, never on a schedule:

```sh
just release          # preflight only: resolve the tested digest, verify signature, compare to :stable
just release --apply  # promote the tested digest to :stable and create a GitHub Release
```

Promotion is by **digest**, not by rebuilding: the release workflow resolves the
`:testing` image for a specific (default: testing HEAD) commit SHA, verifies its
cosign signature and SPDX attestation, and re-tags that exact digest as `:stable`.
It never merges, force-pushes or rebuilds. Preflight is always the default;
`--apply` is required to mutate `:stable`. See `docs/RELEASING.md` for the full
procedure and recovery options.

## Troubleshooting

- **"fetch needed" for many FSDK elements** is normal on a cold cache; the
  shared FSDK/Bluefin BuildStream caches serve most artifacts.
- **`just disk` fails with "must be run in the root user namespace"** — bootc
  installs require real root (not rootless Podman). Run that step as root, or
  use `PODMAN="sudo podman" just disk`. The static `just test` boot-asset check
  verifies the kernel, initramfs, bootc install config and required binaries
  when a root install is not available.
- **`Failed to download blob <sha>: 4`** from `cache.freedesktop-sdk.io` means
  that cache has a broken large blob. Pull the affected element from the
  Bluefin mirror explicitly, then resume the build:

```sh
just bst artifact pull --deps none \
  --artifact-remote https://cache.projectbluefin.io:11001 \
  freedesktop-sdk.bst:components/<element>.bst
```
- **`bootc container lint` failures** usually mean the bootc mount layout or
  labels are wrong; check `base/os-stack.bst` integration commands.
- **A missing library after `bootc switch`** is usually a stale `ld.so.cache`;
  `ldconfig -r` must remain the last post-install step in `oci/rootfs.bst`.
- **A node that never becomes Ready** usually means Cilium was not applied or
  the kernel lacks the BPF/ VXLAN options; see `docs/ARCHITECTURE.md` and the
  CI verification scope above.
