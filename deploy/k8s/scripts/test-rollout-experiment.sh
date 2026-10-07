#!/usr/bin/env bash
set -Eeuo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "$script_dir/../../.." && pwd)"
readonly loadtest_dir="$repo_root/deploy/k8s/loadtest"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "$file does not contain: $needle"
}

test_loadtest_assets_are_pinned_and_scheduled() {
  local job="$loadtest_dir/k6-job.yaml"
  local script="$loadtest_dir/rollout.js"

  [[ -f "$job" ]] || fail 'k6 Job manifest is missing'
  [[ -f "$script" ]] || fail 'k6 rollout scenario is missing'
  assert_contains 'image: grafana/k6:2.3.0' "$job"
  assert_contains 'node-role: observability' "$job"
  assert_contains 'ttlSecondsAfterFinished: 3600' "$job"
  assert_contains 'requests:' "$job"
  assert_contains 'limits:' "$job"
  assert_contains "executor: 'constant-arrival-rate'" "$script"
  assert_contains '/api/beaches' "$script"
  assert_contains 'handleSummary' "$script"
}

test_runner_embeds_remote_experiment_contract() {
  local test_dir bin_dir parameters_file remote_script
  test_dir="$(mktemp -d)"
  bin_dir="$test_dir/bin"
  parameters_file="$test_dir/parameters"
  remote_script="$test_dir/remote.sh"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/terraform" <<'EOF'
#!/usr/bin/env bash
printf 'i-control-plane\n'
EOF
  cat > "$bin_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 $2" in
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
  'ssm get-command-invocation')
    if [[ "$*" == *'StandardOutputContent'* ]]; then
      printf 'remote output\n'
    elif [[ "$*" == *'StandardErrorContent'* ]]; then
      printf '\n'
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

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" \
    SSM_POLL_INTERVAL_SECONDS=0 \
    BEACH_ROLLOUT_RESULT_DIR="$test_dir/results" \
    bash "$script_dir/run-rollout-experiment.sh" \
      ghcr.io/example/beach:before ghcr.io/example/beach:after 2 0 1 smoke >/dev/null

  local parameters encoded
  parameters="$(cat "$parameters_file")"
  encoded="${parameters#commands=echo }"
  encoded="${encoded% | base64 -d | bash}"
  printf '%s' "$encoded" | base64 --decode > "$remote_script"

  assert_contains 'kubectl -n beach apply -f' "$remote_script"
  assert_contains 'kubectl -n beach set image deployment/beach beach="ghcr.io/example/beach:after"' "$remote_script"
  assert_contains 'kubectl -n beach rollout status deployment/beach' "$remote_script"
  assert_contains 'kubectl -n beach set image deployment/beach beach="ghcr.io/example/beach:before"' "$remote_script"
  assert_contains 'endpointslice' "$remote_script"
  rm -rf "$test_dir"
}

main() {
  test_loadtest_assets_are_pinned_and_scheduled
  test_runner_embeds_remote_experiment_contract
  printf 'PASS rollout experiment tests\n'
}

main "$@"
