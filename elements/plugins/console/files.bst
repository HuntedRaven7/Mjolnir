kind: script
description: |
  Install the Console plugin units, CRD and RBAC into the image.

build-depends:
- base/sandbox-tools.bst
- filename: plugins/console/files-src.bst
  config:
    location: /src

variables:
  strip-binaries: ''

config:
  commands:
  - |
    set -eu
    root="%{install-root}"
    mkdir -p "${root}/usr/lib/systemd/system" \
             "${root}/usr/lib/systemd/system-preset" \
             "${root}/usr/lib/tmpfiles.d" \
             "${root}/usr/share/mjolnir/manifests/crds" \
             "${root}/usr/share/mjolnir/manifests/kured"
    cp /src/systemd/* "${root}/usr/lib/systemd/system/"
    cp /src/preset/* "${root}/usr/lib/systemd/system-preset/"
    cp /src/tmpfiles.d/* "${root}/usr/lib/tmpfiles.d/"
    cp /src/crds/* "${root}/usr/share/mjolnir/manifests/crds/"
    cp /src/rbac/rbac.yaml "${root}/usr/share/mjolnir/manifests/crds/rbac.yaml"
    cp /src/manifests/kured.yaml "${root}/usr/share/mjolnir/manifests/kured/kured.yaml"
