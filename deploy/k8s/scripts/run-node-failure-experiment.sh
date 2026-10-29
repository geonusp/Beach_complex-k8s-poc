#!/usr/bin/env bash
# Idle dev cluster only; AWS stop includes OS shutdown, not physical power loss.
set -Eeuo pipefail
export SSM_COMMAND_TIMEOUT_SECONDS=1500
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/ssm.sh"
[[ $# -ge 2 && $# -le 3 && "$1" == --confirm-dev ]] || fail 'Usage: run-node-failure-experiment.sh --confirm-dev <Terraform-app-key> [label]'
key="$2"; label="${3:-node-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'invalid result label'
python_bin="${PYTHON:-python3}"
require_tools "$python_bin"
result_dir="${BEACH_NODE_RESULT_DIR:-$repo_root/deploy/k8s/loadtest/results/issue-6}/$label"
mkdir -p "$(dirname "$result_dir")"
mkdir "$result_dir" || fail 'result label exists; preserve previous evidence'
cp_id="$(terraform_output control_plane_instance_id)"
bucket="$(terraform_output experiment_results_bucket_name)"
for output in node_instance_ids node_hostnames node_roles node_private_ips; do terraform_output_json "$output" > "$result_dir/$output.json"; done
"$python_bin" "$script_dir/node_failure_results.py" target "$result_dir" "$key" "$cp_id" > "$result_dir/context.json"
read -r instance node <<< "$("$python_bin" -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["instance"],c["node"])' "$result_dir/context.json")"
aws ec2 describe-instances --instance-ids "$instance" > "$result_dir/aws-before.json"
"$python_bin" "$script_dir/node_failure_results.py" aws "$result_dir"
for action in stop-instances start-instances; do
  aws ec2 "$action" --instance-ids "$instance" --dry-run > "$result_dir/$action-permission.txt" 2>&1 && fail 'unexpected dry-run success'
  grep -q DryRunOperation "$result_dir/$action-permission.txt" || fail "missing $action permission"
done
bash "$script_dir/verify-observability.sh" > "$result_dir/observability.txt" 2>&1
work_dir="/tmp/beach-node-$label-$$-$RANDOM"
utc() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }
remote_common="export KUBECONFIG=/root/.kube/config; work_dir='$work_dir'"
remote_common+=$'\n''snapshot() { kubectl --request-timeout=5s -n beach get pods,deployments,services,endpointslices,nodes -o json > "$work_dir/state.json"; python3 "$work_dir/node_failure_results.py" snapshot "$work_dir"; }'
remote_common+=$'\n''db() { kubectl --request-timeout=5s -n beach exec deployment/postgres -- psql -U beach -d beach_complex -Atc "SELECT md5(COALESCE(string_agg(row_to_json(b)::text, '\'' '\'' ORDER BY id), '\'''\'')) FROM beaches b"; }'
remote_common+=$'\n''api() { ip=$(kubectl -n beach get service beach -o jsonpath="{.spec.clusterIP}"); curl --max-time 5 -fsS "http://$ip/api/beaches" > "$work_dir/api.json"; }'
stop_possible=false; observer_pid=''
finish() {
  status=$?; trap - EXIT; set +e
  if [[ "$stop_possible" == true ]]; then
    echo "restart_requested=$(utc)" >> "$result_dir/local-marks.txt"
    state="$(aws ec2 describe-instances --instance-ids "$instance" --query 'Reservations[0].Instances[0].State.Name' --output text)"
    state="${state//$'\r'/}"
    if [[ "$state" != running ]]; then
      if [[ "$state" == stopping ]]; then aws ec2 wait instance-stopped --instance-ids "$instance" || status=1; fi
      aws ec2 start-instances --instance-ids "$instance" > "$result_dir/aws-start.json" 2> "$result_dir/restart-error.txt" || status=1
    fi
    aws ec2 wait instance-running --instance-ids "$instance" || status=1
    final_script="$(cat <<'FINAL'
# phase=final
set -Eeuo pipefail
touch "$work_dir/abort"
deadline=$((SECONDS + 300))
db_baseline="$work_dir/db-before.txt"
[[ ! -f "$work_dir/db-recovered.txt" ]] || db_baseline="$work_dir/db-recovered.txt"
while ((SECONDS < deadline)); do
  if snapshot && python3 "$work_dir/node_failure_results.py" final "$work_dir" && db > "$work_dir/db-final.txt" && cmp -s "$db_baseline" "$work_dir/db-final.txt" && api; then
    cat "$work_dir/state.json"
    echo "final_state_verified=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    exit 0
  fi
  sleep 5
done
kubectl -n beach get events --sort-by=.metadata.creationTimestamp
echo 'ERROR: final Node/workload/API/data recovery unverified'; exit 1
FINAL
)"
    (ssm_run "$cp_id" "$remote_common"$'\n'"$final_script" "$bucket" "rollout/issue-6/$label/final") > "$result_dir/final.txt" 2> "$result_dir/final-error.txt" || status=1
    [[ -z "$observer_pid" ]] || wait "$observer_pid" || status=1
    cat "$result_dir/local-marks.txt" "$result_dir/final.txt" >> "$result_dir/remote-output.txt"
    echo "experiment_exit_status=$status" >> "$result_dir/remote-output.txt"
    "$python_bin" "$script_dir/node_failure_results.py" summarize "$result_dir" > "$result_dir/phases.json" 2> "$result_dir/summary-error.txt" || status=1
    if ((status == 0)); then log "Node relocation and final recovery verified; results: $result_dir"; else
      log "ERROR: experiment/recovery unverified; inspect $result_dir; remote evidence: $work_dir and s3://$bucket/rollout/issue-6/$label/"
      log "Manual recovery: aws ec2 start-instances --instance-ids $instance"
      log "Then verify Node $node, beach workloads, endpoints and API; a start request is not recovery proof."
    fi
  elif [[ -n "$observer_pid" ]]; then
    (ssm_run "$cp_id" "$remote_common"$'\n''touch "$work_dir/abort"') > "$result_dir/abort.txt" 2>&1 || true
    wait "$observer_pid" || true
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
payload=$'set -Eeuo pipefail\n'"$remote_common"$'\n'"mkdir '$work_dir'"$'\n'
for file in "$script_dir/failure_results.py" "$script_dir/node_failure_results.py" "$script_dir/../loadtest/failure.js" "$script_dir/../loadtest/k6-failure-job.yaml" "$result_dir/context.json"; do
  payload+="echo '$(base64 -w0 "$file")' | base64 -d > '$work_dir/${file##*/}'"$'\n'
