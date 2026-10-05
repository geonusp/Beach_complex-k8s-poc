#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

main() {
  require_tools python3

  local control_plane_id join_command
  control_plane_id="$(terraform_output control_plane_instance_id)"

  # join 토큰은 기본적으로 24시간 후 만료된다. 재생성할 때마다 새로 발급한다.
  log "creating a fresh join token on the control plane"
  join_command="$(ssm_run "$control_plane_id" 'set -Eeuo pipefail
kubeadm token create --print-join-command' | tr -d '\r' | grep '^kubeadm join')"

  local worker_ids
  worker_ids="$(terraform_output_json worker_instance_ids)"

  local key instance_id
  while IFS=$'\t' read -r key instance_id; do
    [ -n "$instance_id" ] || continue
    log "joining $key ($instance_id)"
    ssm_run "$instance_id" "
set -Eeuo pipefail

if [ -f /etc/kubernetes/kubelet.conf ]; then
  echo 'node is already joined, skipping kubeadm join'
  exit 0
fi

$join_command --node-name \"\$(hostnamectl --static)\"
"
  done < <(printf '%s' "$worker_ids" | python3 -c '
import json, sys
for key, value in json.load(sys.stdin).items():
    print(f"{key}\t{value}")
')

  log "all workers joined"
}

main "$@"
