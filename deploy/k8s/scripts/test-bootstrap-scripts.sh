#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/../../.." && pwd)"

test_dir="$(mktemp -d)"
readonly test_dir
trap 'rm -rf "$test_dir"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_equals() {
  local expected="$1"
  local actual_file="$2"

  if [[ "$(cat "$actual_file")" != "$expected" ]]; then
    printf 'Expected:\n%s\nActual:\n' "$expected" >&2
    cat "$actual_file" >&2
    fail "$actual_file did not match"
  fi
}

write_fake_tools() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

name="${!#}"
case "$name" in
  control_plane_instance_id) printf 'i-control-plane\n' ;;
  control_plane_private_ip) printf '10.0.1.10\n' ;;
  worker_instance_ids) printf '{"app-1":"i-app-1","app-2":"i-app-2","obs-1":"i-obs-1"}\n' ;;
  node_hostnames) printf '{"cp-1":"beach-complex-cp-1","app-1":"beach-complex-app-1","app-2":"beach-complex-app-2","obs-1":"beach-complex-obs-1"}\n' ;;
  node_roles) printf '{"cp-1":"control-plane","app-1":"app","app-2":"app","obs-1":"observability"}\n' ;;
  *) printf 'unexpected terraform output: %s\n' "$name" >&2; exit 1 ;;
esac
EOF

  cat > "$bin_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

case "$1 $2" in
  'ssm get-parameter')
    printf 'test-ghcr-token\n'
    ;;
  'ssm send-command')
    while (($#)); do
      if [[ "$1" == '--parameters' ]]; then
        sed -e 's/^{"commands":\["/commands=/' -e 's/"]}$//' "${2#file://}" > "$AWS_PARAMETERS_FILE"
        break
      fi
      shift
    done
    printf 'command-1\n'
    ;;
  'ssm wait')
    ;;
  'ssm get-command-invocation')
    if [[ "$*" == *"StandardOutputContent"* ]]; then
      printf '\n'
    elif [[ "$*" == *"StandardErrorContent"* ]]; then
      printf '\n'
    elif [[ -n "${AWS_STATUS_COUNT_FILE:-}" ]]; then
      count="$(cat "$AWS_STATUS_COUNT_FILE" 2>/dev/null || printf '0')"
      printf '%s\n' "$((count + 1))" > "$AWS_STATUS_COUNT_FILE"
      if [[ "$count" == '0' ]]; then
        printf 'InProgress\n'
      else
        printf 'Success\n'
      fi
    else
      printf 'Success\n'
    fi
    ;;
  *)
    printf 'unexpected aws command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

  chmod +x "$bin_dir/terraform" "$bin_dir/aws"
}

decode_remote_script() {
  local parameters_file="$1"
  local output_file="$2"
  local parameters encoded

  parameters="$(cat "$parameters_file")"
  encoded="${parameters#commands=echo }"
  encoded="${encoded% | base64 -d | bash}"
  printf '%s' "$encoded" | base64 --decode > "$output_file"
}

test_library_resolves_repository_root() {
  local actual

  actual="$(bash -c 'source "$1"; printf "%s" "$repo_root"' _ "$script_dir/lib/ssm.sh")"
  [[ "$actual" == "$repo_root" ]] \
    || fail "ssm.sh resolved repo root as $actual instead of $repo_root"
}

test_ssm_waits_for_in_progress_command() {
  local bin_dir="$test_dir/ssm-bin"
  local status_count_file="$test_dir/ssm-status-count"

  write_fake_tools "$bin_dir"
  PATH="$bin_dir:$PATH" \
    AWS_PARAMETERS_FILE="$test_dir/ssm-parameters" \
    AWS_STATUS_COUNT_FILE="$status_count_file" \
    SSM_POLL_INTERVAL_SECONDS=0 \
    bash -c 'source "$1"; ssm_run i-test "echo ok"' _ "$script_dir/lib/ssm.sh" \
    >/dev/null

  [[ "$(cat "$status_count_file")" == '2' ]] \
    || fail 'ssm_run did not poll until the command reached Success'
}

test_control_plane_keeps_node_selector_role_empty() {
  local bin_dir="$test_dir/label-bin"
  local parameters_file="$test_dir/label-parameters"
  local remote_script="$test_dir/label-remote.sh"
  local kubectl_log="$test_dir/kubectl-label.log"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  chmod +x "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/label-nodes.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" bash "$remote_script"

  assert_file_equals 'label node beach-complex-app-1 node-role.kubernetes.io/app= --overwrite
label node beach-complex-app-1 node-role=app --overwrite
label node beach-complex-app-2 node-role.kubernetes.io/app= --overwrite
label node beach-complex-app-2 node-role=app --overwrite
label node beach-complex-obs-1 node-role.kubernetes.io/observability= --overwrite
label node beach-complex-obs-1 node-role=observability --overwrite
get nodes -o wide' "$kubectl_log"
}

