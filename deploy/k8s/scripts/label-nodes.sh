#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

# 라벨은 join이 끝난 뒤 control plane에서 붙인다. NodeRestriction admission plugin이
# kubelet의 node-role.kubernetes.io/* 자가 설정을 거부하기 때문이다.
#
# 노드마다 라벨을 두 개 부여한다.
#   node-role.kubernetes.io/<role>=""  kubectl get nodes의 ROLES 컬럼 표시용
#   node-role=<role>                   매니페스트의 nodeSelector 키
main() {
  require_tools python3

  local control_plane_id hostnames roles script
  control_plane_id="$(terraform_output control_plane_instance_id)"
  hostnames="$(terraform_output_json node_hostnames)"
  roles="$(terraform_output_json node_roles)"

  script="$(printf '%s\n%s' "$hostnames" "$roles" | python3 -c '
import json, sys
hostnames = json.loads(sys.stdin.readline())
roles = json.loads(sys.stdin.readline())
print("set -Eeuo pipefail")
print("export KUBECONFIG=/root/.kube/config")
for key, hostname in hostnames.items():
    role = roles[key]
    # control plane의 role 라벨은 kubeadm이 이미 붙인다.
    if role == "control-plane":
        continue
    print(f"kubectl label node {hostname} node-role.kubernetes.io/{role}= --overwrite")
    print(f"kubectl label node {hostname} node-role={role} --overwrite")
print("kubectl get nodes -o wide")
')"

  log "labelling nodes from $control_plane_id"
  ssm_run "$control_plane_id" "$script"
  log "nodes labelled"
}

main "$@"
