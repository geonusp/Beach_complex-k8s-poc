#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly namespace="${BEACH_NAMESPACE:-beach}"
readonly secret_name="${GHCR_SECRET_NAME:-ghcr-pull}"
readonly ghcr_username="${GHCR_USERNAME:-}"
readonly ghcr_parameter_name="${GHCR_TOKEN_PARAMETER_NAME:-/beach/dev/ghcr/token}"

main() {
  require_tools
  [[ -n "$ghcr_username" ]] || fail 'GHCR_USERNAME is required'

  local control_plane_id
  control_plane_id="$(terraform_output control_plane_instance_id)"

  log "rehydrating $secret_name from SSM on $control_plane_id"
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config

if ! command -v aws >/dev/null 2>&1; then
  apt-get -o DPkg::Lock::Timeout=300 update
  apt-get -o DPkg::Lock::Timeout=300 install --yes awscli
fi

ghcr_token=\"\$(aws ssm get-parameter \\
  --name '$ghcr_parameter_name' \\
  --with-decryption \\
  --query 'Parameter.Value' \\
  --output text)\"
[[ -n \"\$ghcr_token\" && \"\$ghcr_token\" != 'None' ]] || {
  echo 'GHCR token parameter is empty' >&2
  exit 1
}

kubectl get namespace '$namespace' >/dev/null 2>&1 || kubectl create namespace '$namespace'
kubectl create secret docker-registry '$secret_name' \\
  --namespace '$namespace' \\
  --docker-server=ghcr.io \\
  --docker-username='$ghcr_username' \\
  --docker-password=\"\$ghcr_token\" \\
  --dry-run=client -o yaml | kubectl apply -f -
unset ghcr_token
"
  log "$secret_name is ready"
}

main "$@"
