#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly namespace="${BEACH_NAMESPACE:-beach}"
readonly k6_wait_margin_seconds=180

usage() {
  cat <<'EOF'
Usage:
  bash deploy/k8s/scripts/run-load.sh [request-rate] [duration-seconds]

Runs the pinned k6 constant-arrival-rate Job against the Beach Service without
changing the Beach Deployment, then prints the load window and k6 summary.
Defaults: 5 req/s for 300 seconds.
EOF
}

main() {
  require_tools

  local rate="${1:-5}" duration="${2:-300}"
  [[ "$rate" =~ ^[1-9][0-9]*$ ]] || { usage >&2; fail 'request rate must be a positive integer'; }
  [[ "$duration" =~ ^[1-9][0-9]*$ ]] || { usage >&2; fail 'duration must be a positive integer'; }

  local control_plane_id encoded_js encoded_job
  control_plane_id="$(terraform_output control_plane_instance_id)"
  encoded_js="$(base64 -w0 "$repo_root/deploy/k8s/loadtest/rollout.js")"
  encoded_job="$(base64 -w0 "$repo_root/deploy/k8s/loadtest/k6-job.yaml")"

  log "running k6 load on $control_plane_id (${rate} req/s for ${duration}s)"

  # 롤아웃 실험과 같은 k6 Job을 쓰되 Deployment 이미지는 바꾸지 않는다.
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

# --out json 원본은 수만 줄이라 SSM 출력에서 뺀다. 요약 JSON만 남긴다.
k6_pod=\"\$(kubectl -n $namespace get pods -l job-name=beach-k6-rollout -o jsonpath='{.items[0].metadata.name}')\"
kubectl -n $namespace logs \"\$k6_pod\" -c k6 | awk '!/^\\{\"metric\":/'
"

  log 'k6 load completed'
}

main "$@"
