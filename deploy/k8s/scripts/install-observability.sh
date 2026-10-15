#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly kube_prometheus_stack_chart_version="${KUBE_PROMETHEUS_STACK_CHART_VERSION:-91.9.0}"

main() {
  require_tools

  local control_plane_id values_encoded podmonitor_encoded dashboard_encoded
  control_plane_id="$(terraform_output control_plane_instance_id)"
  values_encoded="$(base64 -w0 "$repo_root/deploy/k8s/observability/kube-prometheus-stack-values.yaml")"
  podmonitor_encoded="$(base64 -w0 "$repo_root/deploy/k8s/observability/beach-podmonitor.yaml")"
  dashboard_encoded="$(base64 -w0 "$repo_root/deploy/k8s/observability/dashboards/beach-overview.json")"

  log "installing kube-prometheus-stack chart $kube_prometheus_stack_chart_version on $control_plane_id"

  # Grafana 관리자 비밀번호는 원격에서 한 번만 생성한다. 재실행 때 Secret이 있으면 유지한다.
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config

echo '$values_encoded' | base64 -d > /tmp/kube-prometheus-stack-values.yaml
echo '$podmonitor_encoded' | base64 -d > /tmp/beach-podmonitor.yaml

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  grafana_password=\"\$(head -c 24 /dev/urandom | base64 -w0)\"
  kubectl -n monitoring create secret generic grafana-admin \\
    --from-literal=admin-user=admin \\
    --from-literal=admin-password=\"\$grafana_password\"
  unset grafana_password
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version '$kube_prometheus_stack_chart_version' \
  --namespace monitoring \
  --values /tmp/kube-prometheus-stack-values.yaml \
  --wait --timeout 10m

kubectl apply -f /tmp/beach-podmonitor.yaml

# Grafana dashboard sidecar가 grafana_dashboard=1 라벨 ConfigMap을 읽어 대시보드를 등록한다.
echo '$dashboard_encoded' | base64 -d > /tmp/beach-overview.json
kubectl -n monitoring create configmap beach-dashboards --from-file=beach-overview.json=/tmp/beach-overview.json --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring label configmap beach-dashboards grafana_dashboard=1 --overwrite

kubectl -n monitoring get pods -o wide
"

  log 'kube-prometheus-stack installed'
}

main "$@"
