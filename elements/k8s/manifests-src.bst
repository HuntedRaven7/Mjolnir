kind: manual
description: |
  Cilium and KubeStellar manifests with all image references pinned by digest.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''

sources:
- kind: local
  path: files/manifests

config:
  install-commands:
  - cp -a . "%{install-root}/"
