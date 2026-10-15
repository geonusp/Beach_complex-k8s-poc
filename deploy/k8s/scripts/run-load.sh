#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly namespace="${BEACH_NAMESPACE:-beach}"
readonly k6_wait_margin_seconds=180
readonly result_root="${BEACH_LOAD_RESULT_DIR:-$repo_root/deploy/k8s/loadtest/results/load}"

usage() {
  cat <<'EOF'
Usage:
  bash deploy/k8s/scripts/run-load.sh [request-rate] [duration-seconds] [label]

Runs the pinned k6 constant-arrival-rate Job against the Beach Service without
changing the Beach Deployment, then prints the load window and k6 summary.
The full SSM output is saved under deploy/k8s/loadtest/results/load/<label>.
Defaults: 5 req/s for 300 seconds.
EOF
}

main() {
  require_tools

  local rate="${1:-5}" duration="${2:-300}"
  local label="${3:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
  [[ "$rate" =~ ^[1-9][0-9]*$ ]] || { usage >&2; fail 'request rate must be a positive integer'; }
  [[ "$duration" =~ ^[1-9][0-9]*$ ]] || { usage >&2; fail 'duration must be a positive integer'; }

  label="$(printf '%s' "$label" | tr -cd '[:alnum:]_.-')"
  [[ -n "$label" ]] || fail 'result label must contain an alphanumeric character'

  local control_plane_id results_bucket encoded_js encoded_job result_dir
  control_plane_id="$(terraform_output control_plane_instance_id)"
  results_bucket="$(terraform_output experiment_results_bucket_name)"
  encoded_js="$(base64 -w0 "$repo_root/deploy/k8s/loadtest/rollout.js")"
  encoded_job="$(base64 -w0 "$repo_root/deploy/k8s/loadtest/k6-job.yaml")"

  result_dir="$result_root/$label"
  mkdir -p "$result_dir"

  log "running k6 load on $control_plane_id (${rate} req/s for ${duration}s)"

  # 롤아웃 실험과 같은 k6 Job을 쓰되 Deployment 이미지는 바꾸지 않는다.
  # k6 진행 로그와 --out json 원본은 SSM 인라인 출력 한도를 넘기므로 전체 출력은 S3로 받는다.
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
work_dir=\"\$(mktemp -d /tmp/beach-load.XXXXXX)\"
trap 'rm -rf \"\$work_dir\"' EXIT
echo '$encoded_js' | base64 -d > \"\$work_dir/rollout.js\"
echo '$encoded_job' | base64 -d > \"\$work_dir/k6-job.yaml\"
sed -i -e 's/value: \"1\"/value: \"$rate\"/' -e 's/value: \"2m\"/value: \"${duration}s\"/' \"\$work_dir/k6-job.yaml\"

kubectl -n $namespace create configmap beach-k6-rollout --from-file=rollout.js=\"\$work_dir/rollout.js\" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n $namespace delete job/beach-k6-rollout --ignore-not-found
kubectl -n $namespace apply -f \"\$work_dir/k6-job.yaml\"
echo \"load_started=\$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
kubectl -n $namespace wait --for=condition=complete job/beach-k6-rollout --timeout=$((duration + k6_wait_margin_seconds))s
echo \"load_finished=\$(date -u +%Y-%m-%dT%H:%M:%SZ)\"

k6_pod=\"\$(kubectl -n $namespace get pods -l job-name=beach-k6-rollout -o jsonpath='{.items[0].metadata.name}')\"
kubectl -n $namespace logs \"\$k6_pod\" -c k6
" "$results_bucket" "rollout/load/$label" > "$result_dir/remote-output.txt"

  # 터미널에는 부하 구간과 handleSummary 요약 한 줄만 보여준다.
  grep -E '^load_(started|finished)=' "$result_dir/remote-output.txt"
  grep '^{"experiment":' "$result_dir/remote-output.txt" || fail "k6 summary is missing; results: $result_dir"
  log "k6 load completed; results: $result_dir"
}

main "$@"
