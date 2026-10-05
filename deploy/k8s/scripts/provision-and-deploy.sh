#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/../../.." && pwd)"
readonly terraform_environment="$repo_root/deploy/k8s/terraform/environments/dev"

log() {
  printf '[beach-k8s] %s\n' "$*"
}

fail() {
  printf '[beach-k8s] ERROR: %s\n' "$*" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in bash terraform; do
    command -v "$tool" >/dev/null || fail "$tool is required but not installed"
  done
}

usage() {
  cat <<'EOF'
Usage:
  bash deploy/k8s/scripts/provision-and-deploy.sh
  bash deploy/k8s/scripts/provision-and-deploy.sh --destroy

The default path creates the Terraform infrastructure and deploys the cluster
and Beach application in dependency order. --destroy removes the Terraform
infrastructure after an explicit Terraform confirmation prompt.
EOF
}

provision_and_deploy() {
  log 'step 1/5 terraform apply'
  terraform -chdir="$terraform_environment" apply -auto-approve

  log 'step 2/5 bootstrap kubeadm and Cilium'
  bash "$script_dir/bootstrap-cluster.sh"

  log 'step 3/5 restore GHCR pull secret'
  bash "$script_dir/sync-ghcr-secret.sh"

  log 'step 4/5 deploy PostgreSQL and Redis'
  bash "$script_dir/deploy-dependencies.sh"

  log 'step 5/5 deploy Beach'
  bash "$script_dir/deploy-beach.sh"

  log 'provision and deployment completed'
}

destroy_infrastructure() {
  log 'destroying Terraform infrastructure'
  terraform -chdir="$terraform_environment" destroy
}

main() {
  require_tools

  case "${1:-}" in
    '')
      provision_and_deploy
      ;;
    --destroy)
      destroy_infrastructure
      ;;
    --help|-h)
      usage
      ;;
    *)
      usage >&2
      fail "unknown option: $1"
      ;;
  esac
}

main "$@"
