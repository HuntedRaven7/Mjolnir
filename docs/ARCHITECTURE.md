# Mjolnir architecture

## 1. Scope and fixed decisions

Mjolnir is a **bootc OCI server image** built from freedesktop-sdk with
BuildStream 2. It is deliberately narrower than a general-purpose distribution:

- one base image, composed from FSDK components, no other distro binaries;
- no k0s — Kubernetes is upstream kubeadm, kubelet, containerd, runc and CNI;
- a multi-node homelab cluster (one control plane, N workers, bootstrap-token join);
- WiFi **client** only;
- management over Varlink-over-HTTPS with mTLS, not SSH;
- no shell, SSH daemon or language interpreter in the base or in any active layer.

The reference designs are
[projectbluefin/server](https://github.com/projectbluefin/server) (FSDK/BuildStream,
kubeadm sysext, KubeStellar add-on),
[projectbluefin/actions](https://github.com/projectbluefin/actions) (CI), and the
[Amutable Foundations technical overview](https://amutable.com/blog/amutable-foundations-technical-overview)
(the seven security properties).

## 2. Image composition

BuildStream composes the following tree. Layers marked *compiled* contain only
ELF binaries and static data; no script is shipped to the target.

```text
freedesktop-sdk (junction, pinned)
└── base/runtime.bst            systemd, glibc, coreutils subset, util-linux subset
    └── base/sanitize.bst       removes shells/interpreters/SSH, SUID/SGID, file caps
        ├── (wireless deps)     NetworkManager + wpa-supplicant + firmware (client only)
        ├── net/primary.bst     systemd-networkd, resolved
        ├── mgmt/varlink.bst    varlink-httpd (Rust), credstore integration
        ├── k8s/runtime.bst     kubeadm, kubelet, kubectl, crictl, containerd, runc, CNI
        │   └── k8s/helpers.bst mjolnir-init, mjolnir-join, mjolnir-wifi (Rust)
        ├── k8s/manifests.bst   Cilium, KubeStellar core, KubeStellar Console (pinned digests)
        └── oci/mjolnir.bst     final bootc OCI image + labels
```

The final OCI image carries the standard bootc labels:

```text
containers.bootc=1
ostree.bootable=1
CONTAINER=oci
```

## 3. Boot and provisioning flow

1. `bootc install to-disk` writes a composefs-backed root plus systemd-boot.
2. First boot consumes **systemd credentials** supplied by the provisioning
   system (USB stick, BMC, or out-of-band). No SSH, no console login.
3. Role selection is a credential: `mjolnir.role = control-plane | worker`.
4. `mjolnir-wifi.service` writes the WPA PSK from a credential into
   a NetworkManager keyfile at `/etc/NetworkManager/system-connections/<SSID>.nmconnection`, then NetworkManager associates and reports
   `network-online.target`.
5. `varlink-httpd.socket` activates the management API on TCP 1031. TLS
   material and the client CA come from `/etc/credstore` via
   `ImportCredential=`, so the bridge starts with mTLS enforced.
6. **Control plane**: `mjolnir-init.service` runs `kubeadm init` with a
   read-only config from `/usr/share/mjolnir/kubernetes/init.yaml`. On success
   it applies Cilium, then KubeStellar and the Console manifests.
7. **Worker**: `mjolnir-join.service` reads the bootstrap token and CA hash
   from credentials and execs `kubeadm join`.
8. Updates are `bootc upgrade --download-only`; a staged update sets
   `/run/reboot-required`. **kured** (pinned DaemonSet, signal reboot method)
   drains the node and reboots it under a cluster-wide lock annotation.

## 4. Enforcing "no shell / no SSH / no interpreters"

This is a build-time property, not a runtime policy.

- A `base/sanitize.bst` element removes an explicit deny-list from the exported
  tree: `sh`, `bash`, `dash`, `zsh`, `fish`, `python*`, `perl*`, `ruby`, `node`,
  `php`, `lua`, `awk`, `gawk`, all `openssh` binaries, and any package manager.
- `tests/test_image_contents.py` re-checks the exported image: it fails on any
  shell/interpreter path, any `sshd` unit, any unit containing `sh -c`, and on
  any file with SUID/SGID bits or file capabilities.
- All orchestration logic that would normally be a shell script is a small Rust
  binary in `src/`. These helpers only exec other binaries and read credentials;
  they do not embed an interpreter.
- Compiled utilities required by kubeadm (`cp`, `mount`, `losetup`) are kept —
  they are native ELF binaries, not interpreters.
- Privilege is not obtained through SUID bits: units that need it declare
  `AmbientCapabilities=` and `CapabilityBoundingSet=`.

## 5. Networking and WiFi

- `systemd-networkd` handles wired links; `systemd-resolved` provides
  `/etc/resolv.conf` at the path kubelet expects.
- `NetworkManager` with the `wpa-supplicant` WiFi backend is the only wireless component (client/station mode). FSDK builds NetworkManager with iwd support; our config forces `wifi.backend=wpa-supplicant`.
- PSKs are never in the image: `mjolnir-wifi` copies a 64-hex-digit PSK from the
  credential store to `/etc/NetworkManager/system-connections/<SSID>.nmconnection` with mode 0600.
- Firmware is included from FSDK; the deny-list of non-free firmware is
  intentional — only firmware reachable from FSDK is shipped.
- Cilium is the CNI, replacing kube-proxy (`kubeProxyReplacement=true`).
  Kernel options required by Cilium are provided by the FSDK kernel config;
  this is validated in `tests/test_kernel_config.py`.

## 6. Kubernetes (no k0s)

Versions and checksums are centralised in `include/versions.yml`.

| Component | Role |
| --- | --- |
| kubeadm | cluster init/join, upgrades |
| kubelet | node agent, registered with systemd cgroup driver |
| kubectl | applying manifests from systemd units |
| crictl | CRI inspection |
| containerd | CRI runtime, `SystemdCgroup=true` |
| runc | OCI runtime |
| CNI plugins | base CNI binaries; Cilium installs its own into `/opt/cni/bin` |
| Cilium | CNI + kube-proxy replacement |

The control plane is a single kubeadm node that also runs workloads. Workers
join using a bootstrap token and CA hash delivered as credentials. The role
config and the kubeadm `InitConfiguration` live under `files/kubernetes/`.

## 7. KubeStellar

KubeStellar is deployed as Kubernetes manifests applied after the control plane
is Ready. All registry references are pinned by digest (the same rule the
Bluefin Server KubeStellar sysext enforces). The Console runs in-cluster behind
a Service so no browser-facing process runs on the host. Core KubeStellar
components (KubeFlex, workload/transport spaces, controllers) are applied from
their published release manifests.

## 8. Varlink management plane

`systemd/varlink-http-bridge` exposes the node's Varlink IPC over HTTPS on port
1031: `io.systemd.Manager`, `io.systemd.Unit`, `io.systemd.JournalAccess`,
`io.systemd.SysUpdate`, `io.systemd.FactoryReset`, and any service that registers
a Varlink interface.

- The bridge is a Rust binary built from a pinned source revision; the source
  repo does not publish release tarballs.
- Authentication is mTLS only (`--require-mtls`, client CA from the credstore).
  `--auth=ssh` is deliberately **not** used: it authenticates keys but is not an
  SSH server, and we do not want SSH key material on the node.
- The self-signed server certificate is generated on first start and pinned by
  the operator (the bridge prints a `sha256//...` public-key pin).
- The API is self-describing: `/openapi/{service}/{interface}` serves OpenAPI
  3.1, so clients can be generated in any language outside the image.

## 9. Amutable properties — implementation status

| # | Property | Status |
| --- | --- | --- |
| 1 | No Shell + No SSH + No Language Interpreters | Build-time deny-list + CI assertion |
| 2 | Signed Images Only | cosign keyless signature + bootc signature policy |
| 3 | W^X | read-only `/usr`, `noexec` writable mounts |
| 4 | Everything Measured | signed UKI (PCR 11), composefs digest pinned in `.cmdline`, TPM PCR evidence; full `TPM2_Quote` attestation is future work |
| 5 | No SUID/SGID or File Capabilities | stripped at build time; capabilities via units |
| 6 | Integrity Is Mandatory | signed UKI + composefs verity seal (no externally supplied kargs), pinned image digests, no mutable fetches |
| 7 | Factory Reset Is Built In | `systemd-factory-reset` unit with sealed key |

## 10. Build and CI pipeline

```text
bst build oci/mjolnir.bst
  → podman load OCI archive
  → bootc container lint
  → content assertions
  → cosign sign + SBOM attestation (projectbluefin/actions)
  → trivy scan (projectbluefin/actions)
  → multi-arch manifest (projectbluefin/actions)
  → GHCR push
```

Only the artifact-level `projectbluefin/actions` are reusable here: `scan-image`,
`sign-and-publish`, `create-manifest`, `create-release`, `ghcr-cleanup`,
`check-token-health`. The dnf/Containerfile-specific ones (`setup-runner` with
dnf, `dnf-cache`, `rechunk`, `chunka`, `apply-pkg-intervals`) are not used.

## 11. Open issues

- `varlink-httpd` for both x86_64 and aarch64 is built reproducibly by
  `scripts/build-varlink.sh`; both sha256 pins live in `include/versions.yml`.
- Full remote attestation (reports/ledger, `TPM2_Quote`) is out of scope for the
  first image. The signed UKI gives a stable PCR 11 measurement and the composefs
  digest is pinned inside the signed `.cmdline`; `mjolnir-fleet status` reports
  both as evidence.
- Cilium and KubeStellar image digests must be refreshed when versions are bumped.
- The FSDK kernel config needs Cilium's VXLAN/BPF options; verify with a boot test
  before treating the image as usable.
- Secure Boot key **enrollment** on real hardware is a manual, out-of-band step.
  The image ships a signed UKI plus a signed systemd-boot and `bootctl` accepts
  the DB key from `loader/keys/auto/` in setup mode; see `docs/SECURITY.md`.
  `bootc upgrade` with the sealed UKI must be validated on real hardware
  (the highest-risk unknown — bootc marks sealed images experimental).