test_existing_control_plane_restores_admin_kubeconfig() {
  local bin_dir="$test_dir/init-bin"
  local parameters_file="$test_dir/init-parameters"
  local remote_script="$test_dir/init-remote.sh"
  local install_log="$test_dir/install.log"
  local kubectl_log="$test_dir/kubectl-init.log"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/install" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INSTALL_LOG"
EOF
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  cat > "$bin_dir/kubeadm" <<'EOF'
#!/usr/bin/env bash
printf 'kubeadm must not run for an existing control plane\n' >&2
exit 1
EOF
  chmod +x "$bin_dir/install" "$bin_dir/kubectl" "$bin_dir/kubeadm"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/init-control-plane.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"

  PATH="$bin_dir:$PATH" INSTALL_LOG="$install_log" KUBECTL_LOG="$kubectl_log" \
    REMOTE_SCRIPT="$remote_script" bash -c '
      function [ {
        if [[ "$*" == "-f /etc/kubernetes/admin.conf ]" ]]; then
          return 0
        fi
        builtin [ "$@"
      }
      source "$REMOTE_SCRIPT"
    '

  assert_file_equals '-d -m 0700 /root/.kube
-m 0600 /etc/kubernetes/admin.conf /root/.kube/config' "$install_log"
  assert_file_equals '--kubeconfig /etc/kubernetes/admin.conf -n kube-system get deployment coredns
--kubeconfig /etc/kubernetes/admin.conf -n kube-system get daemonset kube-proxy
--kubeconfig /root/.kube/config get nodes' "$kubectl_log"
}

test_incomplete_control_plane_is_rejected() {
  local bin_dir="$test_dir/incomplete-init-bin"
  local parameters_file="$test_dir/incomplete-init-parameters"
  local remote_script="$test_dir/incomplete-init-remote.sh"
  local output_file="$test_dir/incomplete-init-output"
  local status

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *'get deployment coredns'* ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/init-control-plane.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"

  set +e
  PATH="$bin_dir:$PATH" REMOTE_SCRIPT="$remote_script" bash -c '
    function [ {
      if [[ "$*" == "-f /etc/kubernetes/admin.conf ]" ]]; then
        return 0
      fi
      builtin [ "$@"
    }
    source "$REMOTE_SCRIPT"
  ' >"$output_file" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail 'incomplete control plane was accepted'
  [[ "$(cat "$output_file")" == *'control plane initialization is incomplete'* ]] \
    || fail 'incomplete control plane did not report a recovery-oriented error'
}

test_kubeadm_config_enables_kubelet_serving_tls() {
  local bin_dir="$test_dir/kubeadm-config-bin"
  local parameters_file="$test_dir/kubeadm-config-parameters"
  local remote_script="$test_dir/kubeadm-config-remote.sh"
  local kubeadm_log="$test_dir/kubeadm.log"
  local config_capture="$test_dir/kubeadm-config.yaml"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf 'beach-complex-cp-1\n'
EOF
  cat > "$bin_dir/kubeadm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBEADM_LOG"
cp "${@: -1}" "$KUBEADM_CONFIG_CAPTURE"
EOF
  cat > "$bin_dir/install" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/hostnamectl" "$bin_dir/kubeadm" "$bin_dir/install" "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    POD_NETWORK_CIDR=10.245.0.0/16 bash "$script_dir/init-control-plane.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBEADM_LOG="$kubeadm_log" KUBEADM_CONFIG_CAPTURE="$config_capture" \
    bash "$remote_script"

  assert_file_equals 'init --config /tmp/kubeadm-config.yaml' "$kubeadm_log"
  grep -Fxq '  advertiseAddress: 10.0.1.10' "$config_capture" \
    || fail 'control plane IP did not reach the kubeadm config'
  grep -Fxq '  name: beach-complex-cp-1' "$config_capture" \
    || fail 'node name did not reach the kubeadm config'
  grep -Fxq '  podSubnet: 10.245.0.0/16' "$config_capture" \
    || fail 'POD_NETWORK_CIDR did not reach the kubeadm config'
  grep -Fxq 'serverTLSBootstrap: true' "$config_capture" \
    || fail 'kubelet serving TLS bootstrap is not enabled'
}

test_bootstrap_verifies_expected_nodes_and_coredns() {
  local bin_dir="$test_dir/bootstrap-bin"
  local parameters_file="$test_dir/bootstrap-parameters"
  local remote_script="$test_dir/bootstrap-remote.sh"
  local kubectl_log="$test_dir/kubectl-bootstrap.log"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/bash" <<'EOF'
#!/bin/bash
case "$1" in
  */init-control-plane.sh|*/join-workers.sh|*/install-cilium.sh|*/label-nodes.sh|*/approve-kubelet-serving-csrs.sh|*/install-metrics-server.sh) exit 0 ;;
  *) exec /bin/bash "$@" ;;
esac
EOF
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
if [[ "$*" == 'get nodes --no-headers' ]]; then
  printf 'node-1\nnode-2\nnode-3\nnode-4\n'
fi
EOF
  chmod +x "$bin_dir/bash" "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    /bin/bash "$script_dir/bootstrap-cluster.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" /bin/bash "$remote_script"

  assert_file_equals 'wait --for=condition=Ready node/beach-complex-cp-1 node/beach-complex-app-1 node/beach-complex-app-2 node/beach-complex-obs-1 --timeout=300s
get nodes --no-headers
get nodes -o wide
-n kube-system rollout status daemonset/cilium --timeout=300s
-n kube-system get pods -l k8s-app=cilium
-n kube-system patch deployment coredns --type merge --patch {"spec":{"template":{"spec":{"nodeSelector":{"node-role":"app"},"topologySpreadConstraints":[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"ScheduleAnyway","labelSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]}}}}
-n kube-system rollout status deployment/coredns --timeout=300s
-n kube-system get pods -l k8s-app=kube-dns' "$kubectl_log"
}

test_cilium_existing_install_is_reconciled_and_verified() {
  local bin_dir="$test_dir/cilium-bin"
  local parameters_file="$test_dir/cilium-parameters"
  local remote_script="$test_dir/cilium-remote.sh"
  local helm_log="$test_dir/helm.log"
  local kubectl_log="$test_dir/kubectl-cilium.log"
  local values_capture="$test_dir/cilium-values.yaml"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HELM_LOG"
if [[ "$1 $2" == 'upgrade --install' ]]; then
  cp /tmp/cilium-values.yaml "$VALUES_CAPTURE"
fi
EOF
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  chmod +x "$bin_dir/helm" "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    POD_NETWORK_CIDR=10.245.0.0/16 \
    bash "$script_dir/install-cilium.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" HELM_LOG="$helm_log" KUBECTL_LOG="$kubectl_log" \
    VALUES_CAPTURE="$values_capture" \
    bash "$remote_script"

  assert_file_equals 'repo add cilium https://helm.cilium.io/ --force-update
repo update
upgrade --install cilium cilium/cilium --version 1.20.2 --namespace kube-system --values /tmp/cilium-values.yaml' "$helm_log"
  assert_file_equals '-n kube-system rollout status daemonset/cilium --timeout=300s' "$kubectl_log"
  grep -q -- '- 10.245.0.0/16' "$values_capture" \
    || fail 'POD_NETWORK_CIDR did not reach the Cilium values'
}

test_metrics_server_is_installed_on_observability_node() {
  local bin_dir="$test_dir/metrics-server-bin"
  local parameters_file="$test_dir/metrics-server-parameters"
  local remote_script="$test_dir/metrics-server-remote.sh"
  local helm_log="$test_dir/helm-metrics-server.log"
  local kubectl_log="$test_dir/kubectl-metrics-server.log"
  local values_capture="$test_dir/metrics-server-values.yaml"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HELM_LOG"
if [[ "$1 $2" == 'upgrade --install' ]]; then
  cp /tmp/metrics-server-values.yaml "$VALUES_CAPTURE"
fi
EOF
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  chmod +x "$bin_dir/helm" "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/install-metrics-server.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" HELM_LOG="$helm_log" KUBECTL_LOG="$kubectl_log" \
    VALUES_CAPTURE="$values_capture" bash "$remote_script"

  assert_file_equals 'repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update
repo update
upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace kube-system --values /tmp/metrics-server-values.yaml' "$helm_log"
  assert_file_equals '-n kube-system rollout status deployment/metrics-server --timeout=300s
wait --for=condition=Available apiservice/v1beta1.metrics.k8s.io --timeout=300s' "$kubectl_log"
  grep -Fxq '  node-role: observability' "$values_capture" \
    || fail 'Metrics Server is not pinned to the observability node'
  if grep -Fq 'kubelet-insecure-tls' "$values_capture"; then
    fail 'Metrics Server must not disable kubelet TLS verification'
  fi
}

test_python_is_checked_before_worker_join() {
  local bin_dir="$test_dir/no-python-bin"
  local output_file="$test_dir/no-python-output"
  local status

  write_fake_tools "$bin_dir"
  ln -s /usr/bin/base64 "$bin_dir/base64"
  ln -s /usr/bin/dirname "$bin_dir/dirname"

  set +e
  PATH="$bin_dir" AWS_PARAMETERS_FILE="$test_dir/no-python-parameters" \
    /bin/bash "$script_dir/join-workers.sh" >"$output_file" 2>&1
  status=$?
  set -e

  [[ $status -ne 0 ]] || fail 'join-workers.sh succeeded without python3'
  [[ "$(cat "$output_file")" == *'python3 is required but not installed'* ]] \
    || fail 'join-workers.sh did not report the missing python3 dependency'
}

write_fake_csr_kubectl() {
  local bin_dir="$1"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == 'get csr --no-headers'* ]]; then
  cat "$CSR_LIST"
elif [[ "$*" == 'get node '* ]]; then
  printf '10.0.1.20'
else
  printf '%s\n' "$*" >> "$KUBECTL_LOG"
fi
EOF
  cat > "$bin_dir/openssl" <<'EOF'
#!/usr/bin/env bash
[[ "${KUBELET_CERT_VERIFIED:-false}" == 'true' ]]
EOF
  chmod +x "$bin_dir/kubectl" "$bin_dir/openssl"
}

test_only_known_kubelet_serving_csrs_are_approved() {
  local bin_dir="$test_dir/csr-bin"
  local parameters_file="$test_dir/csr-parameters"
  local remote_script="$test_dir/csr-remote.sh"
  local kubectl_log="$test_dir/kubectl-csr.log"
  local csr_list="$test_dir/csr-list.txt"

  write_fake_tools "$bin_dir"
  write_fake_csr_kubectl "$bin_dir"
  cat > "$csr_list" <<'EOF'
csr-cp       kubernetes.io/kubelet-serving                 system:node:beach-complex-cp-1    <none>
csr-app1     kubernetes.io/kubelet-serving                 system:node:beach-complex-app-1   Approved
csr-app2     kubernetes.io/kubelet-serving                 system:node:beach-complex-app-2   <none>
csr-obs      kubernetes.io/kubelet-serving                 system:node:beach-complex-obs-1   <none>
csr-rogue    kubernetes.io/kubelet-serving                 system:node:intruder              <none>
csr-client   kubernetes.io/kube-apiserver-client-kubelet   system:node:beach-complex-obs-1   <none>
EOF

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    KUBELET_CSR_POLL_INTERVAL_SECONDS=0 \
    bash "$script_dir/approve-kubelet-serving-csrs.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" CSR_LIST="$csr_list" bash "$remote_script" >/dev/null

  assert_file_equals 'certificate approve csr-cp
certificate approve csr-app2
certificate approve csr-obs
get csr' "$kubectl_log"
}

test_missing_kubelet_serving_csr_fails_after_timeout() {
  local bin_dir="$test_dir/csr-missing-bin"
  local parameters_file="$test_dir/csr-missing-parameters"
  local remote_script="$test_dir/csr-missing-remote.sh"
  local csr_list="$test_dir/csr-missing-list.txt"

  write_fake_tools "$bin_dir"
  write_fake_csr_kubectl "$bin_dir"
  cat > "$csr_list" <<'EOF'
csr-cp       kubernetes.io/kubelet-serving                 system:node:beach-complex-cp-1    Approved
EOF

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    KUBELET_CSR_TIMEOUT_SECONDS=0 KUBELET_CSR_POLL_INTERVAL_SECONDS=0 \
    bash "$script_dir/approve-kubelet-serving-csrs.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"

  if PATH="$bin_dir:$PATH" KUBECTL_LOG="$test_dir/kubectl-csr-missing.log" CSR_LIST="$csr_list" \
    bash "$remote_script" >/dev/null 2>&1; then
    fail 'CSR approval succeeded although worker CSRs were missing'
  fi
}

test_rerun_accepts_kubelets_with_issued_certificates() {
  local bin_dir="$test_dir/csr-rerun-bin"
  local parameters_file="$test_dir/csr-rerun-parameters"
  local remote_script="$test_dir/csr-rerun-remote.sh"
  local kubectl_log="$test_dir/kubectl-csr-rerun.log"
  local csr_list="$test_dir/csr-rerun-list.txt"

  write_fake_tools "$bin_dir"
  write_fake_csr_kubectl "$bin_dir"
  # 승인된 CSR은 1시간 뒤 자동 삭제된다. 재실행 시점에는 CSR 목록이 비어 있을 수 있다.
  : > "$csr_list"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    KUBELET_CSR_TIMEOUT_SECONDS=0 KUBELET_CSR_POLL_INTERVAL_SECONDS=0 \
    bash "$script_dir/approve-kubelet-serving-csrs.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" CSR_LIST="$csr_list" KUBELET_CERT_VERIFIED=true \
    bash "$remote_script" >/dev/null \
    || fail 'CSR approval failed although every kubelet already serves a CA-signed certificate'

  assert_file_equals 'get csr' "$kubectl_log"
}

test_ghcr_secret_is_rehydrated_from_ssm() {
  local bin_dir="$test_dir/ghcr-bin"
  local parameters_file="$test_dir/ghcr-parameters"
  local remote_script="$test_dir/ghcr-remote.sh"
  local kubectl_log="$test_dir/kubectl-ghcr.log"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  chmod +x "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    GHCR_USERNAME=geonusp GHCR_TOKEN_PARAMETER_NAME=/beach/dev/ghcr/token \
    bash "$script_dir/sync-ghcr-secret.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" bash "$remote_script"

  ! grep -Fq 'test-ghcr-token' "$parameters_file" \
    || fail 'GHCR token was embedded in the SSM command payload'
  grep -Fxq 'get namespace beach' "$kubectl_log" \
    || fail 'sync script did not check the target namespace'
  grep -Fxq 'create secret docker-registry ghcr-pull --namespace beach --docker-server=ghcr.io --docker-username=geonusp --docker-password=test-ghcr-token --dry-run=client -o yaml' "$kubectl_log" \
    || fail 'sync script did not create the expected GHCR Secret'
  grep -Fxq 'apply -f -' "$kubectl_log" \
    || fail 'sync script did not apply the generated Secret'
}

test_ghcr_secret_script_bootstraps_remote_aws_cli() {
  local bin_dir="$test_dir/ghcr-aws-cli-bin"
  local parameters_file="$test_dir/ghcr-aws-cli-parameters"
  local remote_script="$test_dir/ghcr-aws-cli-remote.sh"

  write_fake_tools "$bin_dir"
  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    GHCR_USERNAME=geonusp bash "$script_dir/sync-ghcr-secret.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"

  grep -Fq 'command -v aws' "$remote_script" \
    || fail 'sync script does not check for remote AWS CLI'
  grep -Fq 'apt-get -o DPkg::Lock::Timeout=300 install --yes unzip' "$remote_script" \
    || fail 'sync script does not install the AWS CLI installer dependency'
  grep -Fq 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' "$remote_script" \
    || fail 'sync script does not use the official AWS CLI v2 installer'
}

test_dependencies_are_applied_on_the_control_plane() {
  local bin_dir="$test_dir/dependencies-bin"
  local parameters_file="$test_dir/dependencies-parameters"
  local remote_script="$test_dir/dependencies-remote.sh"
  local kubectl_log="$test_dir/kubectl-dependencies.log"

  grep -Fq 'image: postgis/postgis:16-3.5-alpine' "$repo_root/deploy/k8s/dependencies/postgres.yaml" \
    || fail 'PostgreSQL dependency does not use a PostGIS image'

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  chmod +x "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/deploy-dependencies.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" bash "$remote_script"

  grep -Fxq 'apply -k /tmp/beach-dependencies' "$kubectl_log" \
    || fail 'dependency manifests were not applied with kustomize'
  grep -Fxq -- '-n beach rollout status deployment/postgres --timeout=300s' "$kubectl_log" \
    || fail 'PostgreSQL rollout was not verified'
  grep -Fxq -- '-n beach rollout status deployment/redis --timeout=300s' "$kubectl_log" \
    || fail 'Redis rollout was not verified'
}

test_beach_deployment_creates_runtime_secret_and_rolls_out() {
  local bin_dir="$test_dir/beach-deploy-bin"
  local parameters_file="$test_dir/beach-deploy-parameters"
  local remote_script="$test_dir/beach-deploy-remote.sh"
  local kubectl_log="$test_dir/kubectl-beach-deploy.log"

  grep -Fq 'APP_FIREBASE_ENABLED: "false"' "$repo_root/deploy/k8s/app/configmap.yaml" \
    || fail 'Beach ConfigMap does not disable Firebase for the credential-free PoC'
  grep -Fq -- '--from-literal=SPRING_DATA_REDIS_HOST=redis' "$repo_root/deploy/k8s/scripts/deploy-beach.sh" \
    || fail 'Beach deployment does not inject the Spring Boot 3 Redis host property'

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
EOF
  chmod +x "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/deploy-beach.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" KUBECTL_LOG="$kubectl_log" bash "$remote_script"

  grep -Fq -- 'create secret generic beach-runtime --namespace beach' "$kubectl_log" \
    || fail 'Beach runtime Secret was not generated'
  grep -Fq -- 'apply -k /tmp/beach-app' "$kubectl_log" \
    || fail 'Beach manifests were not applied with kustomize'
  grep -Fxq -- '-n beach rollout restart deployment/beach' "$kubectl_log" \
    || fail 'Beach deployment was not restarted after applying runtime manifests'
  grep -Fxq -- '-n beach rollout status deployment/beach --timeout=180s' "$kubectl_log" \
    || fail 'Beach deployment rollout was not verified'
}

test_management_port_is_not_exposed_outside_pods() {
  if grep -Eq '8081|management' "$repo_root/deploy/k8s/app/service.yaml"; then
    fail 'Beach Service must not expose the management port'
  fi
  if grep -Fq 'actuator' "$repo_root/deploy/k8s/app/ingress.yaml"; then
    fail 'Beach Ingress must not route actuator paths'
  fi
}

assert_yaml_component_disabled() {
  local component="$1"
  local values_file="$2"

  grep -A1 -x "$component:" "$values_file" | grep -Fxq '  enabled: false' \
    || fail "$component is not disabled in $values_file"
}

test_observability_values_fit_the_observability_node() {
  local values="$repo_root/deploy/k8s/observability/kube-prometheus-stack-values.yaml"
  local podmonitor="$repo_root/deploy/k8s/observability/beach-podmonitor.yaml"
  local component line

  for component in alertmanager kubeEtcd kubeScheduler kubeControllerManager kubeProxy; do
    assert_yaml_component_disabled "$component" "$values"
  done
  for line in '    retention: 2d' '    retentionSize: 5GB' '    scrapeInterval: 30s' \
    '    podMonitorSelectorNilUsesHelmValues: false' '    existingSecret: grafana-admin'; do
    grep -Fxq -- "$line" "$values" || fail "missing values line: $line"
  done
  [[ "$(grep -c 'node-role: observability' "$values")" == '5' ]] \
    || fail 'operator, webhook job, Prometheus, Grafana and kube-state-metrics must all target obs-1'
  if grep -Eq 'storageSpec|adminPassword' "$values"; then
    fail 'Prometheus must use emptyDir and Grafana must not carry a password in values'
  fi

  grep -Fxq '    - port: management' "$podmonitor" || fail 'PodMonitor must scrape the management port'
  grep -Fxq '      path: /actuator/prometheus' "$podmonitor" || fail 'PodMonitor path is wrong'
}

run_install_observability() {
  local name="$1"
  local secret_exists="$2"
  local bin_dir="$test_dir/$name-bin"
  local parameters_file="$test_dir/$name-parameters"
  local remote_script="$test_dir/$name-remote.sh"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/helm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HELM_LOG"
EOF
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
if [[ "$*" == '-n monitoring get secret grafana-admin' ]]; then
  [[ "$GRAFANA_SECRET_EXISTS" == 'true' ]]
fi
EOF
  chmod +x "$bin_dir/helm" "$bin_dir/kubectl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    bash "$script_dir/install-observability.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" HELM_LOG="$test_dir/$name-helm.log" KUBECTL_LOG="$test_dir/$name-kubectl.log" \
    GRAFANA_SECRET_EXISTS="$secret_exists" bash "$remote_script" >/dev/null
}

test_observability_stack_is_installed_with_generated_grafana_secret() {
  run_install_observability observability-new false

  assert_file_equals 'repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
repo update
upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 91.9.0 --namespace monitoring --values /tmp/kube-prometheus-stack-values.yaml --wait --timeout 10m' \
    "$test_dir/observability-new-helm.log"
  grep -Eq '^-n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-literal=admin-password=.{20,}$' \
    "$test_dir/observability-new-kubectl.log" || fail 'Grafana admin Secret was not generated'
  grep -Fxq 'apply -f /tmp/beach-podmonitor.yaml' "$test_dir/observability-new-kubectl.log" \
    || fail 'Beach PodMonitor was not applied'
}

test_observability_rerun_keeps_grafana_secret() {
  run_install_observability observability-rerun true

  if grep -Fq 'create secret' "$test_dir/observability-rerun-kubectl.log"; then
    fail 'existing Grafana admin Secret was replaced'
  fi
}

run_verify_observability() {
  local name="$1"
  local targets_json="$2"
  local query_value="${3:-1}"
  local bin_dir="$test_dir/$name-bin"
  local parameters_file="$test_dir/$name-parameters"
  local remote_script="$test_dir/$name-remote.sh"

  write_fake_tools "$bin_dir"
  printf '%s' "$targets_json" > "$test_dir/$name-targets.json"
  cat > "$bin_dir/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$CALL_LOG"
case "$*" in
  *'/api/v1/targets'*) cat "$TARGETS_JSON" ;;
  *'/api/v1/query'*) printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[0,"%s"]}]}}' "$QUERY_VALUE" ;;
  '-n beach get svc beach -o jsonpath={.spec.clusterIP}') printf '10.96.0.20' ;;
  *) printf 'fake %s\n' "$*" ;;