done
remote_script="$(cat <<'REMOTE'
# phase=observe
set +e
(
set -Eeuo pipefail
job="beach-node-$(date -u +%s)-$$"
collector=''; job_created=false
finish_remote() {
  result=$?; trap - EXIT; set +e
  [[ -z "$collector" ]] || { kill "$collector" 2>/dev/null; wait "$collector" 2>/dev/null; }
  cat "$work_dir/k6.log"
  if [[ "$job_created" == true ]]; then kubectl --request-timeout=5s -n beach delete job "$job" --ignore-not-found --wait=false || result=1; fi
  kubectl get events -A --sort-by=.metadata.creationTimestamp
  echo "remote_status=$result"
  exit "$result"
}
trap finish_remote EXIT
snapshot
kubectl --request-timeout=5s get pods -A -o json > "$work_dir/all-pods.json"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p+"/state.json")); d["all_pods"]=json.load(open(p+"/all-pods.json"))["items"]; json.dump(d,open(p+"/state.json","w"))' "$work_dir"
python3 "$work_dir/node_failure_results.py" preflight "$work_dir"
cp "$work_dir/state.json" "$work_dir/before.json"
db > "$work_dir/db-before.txt"; api
kubectl -n beach create configmap "$job" --from-file="$work_dir/failure.js"
sed -e "s/beach-k6-failure/$job/g" -e 's/420s/1260s/' "$work_dir/k6-failure-job.yaml" > "$work_dir/job.yaml"
job_created=true; kubectl -n beach create -f "$work_dir/job.yaml"
kubectl -n beach wait --for=condition=Ready pod -l "job-name=$job" --timeout=90s
kubectl -n beach logs --follow --request-timeout=0 "job/$job" -c k6 > "$work_dir/k6.log" 2>&1 &
collector=$!; deadline=$((SECONDS + 180)); started=''
while [[ -z "$started" && $SECONDS -lt $deadline ]]; do
  started="$(python3 "$work_dir/failure_results.py" started < "$work_dir/k6.log")"; sleep 2
