#!/usr/bin/env bash
# Simulate the KubeStellar WDS<-ITS propagation contract for the multi-node
# E2E test. Runs on the CI runner (shell is fine here; the image has none).
#
# Mirrors every MjolnirNode from the ITS cluster into the WDS cluster and
# copies its status subresource back, the way a BindingPolicy/Binding + OCM
# transport does in production. This lets us assert the CRD/status contract
# that the Console plugin and fleet publisher rely on, with real two-cluster
# API round-trips and no dependency on a full KubeStellar control plane.
set -euo pipefail

ITS_KUBECONFIG="${ITS_KUBECONFIG:?set ITS_KUBECONFIG}"
WDS_KUBECONFIG="${WDS_KUBECONFIG:?set WDS_KUBECONFIG}"
INTERVAL="${SYNC_INTERVAL:-2}"
DURATION="${SYNC_DURATION:-90}"

its() { kubectl --kubeconfig "$ITS_KUBECONFIG" "$@"; }
wds() { kubectl --kubeconfig "$WDS_KUBECONFIG" "$@"; }

fail() { echo "sync-agent: ERROR: $*" >&2; exit 1; }

mirror_one() {
  local name="$1"
  local json
  json=$(its get mjolnirnode "$name" -o json)
  local status spec manifest patch
  status=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("status", {})))')
  spec=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("spec", {})))')
  manifest=$(printf '{"apiVersion":"mjolnir.kubestellar.io/v1alpha1","kind":"MjolnirNode","metadata":{"name":"%s","labels":{"mjolnir.kubestellar.io/its":"its-1"}},"spec":%s}' \
    "$name" "$spec")

  printf '%s' "$manifest" | wds apply -f - >/dev/null
  if [ "$status" != "{}" ]; then
    patch=$(printf '{"status":%s}' "$status")
    wds patch mjolnirnode "$name" --subresource=status --type=merge -p "$patch" >/dev/null
  fi
}

echo "sync-agent: watching ITS MjolnirNodes -> WDS for ${DURATION}s"
deadline=$((SECONDS + DURATION))
while [ "$SECONDS" -lt "$deadline" ]; do
  names=$(its get mjolnirnodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  for name in $names; do
    mirror_one "$name" || fail "mirroring $name"
  done
  sleep "$INTERVAL"
done
echo "sync-agent: done"
