#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."

validation_dir="$(mktemp -d)"
readonly validation_dir
readonly terraform_dir="deploy/k8s/terraform"
readonly terraform_environment="$terraform_dir/environments/dev"
# terraform console loads every required root variable before evaluating an expression.
# Use the committed non-secret values as a deterministic CI fixture.
readonly terraform_fixture="terraform.tfvars.example"
readonly rendered_dir="$validation_dir/rendered"
readonly user_data_limit_bytes=16384
trap 'rm -rf "$validation_dir"' EXIT

evaluate_terraform_expression() {
  local output_file="$1"

  # terraform console evaluates non-interactive input one expression per line.
  # Keep the HCL readable below, then collapse it into one expression here.
  tr '\n' ' ' \
    | terraform -chdir="$terraform_environment" console \
      -var-file="$terraform_fixture" \
      > "$output_file"
}

decode_console_base64() {
  local input_file="$1"
  local output_file="$2"

  # Console wraps string results in quotes; quotes and newlines are not Base64 characters.
  tr -d '"\r\n' < "$input_file" | base64 --decode > "$output_file"
}

validate_terraform() {
  terraform fmt -check -recursive "$terraform_dir"
  terraform -chdir="$terraform_environment" init \
    -backend=false \
    -input=false \
    -lockfile=readonly \
    -no-color
  terraform -chdir="$terraform_environment" validate -no-color
}

render_cloud_init() {
  evaluate_terraform_expression "$rendered_dir/cloud-init.b64gzip" <<'HCL'
base64gzip(templatefile("${path.module}/../../modules/k8s_node/cloud-init.yml.tftpl", {
  node_hostname      = "beach-complex-cp-1",
  kubernetes_version = var.kubernetes_version
}))
HCL

  decode_console_base64 \
    "$rendered_dir/cloud-init.b64gzip" \
    "$rendered_dir/cloud-init.yml.gz"
  gzip --decompress --stdout "$rendered_dir/cloud-init.yml.gz" \
    > "$rendered_dir/cloud-init.yml"
}

validate_cloud_init() {
  local user_data_bytes

  cloud-init schema -c "$rendered_dir/cloud-init.yml"
  user_data_bytes="$(wc -c < "$rendered_dir/cloud-init.yml.gz")"
  test "$user_data_bytes" -le "$user_data_limit_bytes"

  printf 'PASS EC2 user data size (%s/%s bytes)\n' \
    "$user_data_bytes" \
    "$user_data_limit_bytes"
}

main() {
  mkdir -p "$rendered_dir"

  validate_terraform
  render_cloud_init
  validate_cloud_init

  printf 'PASS Kubernetes IaC validation\n'
}

main "$@"
