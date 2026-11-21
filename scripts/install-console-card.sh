#!/usr/bin/env bash
# Generate a ready-to-import Console card without asking the user to know the
# Console's external origin. Detection order:
#
#   1. CONSOLE_ORIGIN environment variable (explicit override)
#   2. The Console Helm release's `ingress.hosts[0].host` (helm get values)
#   3. A Kubernetes Ingress/Route whose host contains "console"
#
# The card still has to be imported once in the Console UI
# (Dashboard -> Add Card -> Card Factory -> Import JSON): Tier 2 cards are
# client-side only and Console exposes no import API. This script removes the
# CONSOLE_ORIGIN guesswork, not the UI click.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CARD="$ROOT/plugins/console/card.json"
CONSOLE_HELM_RELEASE="${CONSOLE_HELM_RELEASE:-kubestellar-console}"

detect_from_helm() {
  command -v helm >/dev/null 2>&1 || return 1
  helm get values "$CONSOLE_HELM_RELEASE" -o json 2>/dev/null \
    | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
    hosts=(d.get("ingress") or {}).get("hosts") or []
    host=hosts[0].get("host") if hosts else ""
    if not host:
        host=(d.get("route") or {}).get("host") or ""
    print(host)
except Exception:
    pass
' 2>/dev/null
}

detect_from_k8s() {
  command -v kubectl >/dev/null 2>&1 || return 1
  {
    kubectl get ingress -A -o jsonpath='{range .items[*]}{.spec.rules[*].host}{"\n"}{end}' 2>/dev/null || true
    kubectl get route -A -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null || true
  } | grep -i 'console' | grep -v '^$' | head -n1
}

origin="${CONSOLE_ORIGIN:-}"
if [ -z "$origin" ]; then
  origin=$(detect_from_helm || true)
fi
if [ -z "$origin" ]; then
  origin=$(detect_from_k8s || true)
fi

if [ -z "$origin" ]; then
  cat >&2 <<EOF
Could not detect the Console origin automatically. Set it explicitly:

  CONSOLE_ORIGIN=https://console.example.com just plugin-card

or install Console with an Ingress/Route whose host contains "console", or set
the Helm value ingress.hosts[0].host on release '${CONSOLE_HELM_RELEASE}'.
The card proxy rejects private IPs, so the origin must be publicly routable.
EOF
  exit 1
fi

# Normalise to scheme://host, defaulting to https for a bare hostname.
if [[ "$origin" != http://* && "$origin" != https://* ]]; then
  origin="https://${origin}"
fi
origin="${origin%/}"
echo "==> Console origin: ${origin}"
CONSOLE_ORIGIN="$origin" python3 "$ROOT/plugins/console/build-card.py"
echo "==> Import this file in Console: Dashboard > Add Card > Card Factory > Import JSON"
echo "    ${CARD}"
