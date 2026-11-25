kind: manual
description: |
  Build-time tool that strips interpreters from a generated initramfs. It is
  staged into the initramfs build sandbox only; nothing here ships in the image.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''

sources:
- kind: local
  path: scripts/sanitize-initramfs.sh

config:
  install-commands:
  - install -Dm755 sanitize-initramfs.sh "%{install-root}/sanitize-initramfs.sh"
