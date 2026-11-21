#!/usr/bin/env bash
# Multi-node KubeStellar propagation E2E.
#
# Creates two kind clusters (a WDS fleet control plane and an ITS member
# cluster), installs the MjolnirNode CRD in both, runs a small sync agent that
# mimics the KubeStellar WDS<->ITS propagation contract, and asserts:
#
#   1. Two independent MjolnirNodes (control-plane + worker) created in the ITS
#      propagate to the WDS.
#   2. A status update written through the CRD status subresource in the ITS
#      propagates back to the WDS copy.
#   3. The Console plugin's fleet-list query shape returns both nodes with
#      their spec+status, exactly as the Tier 2 card consumes them.
#
# Runs on hosted ubuntu-24.04 runners; no QEMU/KVM and no shell in the image.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRD="$ROOT/plugins/console/crds/mjolnirnodes.yaml"
AGENT="$(dirname "${BASH_SOURCE[0]}")/sync-agent.sh"
# Use a dedicated temp dir (RUNNER_TEMP on Actions, /tmp locally). Never hardcode
# an OpenCode-specific path: it does not exist on GitHub-hosted runners.
WORKDIR="${RUNNER_TEMP:-/tmp}/mjolnir-multinode"
mkdir -p "$WORKDIR"
WDS_KC="$WORKDIR/wds.kubeconfig"
ITS_KC="$WORKDIR/its.kubeconfig"
AGENT_LOG="$WORKDIR/sync-agent.log"
AGENT_PID=""

for tool in kubectl kind python3; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

fail() { echo "::error::$*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
cleanup() {
  [ -n "$AGENT_PID" ] && kill "$AGENT_PID" 2>/dev/null || true
  kind delete cluster --name mjolnir-wds >/dev/null 2>&1 || true
  kind delete cluster --name mjolnir-its >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> creating WDS and ITS kind clusters"
kind create cluster --name mjolnir-wds --wait 120s
kind create cluster --name mjolnir-its --wait 120s
kind get kubeconfig --name mjolnir-wds > "$WDS_KC"
kind get kubeconfig --name mjolnir-its > "$ITS_KC"
pass "two clusters created"

echo "==> installing MjolnirNode CRD in both clusters"
kubectl --kubeconfig "$WDS_KC" apply -f "$CRD"
kubectl --kubeconfig "$ITS_KC" apply -f "$CRD"
kubectl --kubeconfig "$WDS_KC" rollout status deploy/kube-dns -n kube-system >/dev/null 2>&1 || true
pass "CRD installed in WDS and ITS"

echo "==> creating two MjolnirNodes in the ITS"
for node in mjolnir-cp-1 mjolnir-worker-1; do
  role=worker
  [ "$node" = mjolnir-cp-1 ] && role=control-plane
  kubectl --kubeconfig "$ITS_KC" apply -f - <<EOF
apiVersion: mjolnir.kubestellar.io/v1alpha1
kind: MjolnirNode
metadata:
  name: $node
spec:
  role: $role
  varlinkEndpoint: https://$node:1031
EOF
done
pass "two nodes created in ITS"

echo "==> starting propagation agent"
ITS_KUBECONFIG="$ITS_KC" WDS_KUBECONFIG="$WDS_KC" \
  SYNC_DURATION=180 bash "$AGENT" >"$AGENT_LOG" 2>&1 &
AGENT_PID=$!
pass "propagation agent started"

echo "==> waiting for both nodes to appear in the WDS"
for i in $(seq 1 30); do
  COUNT=$(kubectl --kubeconfig "$WDS_KC" get mjolnirnodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
  [ "$COUNT" -ge 2 ] && break
  sleep 2
done
[ "${COUNT:-0}" -ge 2 ] || { cat "$AGENT_LOG" >&2; fail "expected 2 nodes in WDS, got ${COUNT:-0}"; }
for node in mjolnir-cp-1 mjolnir-worker-1; do
  kubectl --kubeconfig "$WDS_KC" get mjolnirnode "$node" >/dev/null || fail "$node missing in WDS"
done
pass "both nodes propagated to WDS"

echo "==> writing status in the ITS and verifying propagation back"
kubectl --kubeconfig "$ITS_KC" patch mjolnirnode mjolnir-worker-1 \
  --subresource=status --type=merge -p '{
    "status": {
      "version": "26.11.2",
      "updateAvailable": true,
      "image": "ghcr.io/huntedraven7/mjolnir:next",
      "attestation": {"method": "tpm2", "bootId": "multi-node-boot-1"},
      "wifi": {"ssid": "fleet-net", "interface": "wlan0", "state": "UP"}
    }
  }' >/dev/null
for i in $(seq 1 30); do
  VER=$(kubectl --kubeconfig "$WDS_KC" get mjolnirnode mjolnir-worker-1 -o jsonpath='{.status.version}' 2>/dev/null || true)
  [ "$VER" = "26.11.2" ] && break
  sleep 2
done
[ "${VER:-}" = "26.11.2" ] || { cat "$AGENT_LOG" >&2; fail "status.version did not propagate (got '$VER')"; }
pass "status subresource update propagated ITS -> WDS"

echo "==> verifying the Console fleet-list query shape"
ITEMS=$(kubectl --kubeconfig "$WDS_KC" get mjolnirnodes.mjolnir.kubestellar.io -o json)
python3 - "$ITEMS" <<'PY'
import json, sys
items = json.loads(sys.argv[1])["items"]
assert len(items) >= 2, f"expected >=2 items, got {len(items)}"
by_name = {i["metadata"]["name"]: i for i in items}
w = by_name["mjolnir-worker-1"]
assert w["spec"]["role"] == "worker", w["spec"]
assert w["status"]["version"] == "26.11.2", w["status"]
assert w["status"]["attestation"]["method"] == "tpm2", w["status"]
assert w["status"]["wifi"]["ssid"] == "fleet-net", w["status"]
cp = by_name["mjolnir-cp-1"]
assert cp["spec"]["role"] == "control-plane", cp["spec"]
print("PASS: Console fleet list returns both nodes with spec + status")
PY
pass "multi-node propagation E2E passed"
