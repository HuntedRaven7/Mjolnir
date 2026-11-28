# Secure Boot keys

This directory is where Secure Boot and PCR signing keys are supplied to the build.

- `DB.key`/`DB.crt` sign the UKI and systemd-boot; `VENDOR.key`/`VENDOR.crt`
  sign the loader image.
- `PCR.key` signs the TPM2 PCR 11 policy embedded in each image UKI. `PCR.pub`
  is its RSA public key and is the only PCR key material published in the
  runtime image (`/usr/lib/systemd/tpm2-pcr-public-key.pem`). Never publish
  `PCR.key`: anyone holding it can produce a PCR signature that unseals
  MjolnirState.
- `UNKNOWN_PCR.key` signs only the published `uki-unknown.efi` fixture. Its
  signature fails PCR unseal by design. Never publish `UNKNOWN_PCR.key`.

The published fixtures and their stable URLs are documented in
[docs/SECUREBOOT-FIXTURES.md](../../docs/SECUREBOOT-FIXTURES.md).

- **Development / CI (non-release):** run `scripts/gen-dev-keys.sh` to generate
  throwaway keys here. The signing elements will also generate keys on demand
  if none are present (including `PCR.key`/`PCR.pub`).
- **Release:** CI writes the real DB/PK/KEK keys here from secrets before
  building. Never commit private keys — `*.key`, `*.crt` (except this README)
  are gitignored.

The `uki/boot-keys.bst` and `uki/mjolnir-uki.bst` elements are signing-only and
must never be added to a runtime stack: their BST artifacts contain key material.