esac
EOF
  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "${!#}" >> "$CALL_LOG"
EOF
  chmod +x "$bin_dir/kubectl" "$bin_dir/curl"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" OBSERVABILITY_SCRAPE_WAIT_SECONDS=0 \
    bash "$script_dir/verify-observability.sh" >/dev/null
  decode_remote_script "$parameters_file" "$remote_script"
  PATH="$bin_dir:$PATH" TARGETS_JSON="$test_dir/$name-targets.json" QUERY_VALUE="$query_value" \
    CALL_LOG="$test_dir/$name-calls.log" bash "$remote_script" > "$test_dir/$name-output.txt" 2>&1
}

test_observability_verification_reports_targets_and_queries() {
  run_verify_observability verify-up \
    '{"data":{"activeTargets":[{"labels":{"job":"beach"},"health":"up","scrapeUrl":"http://10.244.1.5:8081/actuator/prometheus","lastError":""}]}}' \
    || fail 'verification failed although every target was up'

  grep -Fq "$(printf 'beach\tup\thttp://10.244.1.5:8081/actuator/prometheus')" "$test_dir/verify-up-output.txt" \
    || fail 'target line was not printed'
  grep -Fq "$(printf 'http_p95_seconds\t[')" "$test_dir/verify-up-output.txt" \
    || fail 'PromQL results were not printed'
}

