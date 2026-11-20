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
3. Generate the card with your Console's externally reachable origin:

   ```sh
   CONSOLE_ORIGIN=https://console.example.com python3 build-card.py
   ```

4. In Console: **Dashboard → Add Card → Custom / Card Factory → Import JSON**,
   select `card.json`.
5. Optionally submit `mission.json` to `kubestellar/console-kb` under `fixes/`
   and add an entry to its `fixes/index.json` so it appears in Mission Browser.

## Operations via Varlink

`varlink-httpd` exposes the node's Varlink registry on mTLS port 1031. The plugin
service registers `io.mjolnir.Fleet` at
`/run/varlink/registry/io.mjolnir.Fleet`:

| Method | Effect |
|---|---|
| `Status` | Full status JSON |
| `WifiStatus` | NetworkManager SSID, interface, link state and signal |
| `Upgrade` | `bootc upgrade --download-only` (stage, no reboot) |
| `ClearRebootLock` | Remove local lock files; kured's cluster lock is cleared via `kubectl annotate ds kured weave.works/kured-node-lock-` |
| `Reboot` | Write `/run/reboot-required`; kured drains and reboots the node |
| `RotateJoinToken` | `kubeadm token create --print-join-command` (control plane only) |

Example:

```sh
varlinkctl call https://NODE:1031/ws/services/io.mjolnir.Fleet \
  io.mjolnir.Fleet.Status '{}'
```

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
