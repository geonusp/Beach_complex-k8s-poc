#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

readonly terraform_dir="deploy/k8s/terraform"
readonly terraform_environment="$terraform_dir/environments/dev"

validate_terraform() {
  terraform fmt -check -recursive "$terraform_dir"
  terraform -chdir="$terraform_environment" init \
    -backend=false \
    -input=false \
    -lockfile=readonly \
    -no-color
  terraform -chdir="$terraform_environment" validate -no-color
}

main() {
  validate_terraform

  printf 'PASS Kubernetes IaC validation\n'
}

main "$@"
