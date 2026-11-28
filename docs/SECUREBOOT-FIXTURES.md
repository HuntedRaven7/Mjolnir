# Secure Boot unlock fixtures

Mjolnir publishes three public fixtures for the OVMF + `swtpm` unlock harness
in [Gram](https://github.com/HuntedRaven7/Gram) (issue #19). They prove that a
signed UKI update still unseals `MjolnirState`, while a UKI with an unknown PCR
signing key fails the PCR 11 policy.

## Stable URLs

Set `SECUREBOOT_FIXTURE_BASE_URL` in Gram to:

```
https://github.com/HuntedRaven7/Mjolnir/releases/download/secureboot-fixtures-v1
```

The harness appends one of these file names to that base:

| Asset | Contents |
| --- | --- |
| `OVMF_VARS.enrolled.fd` | Secure Boot enabled; `PK` and `KEK` hold the test key; `db` holds both `VENDOR.crt` and `DEBUG.crt`. |
| `uki-signed.efi` | The production UKI: VENDOR Secure Boot signature and a PCR 11 signature from `PCR.key`. |
| `uki-unknown.efi` | Same kernel, initramfs and pinned composefs digest, but DEBUG Secure Boot signature and a PCR 11 signature from a separate `UNKNOWN_PCR.key`. |

`SHA256SUMS` in the release lists the checksums of all three assets. The
release tag is an asset namespace, not an image release: assets are refreshed
from each successful `testing` build, so the URLs never change. Copy
`OVMF_VARS.enrolled.fd` fresh into each boot case's variable store; never reuse
a variable store that a VM has already written to.

No private key is published. `PCR.key` and `UNKNOWN_PCR.key` stay inside the
signing-only `uki/boot-keys.bst` artifact, and neither is copied into the
runtime image or these assets.

## Regeneration

Fixtures are generated on a successful `build` workflow run on `testing`, or by
manual dispatch of that workflow, and uploaded by the `publish-fixtures` job.
To regenerate locally after a completed image build:

```sh
sudo apt-get install python3-cryptography ovmf binutils unzip
just build
just fixtures
```

`just fixtures` checks out the signing-only BST artifacts into `.build-out/`,
then runs `scripts/gen-secureboot-fixtures.sh`. That script verifies the
`virt-firmware` wheel against the version and sha256 pinned in
`include/versions.yml`, enrolls the throwaway keys into the runner's blank OVMF
varstore with `virt-fw-vars`, and copies the two staged UKIs. It asserts the
enrolled variables, the two distinct PCR public keys, and that both UKIs pin
the same cmdline before writing `SHA256SUMS`.

`scripts/publish-secureboot-fixtures.sh` creates the stable release if needed
and replaces the assets in place with `gh release upload --clobber`. It needs
`GH_TOKEN` with `contents: write`.

## What is not proven here

These fixtures only supply firmware- and PCR-signed binaries. The serial needles
for the unlock and failure cases, the `swtpm` boot cases, and the installed-disk
path belong to Gram issue #19 and the Mjolnir boot-case work. `just test` and
`just lint` still gate every change to the signing elements.
