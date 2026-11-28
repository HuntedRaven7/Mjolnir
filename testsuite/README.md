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
- `boot/test-boot.sh` — install + OVMF boot proof and the two Secure Boot
  swtpm cases, run by the `image` job in `.github/workflows/build.yml` on pull
  requests and pushes.

## Boot verification

The boot test installs the built image with `bootc install to-disk` directly
(no custom installer), extracts the signed `.cmdline` from the installed UKI,
recomputes the composefs digest from the image under test, and boots the disk
under OVMF. It asserts the signed cmdline, `bootc status`, absence of failed
units, image provenance, and that the separately signed debug UKI pins the same
root as a distinct systemd-boot entry. See
[docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

Run it locally with `sudo just boot-test` after `just build`; it needs root,
KVM, QEMU, OVMF and `objcopy`. The Secure Boot cases additionally need `swtpm`.

## Secure Boot unlock cases

`boot/test-boot.sh` appends two cases after the OVMF check above. Each case
copies the installed disk and gets its own copy of the enrolled OVMF variable
store and its own swtpm state directory, so a failed unseal in one case cannot
leak into the other. Both cases first boot `uki-signed.efi` to establish the
TPM2 enrollment, then reboot with the case's update:

| Case | Update installed in the ESP | Required serial evidence |
| --- | --- | --- |
| signed | `uki-signed.efi` | `MjolnirState: unlocked`, no `Failed to unseal` |
| unknown | `uki-unknown.efi` | `PCR policy` and `Failed to unseal`, no unlock |

The needles come from image units, not from journal text the guest happens to
emit. `mjolnir-state-unlocked.service` runs after `var-lib-mjolnir.mount` and is
enabled by the preset. A drop-in for `systemd-cryptsetup@mjolnir-state.service`
wires `OnFailure=` to `mjolnir-state-unseal-failed.service`; that unit and the
drop-in are installed in both the rootfs and the initramfs because the PCR miss
fails cryptsetup before switch-root. Both units use
`StandardOutput=journal+console` so the strings reach the serial log
regardless of journald forwarding settings.

### Fixtures

The three fixtures are release assets of this repository, published by the
Secure Boot fixture work. The harness reads them from `FIXTURE_DIR`, which
defaults to `$RUNNER_TEMP/mjolnir-secureboot-fixtures`:

| File | Meaning |
| --- | --- |
| `OVMF_VARS.enrolled.fd` | Variable store with PK/KEK/db holding the test key, Secure Boot enabled; copied fresh per case |
| `uki-signed.efi` | Signed update that satisfies the existing PCR 11 policy |
| `uki-unknown.efi` | Same boot, signed with an unknown PCR signing key |

Env overrides: `FIXTURE_DIR`, `SECUREBOOT_FIXTURE_DIR`, `OVMF_VARS_ENROLLED`,
`UKI_SIGNED`, `UKI_UNKNOWN`, `SIGNED_LOG`, `UNKNOWN_LOG`, `SWTPM`, `BOOT_WAIT`,
`GRACE_SECONDS`, and the three needle overrides `UNLOCK_NEEDLE`, `PCR_NEEDLE`,
`UNSEAL_FAIL_NEEDLE`. CI sets `FIXTURE_DIR` from the
`SECUREBOOT_FIXTURE_BASE_URL` repository variable. With no variable configured
the two cases write SKIP logs and the run stays green; the assertions in the
script and the static checks in `tests/test_units.py` still run on every PR.
Both serial logs are uploaded as the `mjolnir-secureboot-serial-logs` artifact.
