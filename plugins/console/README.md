# Mjolnir fleet plugin for KubeStellar Console

Surfaces Mjolnir bootc nodes as `MjolnirNode` custom resources and lets operators
act on them through the node's mTLS Varlink API. It is built into every Mjolnir
image; no Console fork or backend plugin is required.

KubeStellar Console has no third-party plugin SDK today. This uses two supported
paths: a **Tier 2 dynamic card** that reads `/api/mcp/custom-resources`, and a
**kc-mission-v1 runbook** that Documents the Varlink operations.

## Components

| Path | Purpose |
|---|---|
| `crds/mjolnirnodes.yaml` | Cluster-scoped CRD (`mjolnir.kubestellar.io/v1alpha1`) |
| `rbac.yaml` | ServiceAccount + ClusterRole for the status publisher |
| `src/fleet.c` | Compiled exporter and Varlink action service (no shell/interpreter) |
| `files/systemd/` | Socket-activated Varlink service and 1-minute publish timer |
| `src/card.tsx`, `build-card.py` | Source and generator for the Tier 2 card |
| `card.json` | Generated dynamic card definition |
| `mission.json` | Console mission / runbook |
| `manifests/kured.yaml` | Pinned kured DaemonSet and RBAC |

## Status fields

`MjolnirNode.status` carries `image`, `version`, `updateAvailable`,
`pendingDeployment`, `rebootRequired`, `rebootLock`, `rebootDeferred`,
`lastCheck`, `wifi { ssid, interface, state, signal }` and `conditions`.
`spec` carries `role` and `varlinkEndpoint`.

## Install

1. The CRD and RBAC are applied by `mjolnir-helper apply` at cluster bootstrap.
   To install manually: `kubectl apply -f crds/ -f rbac.yaml`.
2. Create a token for the `mjolnir-fleet` ServiceAccount and pass the kubeconfig
   to every node as the systemd credential `fleet-kubeconfig` (base64 or plain
   YAML text). The publisher writes it to `/run/mjolnir/fleet.kubeconfig`.
3. Generate the card:

   ```sh
   just plugin-card
   ```

   This auto-detects the Console origin from `CONSOLE_ORIGIN`, the
   `kubestellar-console` Helm release's Ingress host, or a Kubernetes
   Ingress/Route whose host contains `console`. If none is found it exits with
   a clear message asking for `CONSOLE_ORIGIN` explicitly.

4. In Console: **Dashboard → Add Card → Custom / Card Factory → Import JSON**,
   select `card.json`.

5. Optionally submit `mission.json` to `kubestellar/console-kb` under `fixes/`
   and add an entry to its `fixes/index.json` so it appears in Mission Browser.

Why is the origin needed at all? Tier 2 dynamic card code runs in a hardened
sandbox with no `window`, `document` or `location`, and `useCardFetch` must call
an absolute URL through Console's `/api/card-proxy` (which rejects private IPs).
A card therefore cannot discover its own origin at runtime. Console also has no
card-import API, so the one UI import click cannot be automated locally. A truly
zero-config install requires an in-tree card in
`kubestellar/console-marketplace` that calls the Console backend directly —
that is the upstream issue. `just plugin-card` removes the origin guesswork;
the single UI import remains.

## Operations via Varlink

`varlink-httpd` exposes the node's Varlink registry on mTLS port 1031. The plugin
service registers `io.mjolnir.Fleet` at
`/run/varlink/registry/io.mjolnir.Fleet`:

| Method | Effect |
|---|---|
| `Status` | Full status JSON |
| `WifiStatus` | NetworkManager SSID, interface, link state and signal |
| `Attestation` | TPM/DICE attestation evidence |
| `JournalTail` | Last 1 to 1000 journal lines, optionally for one unit |
| `UnitStatus` | `systemctl show` for a named unit and allowlisted properties |
| `BootcStatus` | Parsed `bootc status --json` plus `exitCode` |
| `KubeadmPreflight` | Read-only `kubeadm init phase preflight --dry-run` output |
| `NetworkChecks` | `ip -j addr`, `ip -j route`, `ss -tuln`, `resolvectl status` and WiFi state |
| `Upgrade` | `bootc upgrade --download-only` (stage, no reboot) |
| `ClearRebootLock` | Remove local lock files; kured's cluster lock is cleared via `kubectl annotate ds kured weave.works/kured-node-lock-` |
| `Reboot` | Write `/run/reboot-required`; kured drains and reboots the node |
| `RotateJoinToken` | `kubeadm token create --print-join-command` (control plane only) |

Example:

```sh
varlinkctl call https://NODE:1031/ws/services/io.mjolnir.Fleet \
  io.mjolnir.Fleet.Status '{}'
```

`GetInfo` returns the full method list in its `methods` field.

## Read-only diagnostics

`JournalTail`, `UnitStatus`, `BootcStatus`, `KubeadmPreflight` and
`NetworkChecks` never change node state. They run compiled binaries with a
fixed argv; no caller string reaches a shell or an option position.

- `lines` must be an integer from 1 to 1000 and defaults to 100.
- `unit` must be a systemd unit name of at most 128 characters. `JournalTail`
  accepts it as an optional filter; `UnitStatus` requires it.
- `properties` is optional. When given it is an array of 1 to 16 names from
  `LoadState`, `ActiveState`, `SubState`, `MainPID`, `ExecMainStatus`, `Result`,
  `Description`, `FragmentPath`, `ActiveEnterTimestamp` and `NRestarts`.
- Output is capped at 64 KiB and each command is killed after 5 seconds. A
  timeout returns `exitCode` 124. Invalid arguments return an
  `InvalidArguments` error.
- `KubeadmPreflight` uses `/etc/mjolnir/kubeadm-init.yaml` and checks node
  readiness before join. On a joined control plane it reports the checks that
  now fail because the cluster already exists.

bootc already handles a bad update: a staged deployment that does not come up
is rolled back to the previous one. No separate rollback service or Varlink
method is added here.

## kured

Reboots are not performed directly on the host. kured 1.23.0 is applied at
cluster bootstrap from `manifests/kured.yaml` with the image pinned by digest.
It uses the signal reboot method (`CAP_KILL` only, no privileged `nsenter`),
watches `/run` through a hostPath mount, and coordinates reboots with the
`weave.works/kured-node-lock` annotation on its DaemonSet.

## Constraints

- The card proxy rejects private IP addresses, so the `CONSOLE_ORIGIN` used by
  the Tier 2 card must be publicly routable. For a LAN-only Console, either use
  a reverse proxy with a public name or contribute an in-tree card upstream.
- `Reboot` and `RotateJoinToken` are privileged; protect the Varlink client CA
  and audit calls. The read-only card uses normal Console RBAC.
- No credentials or node IPs are stored in this repository.
