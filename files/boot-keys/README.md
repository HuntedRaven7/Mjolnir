# Secure Boot keys

This directory is where Secure Boot signing keys are supplied to the build.

- **Development / CI (non-release):** run `scripts/gen-dev-keys.sh` to generate
  throwaway keys here. The signing elements will also generate keys on demand
  if none are present.
- **Release:** CI writes the real DB/PK/KEK keys here from secrets before
  building. Never commit private keys — `*.key`, `*.crt` (except this README)
  are gitignored.

The `uki/boot-keys.bst` and `uki/mjolnir-uki.bst` elements are signing-only and
must never be added to a runtime stack: their BST artifacts contain key material.
