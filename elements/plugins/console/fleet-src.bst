kind: manual
description: |
  Source for the compiled Mjolnir fleet exporter / Varlink action service.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''

sources:
- kind: local
  path: plugins/console/src

config:
  install-commands:
  - cp -a . "%{install-root}/"
