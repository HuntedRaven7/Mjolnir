kind: script
description: |
  Install the pinned CNI and KubeStellar manifests.

build-depends:
- base/sandbox-tools.bst
- filename: k8s/manifests-src.bst
  config:
    location: /manifests

config:
  commands:
  - |
    set -eu
    root="%{install-root}"
    mkdir -p "${root}/usr/share/mjolnir/manifests"
    cp -a /manifests/cilium /manifests/kubestellar "${root}/usr/share/mjolnir/manifests/"
    install -Dm644 /manifests/NOTICE "${root}/usr/share/mjolnir/manifests/NOTICE"
    if grep -rnE 'image: "?[^[:space:]]*[/:]' "${root}/usr/share/mjolnir/manifests" \
        | grep -v '@sha256:[0-9a-f]\{64\}'; then
      echo "ERROR: unpinned image reference in manifests" >&2
      exit 1
    fi
