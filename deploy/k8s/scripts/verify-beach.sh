#!/usr/bin/env bash
set -Eeuo pipefail

readonly namespace="${BEACH_NAMESPACE:-beach}"
readonly deployment="${BEACH_DEPLOYMENT:-beach}"
readonly selector="app.kubernetes.io/name=beach,app.kubernetes.io/component=backend"
readonly external_path="${BEACH_EXTERNAL_PATH:-/api/beaches}"

log() {
  printf '[beach-k8s] %s\n' "$*"
}

fail() {
  printf '[beach-k8s] ERROR: %s\n' "$*" >&2
  exit 1
}

require_tools() {
  command -v kubectl >/dev/null || fail 'kubectl is required but not installed'
}

main() {
  require_tools

  log "waiting for deployment/$deployment"
  kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout=300s

  local ready_replicas
  ready_replicas="$(kubectl -n "$namespace" get "deployment/$deployment" -o jsonpath='{.status.readyReplicas}')"
  [[ "$ready_replicas" == "2" ]] || fail "expected 2 ready replicas, found ${ready_replicas:-0}"

  local distinct_nodes
  distinct_nodes="$(kubectl -n "$namespace" get pods -l "$selector" \
    -o custom-columns='NODE:.spec.nodeName' --no-headers | awk 'NF { print $1 }' | sort -u | wc -l | tr -d ' ')"
  [[ "$distinct_nodes" == "2" ]] || fail "expected replicas on 2 distinct nodes, found $distinct_nodes"

  kubectl -n "$namespace" get endpoints "$deployment" -o jsonpath='{.subsets[*].addresses[*].ip}' | grep -q '[0-9]' \
    || fail 'Service has no ready endpoints'
  kubectl -n "$namespace" get ingress "$deployment" >/dev/null \
    || fail "ingress/$deployment does not exist"

  if [[ -n "${BEACH_URL:-}" ]]; then
    curl --fail --silent --show-error --max-time 10 "$BEACH_URL$external_path" >/dev/null \
      || fail "external health check failed: $BEACH_URL"
  fi

  kubectl -n "$namespace" get pods -l "$selector" -o wide
  log 'Beach deployment verification completed'
}

main "$@"
