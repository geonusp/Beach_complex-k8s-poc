#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

# Cilium values.yaml의 clusterPoolIPv4PodCIDRList와 반드시 같은 값이어야 한다.
readonly pod_network_cidr="${POD_NETWORK_CIDR:-10.244.0.0/16}"

main() {
  require_tools

  local control_plane_id control_plane_ip
  control_plane_id="$(terraform_output control_plane_instance_id)"
  control_plane_ip="$(terraform_output control_plane_private_ip)"

  log "initialising control plane on $control_plane_id ($control_plane_ip)"

  ssm_run "$control_plane_id" "
set -Eeuo pipefail

if [ -f /etc/kubernetes/admin.conf ]; then
  echo 'control plane is already initialised, skipping kubeadm init'
  exit 0
fi

kubeadm init \
  --node-name \"\$(hostnamectl --static)\" \
  --apiserver-advertise-address '$control_plane_ip' \
  --pod-network-cidr '$pod_network_cidr'

install -d -m 0700 /root/.kube
install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
kubectl --kubeconfig /root/.kube/config get nodes
"

  log "control plane initialised"
}

main "$@"
