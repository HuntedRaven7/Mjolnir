kind: manual
description: |
  Console plugin assets: systemd units, tmpfiles, preset, CRD and RBAC.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''

sources:
- kind: local
  path: plugins/console/files/systemd
  directory: systemd
- kind: local
  path: plugins/console/files/tmpfiles.d
  directory: tmpfiles.d
- kind: local
  path: plugins/console/files/preset
  directory: preset
- kind: local
  path: plugins/console/crds
  directory: crds
- kind: local
  path: plugins/console/rbac.yaml
  directory: rbac

config:
  install-commands:
  - cp -a systemd "%{install-root}/systemd"
  - cp -a tmpfiles.d "%{install-root}/tmpfiles.d"
  - cp -a preset "%{install-root}/preset"
  - cp -a crds "%{install-root}/crds"
  - mkdir -p "%{install-root}/rbac"
  - cp -a rbac/. "%{install-root}/rbac/"
