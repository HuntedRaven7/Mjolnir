kind: manual
description: |
  Static Mjolnir configuration files.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''

sources:
- kind: local
  path: files/config

config:
  install-commands:
  - cp -a . "%{install-root}/"