test_observability_verification_fails_on_down_target() {
  if run_verify_observability verify-down \
    '{"data":{"activeTargets":[{"labels":{"job":"kube-proxy"},"health":"down","scrapeUrl":"http://10.0.1.10:10249/metrics","lastError":"connection refused"}]}}'; then
    fail 'verification passed although a target was down'
  fi
}

test_observability_verification_sends_beach_traffic_before_queries() {
  run_verify_observability verify-traffic \
    '{"data":{"activeTargets":[{"labels":{"job":"beach"},"health":"up","scrapeUrl":"http://10.244.1.5:8081/actuator/prometheus","lastError":""}]}}' \
    || fail 'verification failed although every target was up'

  local calls="$test_dir/verify-traffic-calls.log"
  [[ "$(grep -cFx 'curl http://10.96.0.20/api/beaches' "$calls")" == '30' ]] \
    || fail 'verification must send 30 requests to the Beach Service'
  (( $(grep -nF 'curl ' "$calls" | tail -1 | cut -d: -f1) < $(grep -nF '/api/v1/query' "$calls" | head -1 | cut -d: -f1) )) \
    || fail 'Beach traffic must be sent before PromQL queries'
}

test_observability_verification_fails_on_nan_result() {
  if run_verify_observability verify-nan \
    '{"data":{"activeTargets":[{"labels":{"job":"beach"},"health":"up","scrapeUrl":"http://10.244.1.5:8081/actuator/prometheus","lastError":""}]}}' \
    NaN; then
    fail 'verification passed although a query returned NaN'
  fi
  grep -Fq 'returned NaN' "$test_dir/verify-nan-output.txt" || fail 'NaN failure reason was not printed'
}

