# Mjolnir testsuite

Adapters for running Mjolnir's cluster-level checks without a shell or SSH user
inside the image. The checks run from the runner host against kind-based
clusters and the mTLS Varlink API.

## Layout

- `features/*.feature` — behave-style descriptions of boot, status and
  impermanence behaviour (documentation of intent, not executable tests).
- `multinode/` — kind-based KubeStellar WDS↔ITS propagation test, run by
  `.github/workflows/multinode.yml` on `testing`.
- `plugin-smoke.sh` — Console plugin smoke check, run by
  `.github/workflows/plugin-test.yml`.
- `boot/test-boot.sh` — install + OVMF boot proof, run by the `image` job in
  `.github/workflows/build.yml` on pull requests and pushes.

## Boot verification

The boot test installs the built image with `bootc install to-disk` directly
(no custom installer), extracts the signed `.cmdline` from the installed UKI,
recomputes the composefs digest from the image under test, and boots the disk
under OVMF. It asserts the signed cmdline, `bootc status`, absence of failed
units, image provenance, and that the separately signed debug UKI pins the same
root as a distinct systemd-boot entry. See
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

Run it locally with `sudo just boot-test` after `just build`; it needs root,
KVM, QEMU, OVMF and `objcopy`.
