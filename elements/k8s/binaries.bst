kind: script
description: |
  Install the verified Kubernetes node binaries into the image.

build-depends:
- base/sandbox-tools.bst
- filename: k8s/binaries-src.bst
  config:
    location: /src

variables:
  strip-binaries: ''

config:
  commands:
  - |
    set -eu
    root="%{install-root}"
    install -Dm755 /src/kubelet "${root}/usr/bin/kubelet"
    install -Dm755 /src/kubeadm "${root}/usr/bin/kubeadm"
    install -Dm755 /src/kubectl "${root}/usr/bin/kubectl"
    install -Dm755 /src/crictl "${root}/usr/bin/crictl"
    install -Dm755 /src/runc "${root}/usr/bin/runc"
    install -Dm755 /src/bin/containerd "${root}/usr/bin/containerd"
    install -Dm755 /src/bin/ctr "${root}/usr/bin/ctr"
    install -Dm755 /src/bin/containerd-shim-runc-v2 \
      "${root}/usr/bin/containerd-shim-runc-v2"
    mkdir -p "${root}/usr/libexec/cni"
    cp -a /src/cni/. "${root}/usr/libexec/cni/"
