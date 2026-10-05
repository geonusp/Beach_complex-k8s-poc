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
        printf '%s' "$2" > "$AWS_PARAMETERS_FILE"
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

test_pod_cidr_override_reaches_kubeadm() {
  local bin_dir="$test_dir/cidr-bin"
  local parameters_file="$test_dir/cidr-parameters"
  local remote_script="$test_dir/cidr-remote.sh"
  local kubeadm_log="$test_dir/kubeadm.log"

  write_fake_tools "$bin_dir"
  cat > "$bin_dir/hostnamectl" <<'EOF'
#!/usr/bin/env bash
printf 'beach-complex-cp-1\n'
EOF
  cat > "$bin_dir/kubeadm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBEADM_LOG"
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
  PATH="$bin_dir:$PATH" KUBEADM_LOG="$kubeadm_log" bash "$remote_script"

  [[ "$(cat "$kubeadm_log")" == *'--pod-network-cidr 10.245.0.0/16'* ]] \
    || fail 'POD_NETWORK_CIDR did not reach kubeadm'
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
  */init-control-plane.sh|*/join-workers.sh|*/install-cilium.sh|*/label-nodes.sh) exit 0 ;;
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
  grep -Fxq -- '-n beach rollout status deployment/beach --timeout=300s' "$kubectl_log" \
    || fail 'Beach deployment rollout was not verified'
}

test_kubeconfig_files_are_ignored() {
  git -C "$repo_root" check-ignore -q kubeconfig \
    || fail 'kubeconfig is not ignored'
  git -C "$repo_root" check-ignore -q cluster/admin.conf \
    || fail '*.conf files are not ignored'
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
  test_pod_cidr_override_reaches_kubeadm
  test_control_plane_keeps_node_selector_role_empty
  test_bootstrap_verifies_expected_nodes_and_coredns
  test_cilium_existing_install_is_reconciled_and_verified
  test_python_is_checked_before_worker_join
  test_ghcr_secret_is_rehydrated_from_ssm
  test_ghcr_secret_script_bootstraps_remote_aws_cli
  test_dependencies_are_applied_on_the_control_plane
  test_beach_deployment_creates_runtime_secret_and_rolls_out
  test_kubeconfig_files_are_ignored
  printf 'PASS bootstrap script tests\n'
}

main "$@"
