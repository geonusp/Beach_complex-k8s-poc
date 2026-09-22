#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

# Cilium v1.20.2가 e2e 테스트하는 Kubernetes는 1.33~1.36이다. 버전을 올릴 때는
# 호환성 표를 먼저 확인하고 kubernetes_version과 함께 조정한다.
readonly cilium_version="${CILIUM_VERSION:-1.20.2}"

main() {
  require_tools

  local control_plane_id values_encoded
  control_plane_id="$(terraform_output control_plane_instance_id)"
  values_encoded="$(base64 -w0 "$repo_root/deploy/k8s/cilium/values.yaml")"

  log "installing cilium $cilium_version on $control_plane_id"

  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config

if kubectl -n kube-system get daemonset cilium >/dev/null 2>&1; then
  echo 'cilium is already installed, skipping'
  exit 0
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo '$values_encoded' | base64 -d > /tmp/cilium-values.yaml

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update
helm install cilium cilium/cilium \
  --version '$cilium_version' \
  --namespace kube-system \
  --values /tmp/cilium-values.yaml

kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
"

  log "cilium installed"
}

main "$@"
