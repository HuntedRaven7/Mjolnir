---
name: troubleshooting
description: Symptom-first troubleshooting for Mjolnir builds, CI, installs and booted nodes.
---

# Troubleshooting Mjolnir

Read this skill when a build, CI run, ISO install or booted node misbehaves.
Match the symptom first, then follow the check. Do not change the image to make
a symptom disappear without understanding it.

## Build fails: "fetch needed" for many FSDK elements

Normal on a cold BuildStream cache. Let the build run; the shared FSDK/Bluefin
caches serve most artifacts.

## Build fails: `Failed to download blob <sha>: 4`

The FSDK artifact cache returned a broken large blob. Pull the affected element
from the Bluefin mirror and resume:

```sh
just bst artifact pull --deps none \
  --artifact-remote https://cache.projectbluefin.io:11001 \
  freedesktop-sdk.bst:components/<element>.bst
just bst build oci/mjolnir.bst
```

## Build fails: `Staged artifacts do not provide command 'sh'` or `Command failed`

A `manual`/`script` element runs commands without a build sandbox shell, or a
local source was staged as a directory. Add `base/sandbox-tools.bst` to
`build-depends` and set `variables: strip-binaries: ''` when the FSDK stripper
is unavailable. Use `if [ -d ... ]` for local sources staged as directories.

## Content check fails: forbidden path pattern

A new dependency pulled in an interpreter/man page. Remove it in
`elements/oci/mjolnir.bst` (deny-list + `find ... -delete`). Only license and doc
directories are exempt in `tests/test_image_contents.py`.

## `bootc container lint` warns about `/var` tmpfiles

Add `d` lines under `/usr/lib/tmpfiles.d/mjolnir.conf` for each directory
created under `/var` in `base/os-stack.bst` integration commands.

## CI fails: `localhost/mjolnir:latest: image not known`

The build exported to one Podman store and push used another. Keep
`PODMAN: "sudo podman"` in the image job env so export, lint, scan and push all
use rootful storage. The scan uses a docker-archive to be store-independent.

## Installed node: no `MjolnirNode` resources

Check the `fleet-kubeconfig` credential and the publish timer:

```sh
systemctl status mjolnir-fleet-publish.timer
journalctl -u mjolnir-fleet-publish.service
kubectl get crd mjolnirnodes.mjolnir.kubestellar.io
```

## Node never reboots after `bootc upgrade`

The update must be staged (`--download-only`), then `/run/reboot-required`
created. Check:

```sh
cat /run/reboot-required
kubectl -n kube-system rollout status ds/kured
kubectl -n kube-system get ds kured -o jsonpath='{.metadata.annotations.weave\.works/kured-node-lock}'
journalctl -u mjolnir-fleet-varlink.service
```

Clear a held cluster lock with
`kubectl -n kube-system annotate ds kured weave.works/kured-node-lock-`.

## State missing after reboot (impermanence)

Only the allowlist in `docs/IMPERMANENCE.md` survives. Verify mounts with
`findmnt /etc /var/lib/containerd /var/lib/kubelet /var/log/journal` and confirm
`systemd.volatile=yes` in `/proc/cmdline`. Add a new `.mount` unit in
`/usr/lib/systemd/system` if a path must persist; do NOT use `/etc/fstab`.

## WiFi does not connect

Check the keyfile and NetworkManager backend:

```sh
nmcli device wifi list
nmcli connection show
cat /etc/NetworkManager/conf.d/10-wifi-backend.conf
journalctl -u NetworkManager
```

The PSK must be a 64-character hex string from the `wifi-psk` credential.

## Varlink call fails

Confirm the socket and mTLS client cert:

```sh
systemctl status varlink-httpd.socket mjolnir-fleet-varlink.socket
varlinkctl call https://NODE:1031/ws/services/io.mjolnir.Fleet io.mjolnir.Fleet.Status '{}'
```

The bridge requires a client certificate signed by the provisioned CA.

## Full disk-install/QEMU test needs root

`bootc install to-disk` requires a real root user namespace. Run
`PODMAN="sudo podman" just disk && just vm` as root; `just test` verifies boot
assets statically when that is unavailable.
