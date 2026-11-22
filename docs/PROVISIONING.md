# Provisioning

Mjolnir has no shell, no SSH daemon and no console login. A node is configured
entirely through **systemd credentials**, which the provisioning system passes
to the kernel (for example via `systemd.set_credential=...` on the command line
or through an Ignition-style initrd stage).

Credentials are read by `mjolnir-helper` from
`/run/credentials/@system/<name>` (system credentials) or from a unit's
`$CREDENTIALS_DIRECTORY`. They never live in the image or in the repository.

Use `scripts/make-credentials.py` to build the directory on the provisioning
host; it validates the values, writes files as 0600 in a 0700 directory, and
prints only the credential *names*:

```sh
python3 scripts/make-credentials.py --out ./cred --role worker \
  --join-token "$TOKEN" --ca-cert-hash "sha256:$HASH" \
  --endpoint control-plane.example:6443 \
  --wifi-ssid homelab --wifi-psk "$PSK" \
  --tls-ca ./client-ca.pem
```

Mount the resulting directory where the provisioning system expects it (for
example `/run/credentials/@system/`). Never commit it: add it to `.gitignore` or
keep it outside the repository.

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
| `registry-user`, `registry-token` | installer | optional GHCR credentials for the image pull |
| `wifi-ssid`, `wifi-psk` | installer | optional WiFi used during installation |

`wifi-*` credentials are optional; without them the node uses wired networking
only. `join-*` credentials are required on workers and ignored on the control
plane.

## First boot sequence

1. `mjolnir-wifi.service` writes a NetworkManager keyfile to `/etc/NetworkManager/system-connections/<SSID>.nmconnection` and reloads NetworkManager.
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

`bootc upgrade --download-only` stages a new image and writes
`/run/reboot-required`. The **kured** DaemonSet (applied at bootstrap from
`plugins/console/manifests/kured.yaml`) watches that sentinel, cordons and
drains the node, reboots it with SIGRTMIN+5, and uncordons it on return.
Hold reboots cluster-wide with the kured lock annotation:

```sh
kubectl -n kube-system annotate ds kured \
  weave.works/kured-node-lock='{"nodeID":"manual"}' --overwrite
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock-
```
