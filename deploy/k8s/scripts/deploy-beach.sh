#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

readonly deploy_timeout_seconds="${BEACH_DEPLOY_TIMEOUT_SECONDS:-180}"

main() {
  require_tools
  [[ "$deploy_timeout_seconds" =~ ^[1-9][0-9]*$ ]] \
    || fail 'BEACH_DEPLOY_TIMEOUT_SECONDS must be a positive integer'

  local control_plane_id manifest_dir encoded_kustomization encoded_namespace encoded_configmap encoded_deployment encoded_service encoded_ingress
  control_plane_id="$(terraform_output control_plane_instance_id)"
  manifest_dir="/tmp/beach-app"
  encoded_kustomization="$(base64 -w0 "$repo_root/deploy/k8s/app/kustomization.yaml")"
  encoded_namespace="$(base64 -w0 "$repo_root/deploy/k8s/app/namespace.yaml")"
  encoded_configmap="$(base64 -w0 "$repo_root/deploy/k8s/app/configmap.yaml")"
  encoded_deployment="$(base64 -w0 "$repo_root/deploy/k8s/app/deployment.yaml")"
  encoded_service="$(base64 -w0 "$repo_root/deploy/k8s/app/service.yaml")"
  encoded_ingress="$(base64 -w0 "$repo_root/deploy/k8s/app/ingress.yaml")"

  log "deploying Beach on $control_plane_id (rollout timeout: ${deploy_timeout_seconds}s)"
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
install -d '$manifest_dir'
echo '$encoded_kustomization' | base64 -d > '$manifest_dir/kustomization.yaml'
echo '$encoded_namespace' | base64 -d > '$manifest_dir/namespace.yaml'
echo '$encoded_configmap' | base64 -d > '$manifest_dir/configmap.yaml'
echo '$encoded_deployment' | base64 -d > '$manifest_dir/deployment.yaml'
echo '$encoded_service' | base64 -d > '$manifest_dir/service.yaml'
echo '$encoded_ingress' | base64 -d > '$manifest_dir/ingress.yaml'

jwt_secret=\"\$(head -c 48 /dev/urandom | base64 -w0)\"
kubectl create secret generic beach-runtime \\
  --namespace beach \\
  --from-literal=SPRING_DATASOURCE_URL=jdbc:postgresql://postgres:5432/beach_complex \\
  --from-literal=SPRING_DATASOURCE_USERNAME=beach \\
  --from-literal=SPRING_DATASOURCE_PASSWORD=beach \\
  --from-literal=SPRING_REDIS_HOST=redis \\
  --from-literal=JWT_SECRET=\"\$jwt_secret\" \\
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k '$manifest_dir'
kubectl -n beach rollout restart deployment/beach
kubectl -n beach rollout status deployment/beach --timeout='${deploy_timeout_seconds}s'
kubectl -n beach get pods -o wide
unset jwt_secret
"
  log 'Beach deployment is ready'
}

main "$@"
