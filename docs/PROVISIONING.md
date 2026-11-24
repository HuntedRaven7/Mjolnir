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
  --tls-ca ./client-ca.pem \
  --journal-forward-socket collector.example:19532
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
| `journal.forward_to_socket` | journald | optional socket address for off-node journal export |
| `registry-user`, `registry-token` | provisioning | optional GHCR credentials for the image pull |

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

## Debugging a node that never joins

A node with no cluster connection still has to explain why. Two mechanisms work
before Kubernetes starts:

- The signed UKI carries `console=ttyS0,115200` and
  `systemd.journald.forward_to_console=1`. Journald writes warning-level and
  higher entries to the serial console. The kargs live in `kargs.d` and are
  baked into the signed `.cmdline`, so you cannot change them at boot time.
- The `journal.forward_to_socket` credential sets journald's `ForwardToSocket=`.
  Journald sends the journal export stream to that address. Run
  `systemd-journal-remote` on the collector to store it. The node needs no
  cluster join, token or shell for this path. Leave the credential unset when
  you do not run a collector.

Forwarding is synchronous inside journald. A collector that accepts data but
never reads it can block journald, so use a dedicated receiver and monitor it.
The serial console carries warnings only, which limits traffic on slow ports.
No address or key is stored in the image or in this repository.

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
