#!/usr/bin/env bash
# Development cluster only. Force deletion removes the API object, not proof of process exit.
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"
[[ "${1:-}" == --confirm-dev && $# -le 2 ]] || fail 'Usage: run-pod-failure-experiment.sh --confirm-dev [label]; requires an idle dev cluster'
python_bin="${PYTHON:-python3}"
require_tools "$python_bin"
label="${2:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'invalid result label'
result_dir="${BEACH_FAILURE_RESULT_DIR:-$repo_root/deploy/k8s/loadtest/results/issue-6}/$label"
mkdir -p "$(dirname "$result_dir")"
mkdir "$result_dir" || fail 'result label already exists; do not overwrite evidence'
control_plane_id="$(terraform_output control_plane_instance_id)"
results_bucket="$(terraform_output experiment_results_bucket_name)"
bash "$repo_root/deploy/k8s/scripts/verify-observability.sh" > "$result_dir/observability.txt" 2>&1
remote_script="$(cat <<'REMOTE'
set +e
(
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
k=(kubectl --request-timeout=5s -n beach)
job_created=false
injected=false
collector_pid=''
utc() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }
snapshot() {
  "${k[@]}" get pods,deployments,services,endpointslices,nodes -o json > "$work_dir/state.json"
  python3 "$work_dir/failure_results.py" snapshot "$work_dir/state.json"
}
check_state() { python3 "$work_dir/failure_results.py" state "$work_dir/state.json" "$@" | sort; }
finish() {
  status=$?
  trap - EXIT
  if [[ "$injected" == true ]]; then
    echo "recovery_check_started=$(utc)"
    if ! "${k[@]}" rollout status deployment/beach --timeout=120s || ! snapshot || ! check_state "$old_uid" "$survivor_uid"; then
      echo 'ERROR: recovery unverified; inspect: sudo kubectl -n beach describe pods; sudo kubectl -n beach get endpointslice -o yaml'
      status=1
    else
      echo "final_state_verified=$(utc)"
    fi
  fi
  if [[ "$job_created" == true ]]; then
    remaining=$((job_deadline - $(date -u +%s)))
    if ! "${k[@]}" wait --for=condition=complete job/beach-k6-failure --timeout="$((remaining > 0 ? remaining : 1))s"; then status=1; fi
    if [[ -n "$collector_pid" ]]; then
      timeout 10s tail --pid="$collector_pid" -f /dev/null || { kill "$collector_pid" 2>/dev/null || true; status=1; }
      wait "$collector_pid" || status=1
      cat "$work_dir/k6.log" || status=1
    else
      "${k[@]}" logs job/beach-k6-failure -c k6 || status=1
    fi
  fi
  "${k[@]}" get events --sort-by=.metadata.creationTimestamp || true
  echo "remote_work_dir=$work_dir"
  echo 'Preserved Job/ConfigMap: beach-k6-failure; collect logs before deleting them or destroying the cluster.'
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
kubectl version -o yaml
echo "request_rate=5"
snapshot
baseline="$(check_state)"
read -r target old_uid target_node <<< "$(head -n1 <<< "$baseline")"
read -r _ survivor_uid _ <<< "$(tail -n1 <<< "$baseline")"
echo "target=$target uid=$old_uid node=$target_node"
"${k[@]}" create configmap beach-k6-failure --from-file="$work_dir/failure.js"
"${k[@]}" create -f "$work_dir/k6-failure-job.yaml"
job_created=true
job_deadline=$(($(date -u +%s) + 480))
start_deadline=$(($(date -u +%s) + 60))
started=''
while [[ -z "$started" && $(date -u +%s) -lt "$start_deadline" ]]; do
  started="$("${k[@]}" logs job/beach-k6-failure -c k6 2>/dev/null | python3 "$work_dir/failure_results.py" started)" || true
  [[ -n "$started" ]] || sleep 2
done
[[ -n "$started" ]] || { echo 'ERROR: k6 did not send requests'; exit 1; }
echo "load_started=$started"
# Stream continuously to the CP file so kubelet log rotation cannot discard early raw samples.
kubectl -n beach logs --follow --request-timeout=0 job/beach-k6-failure -c k6 > "$work_dir/k6.log" 2>&1 &
collector_pid=$!
baseline_end=$(($(date -u -d "$started" +%s) + 121))
while [[ $(date -u +%s) -lt "$baseline_end" ]]; do snapshot; sleep 2; done
snapshot
[[ "$(check_state)" == "$baseline" ]] || { echo 'ERROR: baseline Pod identities changed'; exit 1; }
{ echo 'request_rate=5'; cat "$work_dir/k6.log"; } | python3 "$work_dir/failure_results.py" baseline "$(utc)"
python3 -c 'import json,sys; json.dump({"apiVersion":"v1","kind":"DeleteOptions","gracePeriodSeconds":0,"preconditions":{"uid":sys.argv[1]}},open(sys.argv[2],"w"))' "$old_uid" "$work_dir/delete.json"
injected=true
echo "t0=$(utc)"
"${k[@]}" delete --raw "/api/v1/namespaces/beach/pods/$target" -f "$work_dir/delete.json"
deadline=$(($(date -u +%s) + 180))
recovered=false
while [[ $(date -u +%s) -lt "$deadline" ]]; do
  snapshot
  if check_state "$old_uid" "$survivor_uid"; then
    echo "replacement_ready=$(utc)"
    recovered=true
    break
  fi
  sleep 2
done
[[ "$recovered" == true ]] || { echo 'ERROR: replacement or endpoints did not recover within 180s'; exit 1; }
# Continue state observations throughout the load; a later regression must fail the run.
while [[ $(date -u +%s) -lt "$job_deadline" ]]; do
  snapshot
  check_state "$old_uid" "$survivor_uid"
  [[ "$("${k[@]}" get job beach-k6-failure -o jsonpath='{.status.succeeded}')" != 1 ]] || break
  sleep 2
done
) 2>&1
status=$?
printf 'experiment_exit_status=%s\n' "$status"
exit 0
REMOTE
)"
payload="work_dir=\"\$(mktemp -d /tmp/beach-failure.XXXXXX)\""$'\n'
for file in loadtest/failure.js loadtest/k6-failure-job.yaml scripts/failure_results.py; do
  payload+="echo '$(base64 -w0 "$repo_root/deploy/k8s/$file")' | base64 -d > \"\$work_dir/${file##*/}\""$'\n'
done
log "running Pod failure experiment on $control_plane_id; results: $result_dir"
if ! ssm_run "$control_plane_id" "$payload"$'\n'"$remote_script" "$results_bucket" "rollout/issue-6/$label" > "$result_dir/remote-output.txt" 2> "$result_dir/ssm-error.txt"; then
  fail "SSM execution/retrieval failed; inspect $result_dir and S3 rollout/issue-6/$label before retrying"
fi
"$python_bin" "$repo_root/deploy/k8s/scripts/failure_results.py" summarize "$result_dir/remote-output.txt" > "$result_dir/phases.json" || fail "experiment incomplete; preserved evidence: $result_dir"
log "Pod replacement and API recovery verified; results: $result_dir"
