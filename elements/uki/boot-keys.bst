kind: manual
description: |
  SIGNING-ONLY. Imports Secure Boot keys into the build sandbox. If no keys
  are supplied in files/boot-keys (dev/CI), throwaway keys are generated with
  openssl so the image is still signed and bootable in a VM. Release builds
  write real keys to files/boot-keys from CI secrets before building.
  NEVER add this element to a runtime stack: its artifact holds key material.

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
    for f in DB.key DB.crt VENDOR.key VENDOR.crt; do
      test -f "%{install-root}/${f}"
      chmod 0600 "%{install-root}/${f}"
    done
