# Impermanent root (NixOS-impermanence semantics)

Mjolnir uses `systemd.volatile=yes` to give every boot a fresh `/etc` and `/var`
from tmpfs. Only the verification-protected `/usr` comes from disk (composefs +
dm-verity). An explicit allowlist is re-attached from a dedicated persistent
btrfs partition labelled `MjolnirState`, so each boot starts clean except for
state that must survive.

This is the bootc/systemd equivalent of
[NixOS impermanence](https://wiki.nixos.org/wiki/Impermanence), where `/` is
tmpfs and only a declared set of directories is bind-mounted back from
persistent storage.

## What is ephemeral

Everything under `/etc` and `/var` **except** the allowlist below. This includes
logs not under `/var/log/journal`, temporary files, and any state a workload
writes outside the allowlist. `/run` is always tmpfs.

Pristine `/etc` defaults are rehydrated at boot from `/usr/share/factory/etc/`
by `systemd-tmpfiles` rules in `/usr/lib/tmpfiles.d/mjolnir-volatile.conf`
(`L` links, `C` copies). Users and groups come from `/usr/lib/sysusers.d`.

## What persists

| Path | Why |
|---|---|
| `/etc/machine-id` | Stable node identity for journald, DHCP and Kubernetes |
| `/etc/NetworkManager/system-connections` | WiFi profiles written by `mjolnir-helper wifi` |
| `/var/lib/containerd` | CRI content store, metadata and snapshots (all-or-nothing) |
| `/var/lib/kubelet` | TLS bootstrap certs, config, CPU/device manager checkpoints |
| `/var/lib/cni` | CNI IPAM leases |
| `/var/log/journal` | Persistent journal (keyed by the stable machine-id) |
| `/etc/kubernetes` | kubeadm-generated configuration |

kured's cluster-wide lock lives in the Kubernetes API, not on the host, so it
needs no local persistence.

## Implementation

- `files/config/bootc/kargs.d/50-volatile.toml`: `kargs = ["systemd.volatile=yes"]`.
  This is installed into the image, so it survives `bootc upgrade`.
- `files/config/repart.d/20-mjolnir-state.conf`: a `state` partition labelled
  `MjolnirState`, created on first boot by `systemd-repart`.
- `files/config/systemd/*.mount`: native mount units in `/usr`. Under volatile
  mode `/etc/fstab` is ephemeral, so mount units are mandatory. The state
  partition is mounted at `/var/lib/mjolnir`, then each allowlist path is a
  bind mount from there.
- `files/config/journald/10-persistent.conf`: `Storage=persistent`, capped at 2G.
- `bootc install to-disk` boot configuration: provisioning passes a generated
  machine ID via a kernel argument so PID 1 keeps a stable ID across the
  volatile root. No credential or static ID is baked into the image.

## Verify on a booted node

```sh
cat /proc/cmdline | grep systemd.volatile
findmnt /etc /var /var/lib/containerd /var/lib/kubelet /var/log/journal
cat /etc/machine-id   # identical across two reboots
```

## Trade-offs

- A workload that writes outside the allowlist loses that state on reboot. This
  is intentional; use a Kubernetes volume or add a path to the allowlist.
- `containerd` must persist its whole root as a unit; a partial store (metadata
  without blobs or vice versa) fails with a fatal CRI error.
- `/etc` changes made by hand are lost. Use Ignition/systemd credentials or a
  confext for declarative configuration; the Console plugin already stores
  fleet state in the cluster.
