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
    # Impermanent root: /etc and /var are tmpfs each boot. Persistent state
    # is re-attached by native .mount units from /usr (fstab is ephemeral).
    # crypttab is consumed by dracut at build time and rehydrated into the
    # volatile /etc at boot. Only mapping options are stored; no keys.
    install -Dm644 /config/crypttab "${root}/etc/crypttab"
    install -Dm644 /config/crypttab "${root}/usr/share/factory/etc/crypttab"
    # Every signed cmdline source is explicit so a new kargs.d file cannot be
    # silently omitted: volatile root, boot-test status, diagnostics console.
    mkdir -p "${root}/usr/lib/bootc/kargs.d"
    install -m644 \
      /config/bootc/kargs.d/40-console.toml \
      /config/bootc/kargs.d/50-volatile.toml \
      /config/bootc/kargs.d/60-journal-console.toml \
      "${root}/usr/lib/bootc/kargs.d/"
    install -Dm644 /config/repart.d/10-mjolnir-esp.conf \
      "${root}/usr/lib/repart.d/10-mjolnir-esp.conf"
    install -Dm644 /config/repart.d/20-mjolnir-state.conf \
      "${root}/usr/lib/repart.d/20-mjolnir-state.conf"
    install -Dm644 /config/journald/10-persistent.conf \
      "${root}/usr/lib/systemd/journald.conf.d/10-persistent.conf"
    install -Dm644 /config/logind/50-ignore-lid.conf \
      "${root}/usr/lib/systemd/logind.conf.d/50-ignore-lid.conf"
    install -Dm644 /config/tmpfiles.d/mjolnir-volatile.conf \
      "${root}/usr/lib/tmpfiles.d/mjolnir-volatile.conf"
    install -Dm644 /config/systemd/var-lib-mjolnir.mount \
      "${root}/usr/lib/systemd/system/var-lib-mjolnir.mount"
    # The cryptsetup instance drop-in lives in a directory, so the *.service
    # glob below does not copy it. The initramfs stages its own copy.
    install -Dm644 /config/systemd/systemd-cryptsetup@mjolnir-state.service.d/10-mjolnir-failure.conf \
      "${root}/usr/lib/systemd/system/systemd-cryptsetup@mjolnir-state.service.d/10-mjolnir-failure.conf"
    for m in var-lib-mjolnir var-lib-etcd etc-machine-id \
             etc-NetworkManager-system-connections \
             var-lib-containerd var-lib-kubelet var-log-journal var-lib-cni \
             etc-kubernetes; do
      if [ "${m}" != "var-lib-mjolnir" ]; then
        install -Dm644 "/config/systemd/${m}.mount" \
          "${root}/usr/lib/systemd/system/${m}.mount"
      fi
    done
    install -Dm644 /config/containerd-config.toml "${root}/usr/share/mjolnir/containerd/config.toml"
    install -Dm644 /config/crictl.yaml "${root}/etc/crictl.yaml"
    install -Dm644 /config/presets/80-mjolnir.preset \
      "${root}/usr/lib/systemd/system-preset/80-mjolnir.preset"
    mkdir -p "${root}/usr/lib/systemd/system"
    cp /config/systemd/*.service /config/systemd/*.socket /config/systemd/*.timer \
      "${root}/usr/lib/systemd/system/" 2>/dev/null || true
    install -Dm644 /config/sysusers.d/mjolnir.conf "${root}/usr/lib/sysusers.d/mjolnir.conf"
    install -Dm644 /config/tmpfiles.d/mjolnir.conf "${root}/usr/lib/tmpfiles.d/mjolnir.conf"
    install -Dm644 /config/sysctl.d/90-kubernetes.conf "${root}/usr/lib/sysctl.d/90-kubernetes.conf"
    install -Dm644 /config/modules-load.d/kubernetes.conf "${root}/usr/lib/modules-load.d/kubernetes.conf"
    install -Dm644 /config/bootc-install/00-defaults.toml "${root}/usr/lib/bootc/install/00-defaults.toml"
    install -Dm644 /config/ostree/prepare-root.conf "${root}/usr/lib/ostree/prepare-root.conf"
    install -Dm644 /config/NetworkManager/conf.d/10-wifi-backend.conf \
      "${root}/etc/NetworkManager/conf.d/10-wifi-backend.conf"
