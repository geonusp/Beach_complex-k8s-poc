#!/usr/bin/env bash
set -Eeuo pipefail

# 클러스터 부트스트랩 진입점. 각 단계는 개별 실행과 재실행이 가능하다.
#
#   terraform apply 로 노드를 만든 뒤 이 스크립트를 실행한다.
#   kubeadm init 은 join 토큰이 control plane 기동 후에만 생성되므로
#   cloud-init 이 아니라 여기에서 수행한다.

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$script_dir/lib/ssm.sh"

main() {
  require_tools python3

  local node_data expected_node_count expected_nodes
  node_data="$(terraform_output_json node_hostnames | python3 -c '
import json, sys
hostnames = json.load(sys.stdin)
print(len(hostnames))
print(" ".join(f"node/{hostname}" for hostname in hostnames.values()))
')"
  expected_node_count="${node_data%%$'\n'*}"
  expected_nodes="${node_data#*$'\n'}"

  log "step 1/4 control plane"
  bash "$script_dir/init-control-plane.sh"

  log "step 2/4 workers"
  bash "$script_dir/join-workers.sh"

  log "step 3/4 cilium"
  bash "$script_dir/install-cilium.sh"

  log "step 4/4 node labels"
  bash "$script_dir/label-nodes.sh"

  log "verifying cluster"
  ssm_run "$(terraform_output control_plane_instance_id)" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
kubectl wait --for=condition=Ready $expected_nodes --timeout=300s
actual_node_count=\"\$(kubectl get nodes --no-headers | wc -l)\"
if [ \"\$actual_node_count\" -ne '$expected_node_count' ]; then
  echo \"expected $expected_node_count nodes, found \$actual_node_count\" >&2
  exit 1
fi
kubectl get nodes -o wide
kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
kubectl -n kube-system get pods -l k8s-app=kube-dns
"

  log "bootstrap completed"
}

main "$@"
