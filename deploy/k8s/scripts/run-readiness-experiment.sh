#!/usr/bin/env bash
# Run locally from the repository root; SSM executes the experiment on the CP.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

main() {
  require_tools
  local control_plane_id results_bucket label result_dir remote_script exit_status
  control_plane_id="$(terraform_output control_plane_instance_id)"
  results_bucket="$(terraform_output experiment_results_bucket_name)"
  label="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  result_dir="${BEACH_READINESS_RESULT_DIR:-$repo_root/deploy/k8s/loadtest/results/readiness}/$label"
  mkdir -p "$result_dir"

  remote_script="$(cat <<'REMOTE'
# Preserve failure evidence through SSM/S3 while reporting the test status below.
set +e
(
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
readonly pod_selector='app.kubernetes.io/name=beach'
readonly slice_selector='kubernetes.io/service-name=beach'
k=(kubectl --request-timeout=5s -n beach)
restore_needed=false

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

snapshot() {
  log "phase=$1"
  "${k[@]}" get deployment beach redis -o wide || return 1
  "${k[@]}" get pods -l "$pod_selector" -o wide || return 1
  "${k[@]}" get endpointslice -l "$slice_selector" -o yaml || return 1
}

read_state() {
  pod_state="$("${k[@]}" get pods -l "$pod_selector" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' | sort)" || return 1
  endpoint_state="$("${k[@]}" get endpointslice -l "$slice_selector" -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{" "}{.conditions.ready}{"\n"}{end}')" || return 1
  # The EndpointSlice API treats an omitted ready condition as true.
  ready_endpoints="$(awk 'NF && $2 != "false" {n++} END {print n+0}' <<< "$endpoint_state")"
}

wait_recovery() {
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    read_state || return 1
    if [[ "$pod_state" == "$baseline_pods" && "$ready_endpoints" == 2 ]]; then
      snapshot after || return 1
      return 0
    fi
    sleep 3
  done
  log 'ERROR: Beach readiness or endpoints did not recover within 120 seconds'
  return 1
}

restore() {
  log "restoring Redis replicas=$original_replicas"
  "${k[@]}" scale deployment/redis --replicas="$original_replicas" || return 1
  "${k[@]}" rollout status deployment/redis --timeout=120s || return 1
  wait_recovery || return 1
  restore_needed=false
  log 'Redis, Beach Pods and ready endpoints recovered'
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$restore_needed" == true ]]; then
    if ! restore; then
      log "ERROR: recovery failed; run: sudo kubectl -n beach scale deployment/redis --replicas=$original_replicas"
      status=1
    fi
  fi
  log "exit_status=$status"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log 'Starting Redis-dependent readiness experiment'
"${k[@]}" version -o yaml
snapshot before
"${k[@]}" get deployment beach redis -o yaml
read -r original_replicas redis_ready < <("${k[@]}" get deployment redis -o jsonpath='{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}')
[[ "$original_replicas" =~ ^[1-9][0-9]*$ && "$redis_ready" == "$original_replicas" ]] || { log 'ERROR: Redis is not ready'; exit 1; }
publish_unready="$("${k[@]}" get service beach -o jsonpath='{.spec.publishNotReadyAddresses}')"
[[ "$publish_unready" != true ]] || { log 'ERROR: Service publishes unready addresses'; exit 1; }
read_state
[[ "$(awk '$2 == "True" {n++} END {print n+0}' <<< "$pod_state")" == 2 && "$(wc -l <<< "$pod_state")" == 2 && "$ready_endpoints" == 2 ]] || { log 'ERROR: expected two ready Beach Pods and endpoints'; exit 1; }
baseline_pods="$pod_state"
expected_unready="${baseline_pods//True/False}"
log "original_redis_replicas=$original_replicas"

restore_needed=true
log 'scaling Redis to zero'
"${k[@]}" scale deployment/redis --replicas=0
failure_observed=false
deadline=$((SECONDS + 90))
while (( SECONDS < deadline )); do
  snapshot during
  read_state
  if [[ "$pod_state" == "$expected_unready" && "$ready_endpoints" == 0 ]]; then
    failure_observed=true
    log 'Both Beach Pods are unready and no ready endpoints remain'
    break
  fi
  sleep 3
done
log "failure_observed=$failure_observed"
if ! restore; then
  exit 1
fi
# Retrieve recent failure logs after restoring service availability.
"${k[@]}" logs -l "$pod_selector" --all-containers --prefix --since=5m || true
[[ "$failure_observed" == true ]] || { log 'FAIL: readiness failure and endpoint exclusion were not observed within 90 seconds'; exit 1; }
log 'PASS: readiness failure, endpoint exclusion and recovery observed'
)
status=$?
printf 'readiness_exit_status=%s\n' "$status"
exit 0
REMOTE
)"

  log "running readiness experiment on $control_plane_id; results: $result_dir"
  # Reuse the existing rollout/* S3 permission for full, untruncated output.
  if ! ssm_run "$control_plane_id" "$remote_script" "$results_bucket" "rollout/readiness/$label" > "$result_dir/remote-output.txt" 2> "$result_dir/ssm-error.txt"; then
    cat "$result_dir/ssm-error.txt" >&2
    fail "SSM execution or output retrieval failed; results: $result_dir"
  fi
  exit_status="$(awk -F= '/^readiness_exit_status=/ {status=$2} END {print status}' "$result_dir/remote-output.txt")"
  [[ "$exit_status" =~ ^[0-9]+$ ]] || fail "experiment status is missing; results: $result_dir"
  [[ "$exit_status" == 0 ]] || fail "readiness experiment failed (exit $exit_status); results: $result_dir"
  log "readiness experiment passed; results: $result_dir"
}

main "$@"
