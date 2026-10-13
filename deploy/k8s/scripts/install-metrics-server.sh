#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly metrics_server_chart_version="${METRICS_SERVER_CHART_VERSION:-3.14.0}"

# 차트 기본 args의 --kubelet-preferred-address-types는 InternalIP가 먼저다.
# 노드 hostname은 VPC DNS로 풀리지 않으므로 이 순서를 유지한다.
main() {
  require_tools

  local control_plane_id values_encoded
  control_plane_id="$(terraform_output control_plane_instance_id)"
  values_encoded="$(base64 -w0 "$repo_root/deploy/k8s/metrics-server/values.yaml")"

  log "installing metrics-server chart $metrics_server_chart_version on $control_plane_id"

  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config

echo '$values_encoded' | base64 -d > /tmp/metrics-server-values.yaml

helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server \
  --version '$metrics_server_chart_version' \
  --namespace kube-system \
  --values /tmp/metrics-server-values.yaml

kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s
kubectl wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=300s
"

  log 'metrics-server installed'
}

main "$@"
