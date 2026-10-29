#!/usr/bin/env bash
set -Eeuo pipefail
export SSM_COMMAND_TIMEOUT_SECONDS="${SSM_COMMAND_TIMEOUT_SECONDS:-1500}"

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

main() {
  require_tools

  local control_plane_id manifest_dir encoded_kustomization encoded_namespace encoded_postgres encoded_redis
  local dependency_revision
  dependency_revision="$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
  control_plane_id="$(terraform_output control_plane_instance_id)"
  manifest_dir="/tmp/beach-dependencies"
  encoded_kustomization="$(base64 -w0 "$repo_root/deploy/k8s/dependencies/kustomization.yaml")"
  encoded_namespace="$(base64 -w0 "$repo_root/deploy/k8s/dependencies/namespace.yaml")"
  encoded_postgres="$(sed "s/dependency-revision: initial/dependency-revision: $dependency_revision/" "$repo_root/deploy/k8s/dependencies/postgres.yaml" | base64 -w0)"
  encoded_redis="$(sed "s/dependency-revision: initial/dependency-revision: $dependency_revision/" "$repo_root/deploy/k8s/dependencies/redis.yaml" | base64 -w0)"

  log "deploying PostgreSQL and Redis revision $dependency_revision on app workers from $control_plane_id"
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
nodes=()
for dependency in postgres redis; do
  replicas=\"\$(kubectl -n beach get deployment/\$dependency -o jsonpath='{.spec.replicas}{\" \"}{.status.readyReplicas}')\"
  [[ \"\$replicas\" == '1 1' ]] || { echo '[beach-k8s] ERROR: expected one ready replica per dependency' >&2; exit 1; }
  revision=\"\$(kubectl -n beach get deployment/\$dependency -o jsonpath='{.metadata.annotations.deployment\\.kubernetes\\.io/revision}')\"
  hash=\"\$(kubectl -n beach get replicasets -l \"app.kubernetes.io/name=\$dependency\" -o \"jsonpath={.items[?(@.metadata.annotations.deployment\\\\.kubernetes\\\\.io/revision=='\$revision')].metadata.labels.pod-template-hash}\")\"
  [[ -n \"\$hash\" && \"\$hash\" != *[[:space:]]* ]] || { echo '[beach-k8s] ERROR: expected one latest dependency ReplicaSet hash' >&2; exit 1; }
  old_pods=\"\$(kubectl -n beach get pods -l \"app.kubernetes.io/name=\$dependency,pod-template-hash!=\$hash\" -o name)\"
  if [[ -n \"\$old_pods\" ]]; then kubectl -n beach wait --for=delete \$old_pods --timeout=300s; fi
  node=\"\$(kubectl -n beach get pods -l \"app.kubernetes.io/name=\$dependency,pod-template-hash=\$hash,dependency-revision=$dependency_revision\" -o jsonpath='{.items[*].spec.nodeName}')\"
  [[ -n \"\$node\" && \"\$node\" != *[[:space:]]* ]] || { echo '[beach-k8s] ERROR: expected one scheduled dependency Pod' >&2; exit 1; }
  [[ \"\$(kubectl get node \"\$node\" -o jsonpath='{.metadata.labels.node-role}')\" == app ]] || { echo '[beach-k8s] ERROR: dependency must run on an app worker' >&2; exit 1; }
  nodes+=(\"\$node\")
done
[[ \"\${nodes[0]}\" != \"\${nodes[1]}\" ]] || { echo '[beach-k8s] ERROR: dependencies must be on distinct app workers; inspect Pod placement before retrying' >&2; exit 1; }
kubectl -n beach get pods -o wide
"
  log 'PostgreSQL and Redis are ready'
}

main "$@"