test_beach_dashboard_matches_verification_queries() {
  local dashboard="$repo_root/deploy/k8s/observability/dashboards/beach-overview.json"
  local queries="$repo_root/deploy/k8s/observability/promql-queries.tsv"

  python3 - "$dashboard" "$queries" <<'PY' || fail 'Beach dashboard does not match promql-queries.tsv'
import json, sys
dashboard = json.load(open(sys.argv[1], encoding='utf-8'))
queries = [line.rstrip('\n').split('\t')[1] for line in open(sys.argv[2], encoding='utf-8') if line.strip()]
panels = dashboard['panels']
exprs = [target['expr'] for panel in panels for target in panel['targets']]
assert dashboard['uid'] == 'beach-overview', dashboard['uid']
assert all(panel['datasource'] == {'type': 'prometheus', 'uid': 'prometheus'} for panel in panels)
assert sorted(exprs) == sorted(queries), set(exprs) ^ set(queries)
PY
}

# 실클러스터 캡처에서 드러난 표시 문제: 5xx 축 0~10000%, 시계열 수 축 라벨 중복, restart 범례의 k6 Job Pod.
test_beach_dashboard_panels_render_readable_values() {
  local dashboard="$repo_root/deploy/k8s/observability/dashboards/beach-overview.json"
  local queries="$repo_root/deploy/k8s/observability/promql-queries.tsv"

  python3 - "$dashboard" "$queries" <<'PY' || fail 'Beach dashboard panels do not render readable values'
import json, sys
panels = {panel['title']: panel for panel in json.load(open(sys.argv[1], encoding='utf-8'))['panels']}
queries = dict(line.rstrip('\n').split('\t') for line in open(sys.argv[2], encoding='utf-8') if line.strip())
ratio = panels['HTTP 5xx 비율']['fieldConfig']['defaults']
assert (ratio.get('min'), ratio.get('max')) == (0, 1), ratio
series = panels['Prometheus 시계열 수']['fieldConfig']['defaults']
assert (series.get('unit'), series.get('decimals')) == ('none', 0), series
assert 'pod!~"beach-k6-.*"' in queries['pod_restarts_total'], queries['pod_restarts_total']
PY
}

