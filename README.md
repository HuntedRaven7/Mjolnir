# Mjolnir

An image-based, integrity-oriented **server OS** built from [freedesktop-sdk](https://freedesktop-sdk.freedesktop.org/)
(FSDK) and shipped as a **bootc OCI image**.

Mjolnir is a hardened Kubernetes appliance: it boots a full, upstream **kubeadm**
cluster (no k0s), joins worker nodes with a bootstrap token, drives KubeStellar
workload propagation, and exposes a typed management API over mTLS Varlink —
all with **no shell, no SSH daemon and no language interpreters** in the base
image or in any active layer.

> Status: **alpha**. The x86_64 sealed image builds and passes `bootc container
> lint`, content assertions, and the kind-based multinode propagation test. The
> image ships a **signed, composefs-digest-pinned UKI** (Secure Boot ready; key
> enrollment is a manual hardware step). A full disk-install/QEMU boot test has
> not yet run in CI; see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the
> open issues and [docs/BUILD.md](docs/BUILD.md) for the branch/release model.

## Design decisions

These were fixed at project start:

| Decision | Choice |
| --- | --- |
| Build pipeline | BuildStream 2 from FSDK → bootc OCI image (dakota-style) |
| Shell/SSH/interpreters | Forbidden in base **and** in every enabled layer; helpers are compiled binaries |
| Kubernetes | Full upstream kubeadm — control plane + workers, token join, Cilium CNI |
| KubeStellar | Core propagation + Console, applied as pinned Kubernetes manifests |
| WiFi | Client/station mode only (NetworkManager + wpa-supplicant), WPA2-PSK |
| Root filesystem | Impermanent: `systemd.volatile=yes`, allowlisted state on `MjolnirState` (see [docs/IMPERMANENCE.md](docs/IMPERMANENCE.md)) |
| Node management | Varlink-over-HTTPS with mTLS, plus the Kubernetes API |
| First deliverable | A buildable, bootable image |

## Security model

Mjolnir follows the seven properties from
[Amutable Foundations](https://amutable.com/blog/amutable-foundations-technical-overview):

1. **No Shell + No SSH + No Language Interpreters** — enforced by an explicit
   deny-list at build time and a CI assertion over the exported image.
2. **Signed images only** — cosign keyless signing plus a bootc signature policy.
3. **W^X** — read-only `/usr`, `noexec` on writable data mounts.
4. **Everything measured** — systemd PCR phase bindings / measurements.
5. **No SUID/SGID or file capabilities** — stripped at build time; privilege is
   granted to specific units through `AmbientCapabilities=`.
6. **Integrity is mandatory** — bootc's immutable, composefs-backed root.
7. **Factory reset is built in** — `systemd-factory-reset` with a sealed key.

## Repository layout

```text
elements/       BuildStream element definitions (FSDK junction, OS layers, OCI image)
files/          Static configuration: systemd units, tmpfiles, manifests, credentials
patches/        Patches applied to FSDK components
scripts/        Build/CI helpers
tests/          Image content and boot assertions
.github/        CI workflows using projectbluefin/actions
docs/           Architecture and operational guides
include/        Shared version/pin files
```

## Build

Local builds run BuildStream inside the pinned FSDK `bst2` container through `just`:

```sh
just build          # build and export the bootc OCI image
just lint           # bootc container lint
just test           # content assertions (no shell/SSH/interpreters, no SUID, pins)
just disk           # bootc install to-disk into a raw image
just vm             # boot that image in QEMU
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for prerequisites and the
full pipeline.

## Installer and CI

- `installer/` contains a static Go installer and a build script for a minimal
  UEFI live ISO that pulls the image from GHCR and runs `bootc install to-disk`.
- CI rechunks the exported OCI image with
  `projectbluefin/actions/bootc-build/chunka` for update-friendly layers.
- `renovate.json` tracks Go modules, GitHub Actions and pinned source versions.
- `scripts/update_pins.py` and a weekly workflow recompute source hashes/refs;
  see [docs/UPDATES.md](docs/UPDATES.md).
- `testsuite/` adapts the projectbluefin/testsuite harness to our shell-less
  image: a blocking QEMU boot/health/provenance gate on merge queue. See
  [testsuite/README.md](testsuite/README.md).

## References

- [projectbluefin/server](https://github.com/projectbluefin/server) — FSDK/BuildStream
  server OS and the source of the kubeadm approach this project adapts.
- [projectbluefin/actions](https://github.com/projectbluefin/actions) — shared
  build/sign/scan/release actions used in CI where applicable.
- [Amutable Foundations: A Technical Overview](https://amutable.com/blog/amutable-foundations-technical-overview)
- [systemd/varlink-http-bridge](https://github.com/systemd/varlink-http-bridge)

## License

Apache-2.0 (see [LICENSE](LICENSE)).
