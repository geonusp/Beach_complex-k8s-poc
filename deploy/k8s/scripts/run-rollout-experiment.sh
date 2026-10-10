#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly namespace="${BEACH_NAMESPACE:-beach}"
readonly deployment="${BEACH_DEPLOYMENT:-beach}"
readonly rollout_timeout_seconds="${BEACH_ROLLOUT_TIMEOUT_SECONDS:-300}"
readonly request_rate="${BEACH_ROLLOUT_REQUEST_RATE:-1}"
readonly k6_safety_margin_seconds="${BEACH_ROLLOUT_K6_SAFETY_MARGIN_SECONDS:-30}"
readonly result_root="${BEACH_ROLLOUT_RESULT_DIR:-$repo_root/deploy/k8s/loadtest/results}"

usage() {
  cat <<'EOF'
Usage:
  bash deploy/k8s/scripts/run-rollout-experiment.sh <image-a> <image-b> [request-rate] [warmup-seconds] [observe-seconds] [label]

The experiment runs a pinned k6 Job on the observability node, changes the
Beach Deployment from image-a to image-b, records rollout and EndpointSlice
state, then restores image-a before returning.
EOF
}

main() {
  require_tools
  [[ $# -ge 2 ]] || { usage >&2; fail 'two image references are required'; }
  [[ "$rollout_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || fail 'rollout timeout must be a positive integer'

  local image_a="$1" image_b="$2"
  local rate="${3:-$request_rate}" warmup="${4:-30}" observe="${5:-30}"
  local label="${6:-$(date -u +%Y%m%dT%H%M%SZ)}"
  local k6_duration
  [[ "$rate" =~ ^[1-9][0-9]*$ ]] || fail 'request rate must be a positive integer'
  [[ "$warmup" =~ ^[0-9]+$ && "$observe" =~ ^[0-9]+$ ]] || fail 'warmup and observe seconds must be non-negative integers'
  [[ "$k6_safety_margin_seconds" =~ ^[0-9]+$ ]] || fail 'k6 safety margin must be a non-negative integer'
  k6_duration="$((warmup + rollout_timeout_seconds + observe + k6_safety_margin_seconds))s"
  label="$(printf '%s' "$label" | tr -cd '[:alnum:]_.-')"
  [[ -n "$label" ]] || fail 'result label must contain an alphanumeric character'

  local control_plane_id results_bucket encoded_js encoded_job remote_script output result_dir
  control_plane_id="$(terraform_output control_plane_instance_id)"
  results_bucket="$(terraform_output experiment_results_bucket_name)"
  encoded_js="$(base64 -w0 "$repo_root/deploy/k8s/loadtest/rollout.js")"
  encoded_job="$(base64 -w0 "$repo_root/deploy/k8s/loadtest/k6-job.yaml")"
  result_dir="$result_root/$label"
  mkdir -p "$result_dir"

  remote_script="$(cat <<'REMOTE'
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
work_dir="$(mktemp -d /tmp/beach-rollout.XXXXXX)"
restore_needed=false
restore() {
  kubectl -n __NAMESPACE__ set image deployment/__DEPLOYMENT__ beach="__IMAGE_A__" >/dev/null 2>&1 || true
  kubectl -n __NAMESPACE__ rollout status deployment/__DEPLOYMENT__ --timeout=__TIMEOUT__s >/dev/null 2>&1 || true
}
cleanup() {
  if [[ "$restore_needed" == true ]]; then restore; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
echo '__K6_SCRIPT__' | base64 -d > "$work_dir/rollout.js"
echo '__K6_JOB__' | base64 -d > "$work_dir/k6-job.yaml"
sed -i -e 's/value: "1"/value: "__RATE__"/' -e 's/value: "2m"/value: "__DURATION__"/' "$work_dir/k6-job.yaml"

current_image="$(kubectl -n __NAMESPACE__ get deployment/__DEPLOYMENT__ -o jsonpath='{.spec.template.spec.containers[0].image}')"
[[ "$current_image" == '__IMAGE_A__' ]] || { echo "expected image __IMAGE_A__ before experiment, found $current_image" >&2; exit 1; }
ready_replicas="$(kubectl -n __NAMESPACE__ get deployment/__DEPLOYMENT__ -o jsonpath='{.status.readyReplicas}')"
[[ "${ready_replicas:-0}" == '2' ]] || { echo "expected two ready replicas before experiment, found ${ready_replicas:-0}" >&2; exit 1; }

kubectl -n __NAMESPACE__ create configmap beach-k6-rollout --from-file=rollout.js="$work_dir/rollout.js" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n __NAMESPACE__ delete job/beach-k6-rollout --ignore-not-found
kubectl -n __NAMESPACE__ apply -f "$work_dir/k6-job.yaml"
kubectl -n __NAMESPACE__ wait --for=condition=Ready pod -l job-name=beach-k6-rollout --timeout=120s
sleep __WARMUP__

record_endpoints() {
  local phase="$1"
  printf '%s %s ' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" >> "$work_dir/endpoints.log"
  kubectl -n __NAMESPACE__ get endpointslice -l kubernetes.io/service-name=__DEPLOYMENT__ -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}:{.conditions.ready}{"\n"}{end}' | tr '\n' ' ' >> "$work_dir/endpoints.log"
  printf '\n' >> "$work_dir/endpoints.log"
}

record_endpoints before-rollout
rollout_started="$(date +%s)"
restore_needed=true
kubectl -n __NAMESPACE__ set image deployment/__DEPLOYMENT__ beach="__IMAGE_B__"
kubectl -n __NAMESPACE__ rollout status deployment/__DEPLOYMENT__ --timeout=__TIMEOUT__s
rollout_finished="$(date +%s)"
record_endpoints after-rollout
sleep __OBSERVE__
kubectl -n __NAMESPACE__ wait --for=condition=complete job/beach-k6-rollout --timeout="$((__TIMEOUT__ + __WARMUP__ + __OBSERVE__ + 120))s"
k6_pod="$(kubectl -n __NAMESPACE__ get pods -l job-name=beach-k6-rollout -o jsonpath='{.items[0].metadata.name}')"
printf 'rollout_duration_seconds=%s\n' "$((rollout_finished - rollout_started))"
printf 'k6_summary_start\n'
kubectl -n __NAMESPACE__ logs "$k6_pod" -c k6
printf 'k6_summary_end\n'
printf 'endpoint_samples_start\n'
cat "$work_dir/endpoints.log"
printf 'endpoint_samples_end\n'
REMOTE
)"
  remote_script="${remote_script//__K6_SCRIPT__/$encoded_js}"
  remote_script="${remote_script//__K6_JOB__/$encoded_job}"
  remote_script="${remote_script//__NAMESPACE__/$namespace}"
  remote_script="${remote_script//__DEPLOYMENT__/$deployment}"
  remote_script="${remote_script//__IMAGE_A__/$image_a}"
  remote_script="${remote_script//__IMAGE_B__/$image_b}"
  remote_script="${remote_script//__RATE__/$rate}"
  remote_script="${remote_script//__DURATION__/$k6_duration}"
  remote_script="${remote_script//__WARMUP__/$warmup}"
  remote_script="${remote_script//__OBSERVE__/$observe}"
  remote_script="${remote_script//__TIMEOUT__/$rollout_timeout_seconds}"

  log "running rollout experiment on $control_plane_id (rate: ${rate} req/s)"
  output="$(ssm_run "$control_plane_id" "$remote_script" "$results_bucket" "rollout/$label")"
  printf '%s\n' "$output" \
    | awk '/^raw_json_start$/ { capture=1; found_start=1; next } /^raw_json_end$/ { capture=0; found_end=1; next } !capture { print } END { if (!found_start || !found_end) exit 1 }' \
    > "$result_dir/remote-output.txt" \
    || fail 'raw k6 JSON markers are missing from SSM output'
  printf '%s\n' "$output" \
    | awk '/^raw_json_start$/ { capture=1; next } /^raw_json_end$/ { capture=0; next } capture { print }' \
    > "$result_dir/raw.json"
  log "rollout experiment completed; results: $result_dir"
}

main "$@"