test_beach_dashboard_is_provisioned_for_grafana_sidecar() {
  run_install_observability observability-dashboard true

  grep -Fxq -- '-n monitoring create configmap beach-dashboards --from-file=beach-overview.json=/tmp/beach-overview.json --dry-run=client -o yaml' \
    "$test_dir/observability-dashboard-kubectl.log" || fail 'dashboard ConfigMap was not rendered'
  grep -Fxq -- '-n monitoring label configmap beach-dashboards grafana_dashboard=1 --overwrite' \
    "$test_dir/observability-dashboard-kubectl.log" || fail 'dashboard ConfigMap is not labelled for the Grafana sidecar'
}

test_kubeconfig_files_are_ignored() {
  git -C "$repo_root" check-ignore -q kubeconfig \
    || fail 'kubeconfig is not ignored'
  git -C "$repo_root" check-ignore -q cluster/admin.conf \
    || fail '*.conf files are not ignored'
}

test_provision_and_deploy_runs_steps_in_order() {
  local script="$repo_root/deploy/k8s/scripts/provision-and-deploy.sh"
  local apply_line bootstrap_line ghcr_line dependencies_line beach_line observability_line destroy_line

  apply_line="$(grep -nF 'terraform -chdir=' "$script" | grep -F 'apply -auto-approve' | cut -d: -f1)"
  bootstrap_line="$(grep -nF 'bootstrap-cluster.sh' "$script" | head -n1 | cut -d: -f1)"
  ghcr_line="$(grep -nF 'sync-ghcr-secret.sh' "$script" | head -n1 | cut -d: -f1)"
  dependencies_line="$(grep -nF 'deploy-dependencies.sh' "$script" | head -n1 | cut -d: -f1)"
  beach_line="$(grep -nF 'deploy-beach.sh' "$script" | head -n1 | cut -d: -f1)"
  observability_line="$(grep -nF 'install-observability.sh' "$script" | head -n1 | cut -d: -f1)"
  destroy_line="$(grep -nF 'destroy' "$script" | head -n1 | cut -d: -f1)"

  [[ -n "$apply_line" && -n "$bootstrap_line" && -n "$ghcr_line" && -n "$dependencies_line" && -n "$beach_line" && -n "$observability_line" ]] \
    || fail 'provision-and-deploy.sh is missing a required deployment step'
  ((apply_line < bootstrap_line && bootstrap_line < ghcr_line && ghcr_line < dependencies_line && dependencies_line < beach_line && beach_line < observability_line)) \
    || fail 'provision-and-deploy.sh deployment steps are out of order'
  [[ -n "$destroy_line" ]] || fail 'provision-and-deploy.sh does not provide the destroy path'
}

