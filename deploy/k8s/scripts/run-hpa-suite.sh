#!/usr/bin/env bash
# Run only against an idle development cluster. Each runner verifies recovery.
set -Eeuo pipefail
[[ $# == 1 && "$1" == --confirm-dev ]] || { echo 'Usage: run-hpa-suite.sh --confirm-dev' >&2; exit 1; }
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run() {
  printf '[beach-k8s] %s starting %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
  if ! bash "$script_dir/run-hpa-experiment.sh" --confirm-dev "$1"; then
    printf '[beach-k8s] ERROR: %s failed; inspect preserved results and recovery before retrying\n' "$1" >&2
    exit 1
  fi
  printf '[beach-k8s] %s passed\n' "$1"
}
run smoke
run baseline
echo '[beach-k8s] Review smoke raw counts/log size and baseline CPU/memory. Review and deploy measured requests, then verify rollout, endpoints and API.'
read -r -p 'Type continue after completing these checks: ' answer || exit 1
[[ "$answer" == continue ]] || { echo '[beach-k8s] Stopped before load; results preserved'; exit 1; }
run baseline
run load
run stress
echo '[beach-k8s] HPA suite passed; inspect results and repeat under the same conditions to assess variance'
