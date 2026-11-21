# Mjolnir — Agent entry point

Mjolnir is a BuildStream 2 project that composes a bootc OCI server image from
freedesktop-sdk (FSDK). Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before
changing anything that affects the image content.

## Hard rules

1. **No shell, SSH daemon, or language interpreter in the image.** This applies
   to `/usr` and to every layer that can be merged or enabled. Use compiled
   helpers (`src/`, Rust) instead of scripts. `tests/test_image_contents.py`
   fails the build on violations.
2. **No k0s.** Kubernetes is upstream kubeadm only.
3. **Everything downloaded is pinned by sha256** in `include/versions.yml` and
   the corresponding `.bst` source. Mutable refs (tags, branches) in image
   sources are forbidden.
4. **No keys or secrets in the repository.** TLS material, join tokens and WiFi
   PSKs arrive as systemd credentials at provisioning time.
5. **No Containerfiles and no dnf/rpm-ostree.** The base comes from FSDK via
   BuildStream; `projectbluefin/actions` are used only for artifact-level steps
   (signing, scanning, manifest, cleanup).
6. **Systemd units must not invoke a shell.** `ExecStart=` uses a direct binary
   path; no `sh -c`, no `/bin/sh`, no `python3 -c`.
7. **One canonical source per fact.** Version numbers live in
   `include/versions.yml`; do not duplicate them in units or docs.
8. **Device paths are never hardcoded** in boot configuration; use discoverable
   partitions and `/dev/disk/by-*`.
9. **Every change an agent makes goes through a pull request.** Agents must
   work on a topic branch, commit there, open a PR targeting `testing`, and let
   CI run. Agents must never push directly to `testing`, `stable` or `main`.
   The only exception is an explicitly requested `just release --apply`, which
   is a maintainer operation, not an agent code change.

## Build and test commands

| Command | Purpose |
| --- | --- |
| `just validate` | BuildStream project/element graph check |
| `just build` | Build the OCI image and load it into podman |
| `just lint` | `bootc container lint` |
| `just test` | Content assertions and unit tests |
| `just disk` | `bootc install to-disk` into a raw image |
| `just vm` | Boot the raw image in QEMU (headless serial console) |
| `just clean` | Remove local build outputs |

BuildStream itself is not installed on the host; `just` runs it in the pinned
bst2 container image declared in the Justfile.

## Commit conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `ci:`, `chore:`).
- Stage explicitly: never `git add -A` or `git add .`.
- Agents open a PR for **every** change (see hard rule 9); never push straight
  to a long-lived branch.
- `testing` is the integration trunk and PR target; `stable` is promoted by
  digest only (see [docs/RELEASING.md](docs/RELEASING.md)).
- Every PR must keep `just validate`, `just test` and `just lint` green.

## Boundaries

- Do not add debug tooling, shells or package managers to the base image.
- Do not copy configuration between documentation files; link to the canonical one.
- Do not weaken the signature policy to make a build pass.
- Do not hardcode internal hostnames or IPs; use placeholders.
