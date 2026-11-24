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

## Boot verification

There is currently no automated boot test. The previous QEMU harness installed
the image through a custom live ISO; it was removed because the composefs digest
embedded in the signed UKI could not be reproduced from the final OCI rootfs at
install time. A replacement should install with `bootc install to-disk` directly
and assert that the UKI digest matches the installed deployment. See
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).
