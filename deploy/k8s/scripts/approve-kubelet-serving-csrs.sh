#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly csr_timeout_seconds="${KUBELET_CSR_TIMEOUT_SECONDS:-300}"
readonly csr_poll_interval_seconds="${KUBELET_CSR_POLL_INTERVAL_SECONDS:-5}"

# kubelet-serving CSR은 자동 승인되지 않는다. Terraform이 만든 노드 이름으로
# 요청한 kubelet-serving CSR만 승인하고, 다른 signer나 모르는 요청자는 건드리지 않는다.
main() {
  require_tools python3

  local control_plane_id expected_nodes
  control_plane_id="$(terraform_output control_plane_instance_id)"
  expected_nodes="$(terraform_output_json node_hostnames | python3 -c '
import json, sys
print(" ".join(json.load(sys.stdin).values()))
')"

  log "approving kubelet serving certificates for: $expected_nodes"
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config

deadline=\$((SECONDS + $csr_timeout_seconds))
while true; do
  missing=''
  for node in $expected_nodes; do
    issued=''
    while read -r name signer user condition; do
      [ \"\$signer\" = 'kubernetes.io/kubelet-serving' ] || continue
      [ \"\$user\" = \"system:node:\$node\" ] || continue
      case \"\$condition\" in
        Approved) issued=yes ;;
        '<none>') kubectl certificate approve \"\$name\"; issued=yes ;;
      esac
    done < <(kubectl get csr --no-headers -o 'custom-columns=NAME:.metadata.name,SIGNER:.spec.signerName,USER:.spec.username,CONDITION:.status.conditions[0].type')
    # 승인된 CSR은 1시간 뒤 삭제된다. 재실행 때는 kubelet이 이미 클러스터 CA 인증서를 쓰는지 직접 확인한다.
    if [ -z \"\$issued\" ]; then
      address=\"\$(kubectl get node \"\$node\" -o 'jsonpath={.status.addresses[?(@.type==\"InternalIP\")].address}' 2>/dev/null || true)\"
      if [ -n \"\$address\" ] && timeout 10 openssl s_client -connect \"\$address:10250\" -CAfile /etc/kubernetes/pki/ca.crt -verify_return_error </dev/null >/dev/null 2>&1; then
        issued=yes
      fi
    fi
    [ -n \"\$issued\" ] || missing=\"\$missing \$node\"
  done
  [ -n \"\$missing\" ] || break
  if [ \"\$SECONDS\" -ge \"\$deadline\" ]; then
    echo \"kubelet serving CSR not found for:\$missing\" >&2
    exit 1
  fi
  sleep $csr_poll_interval_seconds
done
kubectl get csr
"

  log 'kubelet serving certificates approved'
}

main "$@"
