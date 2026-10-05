#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

main() {
  require_tools

  local control_plane_id manifest_dir encoded_kustomization encoded_namespace encoded_postgres encoded_redis
  control_plane_id="$(terraform_output control_plane_instance_id)"
  manifest_dir="/tmp/beach-dependencies"
  encoded_kustomization="$(base64 -w0 "$repo_root/deploy/k8s/dependencies/kustomization.yaml")"
  encoded_namespace="$(base64 -w0 "$repo_root/deploy/k8s/dependencies/namespace.yaml")"
  encoded_postgres="$(base64 -w0 "$repo_root/deploy/k8s/dependencies/postgres.yaml")"
  encoded_redis="$(base64 -w0 "$repo_root/deploy/k8s/dependencies/redis.yaml")"

  log "deploying PostgreSQL and Redis on app workers from $control_plane_id"
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
install -d '$manifest_dir'
echo '$encoded_kustomization' | base64 -d > '$manifest_dir/kustomization.yaml'
echo '$encoded_namespace' | base64 -d > '$manifest_dir/namespace.yaml'
echo '$encoded_postgres' | base64 -d > '$manifest_dir/postgres.yaml'
echo '$encoded_redis' | base64 -d > '$manifest_dir/redis.yaml'
kubectl apply -k '$manifest_dir'
kubectl -n beach rollout status deployment/postgres --timeout=300s
kubectl -n beach rollout status deployment/redis --timeout=300s
kubectl -n beach get pods -o wide
"
  log 'PostgreSQL and Redis are ready'
}

main "$@"
