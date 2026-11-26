kind: manual
description: |
  SIGNING-ONLY. Imports Secure Boot and PCR signing keys into the build
  sandbox. If no keys are supplied in files/boot-keys (dev/CI), throwaway keys
  are generated with openssl so the image is still signed and bootable in a VM.
  Release builds write real keys to files/boot-keys from CI secrets before
  building. PCR.key signs the PCR 11 policy embedded in the UKI; PCR.pub is the
  matching public key and is the only PCR material published in the runtime
  image. NEVER add this element to a runtime stack: its artifact holds private
  key material.

build-depends:
- base/sandbox-tools.bst
- freedesktop-sdk.bst:components/openssl.bst
sources:
- kind: local
  path: files/boot-keys
  directory: keys
variables:
  strip-binaries: ''
config:
  install-commands:
  - |
    set -eu
    if [ -f keys/DB.key ] && [ -f keys/DB.crt ]; then
      cp -a keys/. "%{install-root}/"
    else
      echo "No Secure Boot keys supplied; generating throwaway dev keys" >&2
      cd "%{install-root}"
      gen() {
        openssl req -new -x509 -newkey rsa:2048 -nodes -keyout "$1.key" \
          -out "$1.crt" -days 3650 -subj "/CN=Mjolnir Dev $1" >/dev/null 2>&1
      }
      gen DB
      cp DB.key VENDOR.key
      cp DB.crt VENDOR.crt
    fi
    # Separate PCR signing key. Only PCR.pub is ever published; PCR.key stays
    # inside this signing-only artifact.
    if [ ! -f "%{install-root}/PCR.key" ] || [ ! -f "%{install-root}/PCR.pub" ]; then
      cd "%{install-root}"
      openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out PCR.key >/dev/null 2>&1
      openssl rsa -pubout -in PCR.key -out PCR.pub >/dev/null 2>&1
    fi
    for f in DB.key DB.crt VENDOR.key VENDOR.crt PCR.key PCR.pub; do
      test -f "%{install-root}/${f}"
      chmod 0600 "%{install-root}/${f}"
    done