main() {
  if (($#)); then
    "$1"
    printf 'PASS %s\n' "$1"
    return
  fi

  test_library_resolves_repository_root
  test_ssm_waits_for_in_progress_command
  test_existing_control_plane_restores_admin_kubeconfig
  test_incomplete_control_plane_is_rejected
  test_kubeadm_config_enables_kubelet_serving_tls
  test_control_plane_keeps_node_selector_role_empty
  test_bootstrap_verifies_expected_nodes_and_coredns
  test_cilium_existing_install_is_reconciled_and_verified
  test_python_is_checked_before_worker_join
  test_only_known_kubelet_serving_csrs_are_approved
  test_missing_kubelet_serving_csr_fails_after_timeout
  test_rerun_accepts_kubelets_with_issued_certificates
  test_metrics_server_is_installed_on_observability_node
  test_ghcr_secret_is_rehydrated_from_ssm
  test_ghcr_secret_script_bootstraps_remote_aws_cli
  test_dependencies_are_applied_on_the_control_plane
  test_beach_deployment_creates_runtime_secret_and_rolls_out
  test_management_port_is_not_exposed_outside_pods
  test_observability_values_fit_the_observability_node
  test_observability_stack_is_installed_with_generated_grafana_secret
  test_observability_rerun_keeps_grafana_secret
  test_observability_verification_reports_targets_and_queries
  test_observability_verification_fails_on_down_target
  test_observability_verification_sends_beach_traffic_before_queries
  test_observability_verification_fails_on_nan_result
  test_beach_dashboard_matches_verification_queries
  test_beach_dashboard_panels_render_readable_values
  test_beach_dashboard_is_provisioned_for_grafana_sidecar
  test_kubeconfig_files_are_ignored
  test_provision_and_deploy_runs_steps_in_order
  printf 'PASS bootstrap script tests\n'
}

main "$@"
