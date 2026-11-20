#!/usr/bin/env bash
# Smoke-test the KubeStellar Console fleet plugin against a local API server.
# Verifies the CRD, RBAC, publisher status shape and the card's data path
# (/api/mcp/custom-resources is emulated with `kubectl get` here).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
NS="${MJOLNIR_TEST_NS:-default}"

for tool in "$KUBECTL"; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

fail() { echo "::error::$*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

echo "==> applying CRD and RBAC"
$KUBECTL apply -f "$ROOT/plugins/console/crds/mjolnirnodes.yaml"
$KUBECTL apply -f "$ROOT/plugins/console/rbac.yaml"
pass "CRD and RBAC applied"

echo "==> creating a synthetic MjolnirNode"
$KUBECTL apply -n "$NS" -f - <<'EOF'
apiVersion: mjolnir.kubestellar.io/v1alpha1
kind: MjolnirNode
metadata:
  name: mjolnir-plugin-test
spec:
  role: worker
  varlinkEndpoint: https://mjolnir-plugin-test:1031
status:
  image: ghcr.io/HuntedRaven7/Mjolnir:test
  version: "26.11.1"
  updateAvailable: true
  pendingDeployment: ghcr.io/HuntedRaven7/Mjolnir:next
  rebootRequired: false
  rebootLock: false
  rebootDeferred: false
  lastCheck: "2026-11-20T00:00:00Z"
  wifi:
    ssid: test-net
    interface: wlan0
    state: UP
    signal: "-55 dBm"
EOF
pass "synthetic MjolnirNode created"

echo "==> verifying the CRD schema accepted all status fields"
NODE=$($KUBECTL get mjolnirnode mjolnir-plugin-test -o json)
for field in version updateAvailable pendingDeployment rebootRequired rebootLock wifi; do
  echo "$NODE" | grep -q "\"$field\"" || fail "missing status field: $field"
done
echo "$NODE" | grep -q '"ssid": "test-net"' || fail "wifi.ssid not persisted"
pass "all status fields (including WiFi) round-trip through the CRD"

echo "==> verifying the card's data query shape"
# The Tier 2 card calls /api/mcp/custom-resources?group=...&resource=mjolnirnodes.
# Here we assert the equivalent kubectl query returns the item with spec/status.
ITEMS=$($KUBECTL get mjolnirnodes.mjolnir.kubestellar.io -o json)
echo "$ITEMS" | grep -q '"items"' || fail "list response has no items array"
echo "$ITEMS" | grep -q 'mjolnir-plugin-test' || fail "fleet list is empty"
pass "fleet list query returns the node"

echo "==> validating card and mission definitions"
python3 - "$ROOT" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
card = json.loads((root / "plugins/console/card.json").read_text())
assert card["tier"] == "tier2", card["tier"]
assert "/api/mcp/custom-resources" in card["sourceCode"], "card does not query custom resources"
assert "wifi" in card["sourceCode"], "card does not show WiFi state"
mission = json.loads((root / "plugins/console/mission.json").read_text())
assert mission["version"] == "kc-mission-v1"
steps = mission["mission"]["steps"]
assert any("kured" in s.get("title", "").lower() for s in steps), "no kured step"
assert any("Varlink" in s.get("title", "") for s in steps), "no Varlink step"
print("PASS: card and mission definitions are valid")
PY

echo "==> cleaning up"
$KUBECTL delete mjolnirnode mjolnir-plugin-test --ignore-not-found
pass "plugin smoke test passed"