done
[[ -n "$started" ]] || { echo 'ERROR: no k6 samples'; exit 1; }
deadline=$(($(date -u -d "$started" +%s) + 121))
while [[ $(date -u +%s) -lt $deadline ]]; do [[ ! -f "$work_dir/abort" ]] || exit 1; snapshot; sleep 5; done
{ echo request_rate=5; cat "$work_dir/k6.log"; } | python3 "$work_dir/failure_results.py" baseline "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
snapshot
python3 "$work_dir/failure_results.py" state "$work_dir/state.json" > "$work_dir/identities-now.txt"
python3 "$work_dir/failure_results.py" state "$work_dir/before.json" > "$work_dir/identities-before.txt"
cmp "$work_dir/identities-now.txt" "$work_dir/identities-before.txt"
touch "$work_dir/ready"; deadline=$((SECONDS + 900)); echo "observation_deadline=$(date -u -d '+900 seconds' +%Y-%m-%dT%H:%M:%SZ)"; restored=false
while ((SECONDS < deadline)); do
  [[ ! -f "$work_dir/abort" ]] || exit 1
  snapshot
  if [[ -f "$work_dir/inject" ]] && python3 "$work_dir/node_failure_results.py" observe "$work_dir"; then
    db > "$work_dir/db-current.txt"
    if [[ "$restored" == false ]]; then
      python3 "$work_dir/node_failure_results.py" database "$work_dir"
      cp "$work_dir/db-current.txt" "$work_dir/db-recovered.txt"
    else
      cmp "$work_dir/db-recovered.txt" "$work_dir/db-current.txt" || { echo 'ERROR: database contents changed after relocation' >&2; exit 1; }
    fi
    restored=true
  elif [[ "$restored" == true ]]; then echo 'ERROR: recovery regressed'; exit 1; fi
  if [[ "$(kubectl -n beach get job "$job" -o jsonpath='{.status.succeeded}')" == 1 ]]; then
    [[ "$restored" == true ]] || exit 1
    break
  fi
  sleep 5
done
[[ "$restored" == true ]] || { echo 'ERROR: no relocation while worker stopped'; exit 1; }
echo request_rate=5
) 2>&1
echo "remote_status=$?"
exit 0
REMOTE
)"
ssm_run "$cp_id" "$payload"$'\n'"$remote_script" "$bucket" "rollout/issue-6/$label/observe" > "$result_dir/remote-output.txt" 2> "$result_dir/ssm-error.txt" &
observer_pid=$!; deadline=$((SECONDS + 300)); gate=''
while ((SECONDS < deadline)); do
  gate="$(ssm_run "$cp_id" "$remote_common"$'\n''# phase=gate'$'\n''if test -f "$work_dir/ready"; then echo ready; else echo waiting; fi')"
  gate="${gate//$'\r'/}"
  [[ "$gate" != ready ]] || break
  kill -0 "$observer_pid" 2>/dev/null || fail 'observer failed before baseline; inspect preserved results'
  sleep 5
done
[[ "$gate" == ready ]] || fail 'baseline was not verified; no EC2 stop issued'
ssm_run "$cp_id" "$remote_common"$'\n''# phase=inject'$'\n''touch "$work_dir/inject"' > "$result_dir/injection-gate.txt"
stop_possible=true
echo "t0=$(utc)" > "$result_dir/local-marks.txt"
log "stopping validated app worker $node ($instance); results: $result_dir"
aws ec2 stop-instances --instance-ids "$instance" > "$result_dir/aws-stop.json" 2> "$result_dir/stop-error.txt"
aws ec2 wait instance-stopped --instance-ids "$instance"
aws ec2 describe-instances --instance-ids "$instance" > "$result_dir/aws-stopped.json"
wait "$observer_pid"
[[ "$(awk -F= '/^remote_status=/{s=$2} END{print s}' "$result_dir/remote-output.txt" | tr -d '\r')" == 0 ]] || fail 'remote observation failed; restoring worker'
log 'observation ended; restoring same EC2 and verifying final state'
