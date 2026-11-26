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

For snapshots add `--snapshot-url https://... [--snapshot-token TOKEN]` to the
same invocation. The URL must be HTTPS; both values are written as 0600 files.

### Sealed reset credentials

Factory reset requires encrypted credentials delivered as systemd credentials
(`/run/credentials/@system/reset-confirm.cred` and `reset-lone-cp.cred`). They
are sealed to the signed PCR 11 policy so they are readable only by a trusted
boot. Create them off-node with the public key extracted from the signed UKI
(the public half is not a secret), then place the `.cred` files in the
provisioning credential directory:

```sh
objcopy -O binary -j .pcrpkey mjolnir.efi tpm2-pcr-public-key.pem
printf 'factory-reset:etcd-data' | \
  systemd-creds encrypt --name=reset-confirm --with-key=tpm2 \
    --tpm2-public-key=tpm2-pcr-public-key.pem - \
    reset-confirm.cred
printf 'lone-cp-etcd-wipe-v1' | \
  systemd-creds encrypt --name=reset-lone-cp --with-key=tpm2 \
    --tpm2-public-key=tpm2-pcr-public-key.pem - \
    reset-lone-cp.cred
```

Use the confirmation string for the scope you intend to allow. The helper
checks the decrypted value before any file is removed. Without both files the
reset units fail closed.

### Journal forwarding credential

`make-credentials.py --journal-forward-socket <address>` also writes a
`journal.forward_to_socket` credential. No component in the Mjolnir image reads
it. No unit imports it, no journald drop-in sets `ForwardToSocket=`, and no code
uses the value. Journald forwarding is not enabled; the file is available only
to provisioning tooling outside the image.

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
| `journal.forward_to_socket` | provisioning only | optional value written for external tooling; no image consumer, no journald effect |
| `registry-user`, `registry-token` | provisioning | optional GHCR credentials for the image pull |
| `etcd-snapshot-url`, `etcd-snapshot-token` | etcd snapshot | HTTPS destination and bearer token for off-node snapshots |
| `reset-confirm`, `reset-lone-cp` | reset services | TPM2-sealed confirmations, created off-node as `.cred` files |

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
- Off-node journal export is not enabled in this image. The provisioning tool
  can write a `journal.forward_to_socket` credential, but nothing in the image
  imports or reads it, so journald does not gain a `ForwardToSocket=` setting
  from it. The serial console above is the only pre-cluster diagnostic path.

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
