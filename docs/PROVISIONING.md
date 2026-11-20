# Provisioning

Mjolnir has no shell, no SSH daemon and no console login. A node is configured
entirely through **systemd credentials**, which the provisioning system passes
to the kernel (for example via `systemd.set_credential=...` on the command line
or through an Ignition-style initrd stage).

Credentials are read by `mjolnir-helper` from
`/run/credentials/@system/<name>` (system credentials) or from a unit's
`$CREDENTIALS_DIRECTORY`. They never live in the image or in the repository.

## Required credentials

| Name | Used by | Meaning |
| --- | --- | --- |
| `role` | init, join | `control-plane` or `worker` |
| `join-token` | join | kubeadm bootstrap token |
| `ca-cert-hash` | join | `sha256:<hash>` of the cluster CA |
| `control-plane-endpoint` | join | `host:6443` of the control plane |
| `wifi-ssid` | wifi | WiFi network name (station mode) |
| `wifi-psk` | wifi | 64-character hex WPA2/WPA3 PSK |
| `varlink-httpd.tls.trust` | varlink-httpd | PEM CA used to verify mTLS clients |

`wifi-*` credentials are optional; without them the node uses wired networking
only. `join-*` credentials are required on workers and ignored on the control
plane.

## First boot sequence

1. `mjolnir-wifi.service` writes `/var/lib/iwd/<SSID>.psk` and starts `iwd`.
2. `systemd-networkd` obtains an address; `network-online.target` is reached.
3. `containerd.service` and `kubelet.service` start.
4. On the control plane, `mjolnir-init.service` runs `kubeadm init`.
5. `mjolnir-apply.service` waits for `/healthz`, then applies Cilium and
   KubeStellar manifests from `/usr/share/mjolnir/manifests`.
6. On workers, `mjolnir-join.service` runs `kubeadm join` with the token.
7. `varlink-httpd.socket` accepts mTLS connections on port 1031.

## Management

Once the cluster is up:

- **Workloads and cluster state**: `kubectl` from an operator machine using
  `/etc/kubernetes/admin.conf` from the control plane.
- **Node state**: Varlink over HTTPS. Discover the available interfaces with:

```sh
curl --cacert ca.pem --cert client.pem --key client-key.pem \
  https://<node>:1031/services
```

The bridge also serves OpenAPI 3.1 descriptions at
`/openapi/{service}/{interface}`, so typed clients can be generated outside the
image. See the [Varlink bridge README](https://github.com/systemd/varlink-http-bridge)
for client configuration and the `--auth` options we deliberately do not use.

## Updates

`bootc upgrade` stages a new image; `mjolnir-reboot.timer` reboots the node
after checking `/run/reboot-required`, `/run/reboot-lock`, and
`/run/kubestellar-reboot-deferred`. Drain workloads before the reboot with your
normal Kubernetes tooling.
