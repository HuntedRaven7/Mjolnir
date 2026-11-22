# Mjolnir E2E testsuite

A small, self-contained E2E harness adapted from the patterns in
[projectbluefin/testsuite](https://github.com/projectbluefin/testsuite)
(Apache-2.0). Unlike the upstream suite, it does **not** boot a GNOME session
and does **not** inject a shell/SSH user into the image: Mjolnir has no shell or
sshd, so the tests drive the VM via the serial console and the mTLS Varlink API
from the runner host.

## What it verifies

| Check | How |
|---|---|
| Image boots | QEMU boots the `bootc install to-disk` image; `/run/mjolnir/ready` appears on the serial console |
| bootc status | `bootc status --json` reports the pinned image reference |
| System health | No failed systemd units and no critical journal entries, read via Varlink `io.mjolnir.Fleet.Status` and the serial console |
| Immutability | `/usr` is read-only via `findmnt` on the serial console; image digest/labels verified host-side |
| SELinux | Enforcing mode and no AVC denials (when the image ships a policy) |
| Provenance | Cosign keyless verify on the published image with our OIDC identity |
| Fleet state | `MjolnirNode` CRD exists and the exporter reports the expected fields |

## Layout

- `e2e.sh` — host-side QEMU boot + checks (invoked by CI and locally).
- `features/*.feature` — behave-style scenario descriptions (documentation of
  intent; the shell script is the executable source of truth for now).
- `multinode/` — kind-based KubeStellar WDS↔ITS propagation test (no QEMU),
  run by `.github/workflows/multinode.yml` on `testing`.

`.github/workflows/e2e.yml` triggers on PRs against `testing`, after the
`build` workflow has pushed `:testing`, or on manual dispatch. On PRs it builds
the image locally (PR builds do not publish), so it can act as a required
status check for image changes; on pushes it tests the published image.

## Running locally

Requires root (bootc install needs a real root user namespace), QEMU/KVM and
`cosign`:

```sh
IMAGE=ghcr.io/huntedraven7/mjolnir:testing sudo ./testsuite/e2e.sh
```

CI uses the published `:testing` image. See `docs/RELEASING.md` for how a
tested `:testing` digest is promoted to `:stable`.
