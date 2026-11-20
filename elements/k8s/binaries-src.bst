kind: manual
description: |
  Download and verify all Kubernetes node binaries. Kept separate from the
  script element because BuildStream forbids sources on script elements.

build-depends:
- base/sandbox-tools.bst

variables:
  strip-binaries: ''
  (?):
  - arch == 'x86_64':
      kubelet-sha: '%{kubelet-amd64-sha256}'
      kubeadm-sha: '%{kubeadm-amd64-sha256}'
      kubectl-sha: '%{kubectl-amd64-sha256}'
      crictl-sha: '%{crictl-amd64-sha256}'
      containerd-sha: '%{containerd-amd64-sha256}'
      runc-sha: '%{runc-amd64-sha256}'
      cni-sha: '%{cni-plugins-amd64-sha256}'
  - arch == 'aarch64':
      kubelet-sha: '%{kubelet-arm64-sha256}'
      kubeadm-sha: '%{kubeadm-arm64-sha256}'
      kubectl-sha: '%{kubectl-arm64-sha256}'
      crictl-sha: '%{crictl-arm64-sha256}'
      containerd-sha: '%{containerd-arm64-sha256}'
      runc-sha: '%{runc-arm64-sha256}'
      cni-sha: '%{cni-plugins-arm64-sha256}'

sources:
- kind: remote
  url: 'k8s:v%{kubernetes-version}/bin/linux/%{go-arch}/kubelet'
  ref: '%{kubelet-sha}'
- kind: remote
  url: 'k8s:v%{kubernetes-version}/bin/linux/%{go-arch}/kubeadm'
  ref: '%{kubeadm-sha}'
- kind: remote
  url: 'k8s:v%{kubernetes-version}/bin/linux/%{go-arch}/kubectl'
  ref: '%{kubectl-sha}'
- kind: remote
  url: 'github:kubernetes-sigs/cri-tools/releases/download/v%{crictl-version}/crictl-v%{crictl-version}-linux-%{go-arch}.tar.gz'
  ref: '%{crictl-sha}'
- kind: remote
  url: 'github:containerd/containerd/releases/download/v%{containerd-version}/containerd-%{containerd-version}-linux-%{go-arch}.tar.gz'
  ref: '%{containerd-sha}'
- kind: remote
  url: 'github:opencontainers/runc/releases/download/v%{runc-version}/runc.%{go-arch}'
  ref: '%{runc-sha}'
- kind: remote
  url: 'github:containernetworking/plugins/releases/download/v%{cni-plugins-version}/cni-plugins-linux-%{go-arch}-v%{cni-plugins-version}.tgz'
  ref: '%{cni-sha}'

config:
  install-commands:
  - |
    set -eu
    d="%{install-root}"
    mkdir -p "${d}"
    cp kubelet kubeadm kubectl "${d}/"
    tar --no-same-owner -xzf crictl-v%{crictl-version}-linux-%{go-arch}.tar.gz -C "${d}"
    cp "runc.%{go-arch}" "${d}/runc"
    tar --no-same-owner -xzf "containerd-%{containerd-version}-linux-%{go-arch}.tar.gz" -C "${d}"
    mkdir -p "${d}/cni"
    tar --no-same-owner -xzf "cni-plugins-linux-%{go-arch}-v%{cni-plugins-version}.tgz" -C "${d}/cni"
