kind: script
description: |
  Install systemd units, kubeadm/containerd config, presets, sysusers,
  tmpfiles, and bootc install defaults.

build-depends:
- base/sandbox-tools.bst
- filename: config/files-src.bst
  config:
    location: /config

config:
  commands:
  - |
    set -eu
    root="%{install-root}"
    mkdir -p "${root}/etc/mjolnir"
    sed 's/@KUBERNETES_VERSION@/%{kubernetes-version}/g' \
      /config/kubeadm-init.yaml > "${root}/etc/mjolnir/kubeadm-init.yaml"
    install -Dm644 /config/containerd-config.toml "${root}/usr/share/mjolnir/containerd/config.toml"
    install -Dm644 /config/crictl.yaml "${root}/etc/crictl.yaml"
    install -Dm644 /config/presets/80-mjolnir.preset \
      "${root}/usr/lib/systemd/system-preset/80-mjolnir.preset"
    mkdir -p "${root}/usr/lib/systemd/system"
    cp /config/systemd/*.service /config/systemd/*.socket \
      "${root}/usr/lib/systemd/system/" 2>/dev/null || true
    install -Dm644 /config/sysusers.d/mjolnir.conf "${root}/usr/lib/sysusers.d/mjolnir.conf"
    install -Dm644 /config/tmpfiles.d/mjolnir.conf "${root}/usr/lib/tmpfiles.d/mjolnir.conf"
    install -Dm644 /config/sysctl.d/90-kubernetes.conf "${root}/usr/lib/sysctl.d/90-kubernetes.conf"
    install -Dm644 /config/modules-load.d/kubernetes.conf "${root}/usr/lib/modules-load.d/kubernetes.conf"
    install -Dm644 /config/bootc-install/00-defaults.toml "${root}/usr/lib/bootc/install/00-defaults.toml"
    install -Dm644 /config/ostree/prepare-root.conf "${root}/usr/lib/ostree/prepare-root.conf"
    install -Dm644 /config/NetworkManager/conf.d/10-wifi-backend.conf \
      "${root}/etc/NetworkManager/conf.d/10-wifi-backend.conf"
