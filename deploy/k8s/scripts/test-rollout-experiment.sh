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
  assert_contains 'cat /results/raw.json' "$job"
  assert_contains 'raw_json_start' "$job"
  assert_contains 'raw_json_end' "$job"
  assert_contains "executor: 'constant-arrival-rate'" "$script"
  assert_contains '/api/beaches' "$script"
  assert_contains 'handleSummary' "$script"
}

test_runner_embeds_remote_experiment_contract() {
  local test_dir bin_dir parameters_file remote_script bucket_file prefix_file s3_source_file
  test_dir="$(mktemp -d)"
  bin_dir="$test_dir/bin"
  parameters_file="$test_dir/parameters"
  bucket_file="$test_dir/bucket"
  prefix_file="$test_dir/prefix"
  s3_source_file="$test_dir/s3-source"
  remote_script="$test_dir/remote.sh"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/terraform" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  control_plane_instance_id) printf 'i-control-plane\n' ;;
  experiment_results_bucket_name) printf 'beach-test-results\n' ;;
  *) exit 1 ;;
esac
EOF
  cat > "$bin_dir/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1 $2" in
  'ssm send-command')
    while (($#)); do
      if [[ "$1" == '--parameters' ]]; then
        printf '%s' "$2" > "$AWS_PARAMETERS_FILE"
      fi
      if [[ "$1" == '--output-s3-bucket-name' ]]; then printf '%s' "$2" > "$AWS_BUCKET_FILE"; fi
      if [[ "$1" == '--output-s3-key-prefix' ]]; then printf '%s' "$2" > "$AWS_PREFIX_FILE"; fi
      shift
    done
    printf 'command-1\n'
    ;;
  'ssm get-command-invocation')
    if [[ "$*" == *'StandardOutputUrl'* ]]; then
      printf 'https://s3.us-east-1.amazonaws.com/beach-test-results/rollout/smoke/command-1/i-control-plane/awsrunShellScript/0.awsrunShellScript/stdout\n'
    elif [[ "$*" == *'StandardOutputContent'* ]]; then
      printf 'remote output\n'
    elif [[ "$*" == *'StandardErrorContent'* ]]; then
      printf '\n'
    else
      printf 'Success\n'
    fi
    ;;
  *)
    if [[ "$1 $2" == 's3 cp' ]]; then
      printf '%s' "$3" > "$AWS_S3_SOURCE_FILE"
      printf 'rollout_duration_seconds=12\nk6_summary_start\n{}\nk6_summary_end\nraw_json_start\n{"metric":"raw"}\nraw_json_end\nendpoint_samples_start\nsample\nendpoint_samples_end\n'
      exit 0
    fi
    printf 'unexpected aws command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin_dir/terraform" "$bin_dir/aws"

  PATH="$bin_dir:$PATH" AWS_PARAMETERS_FILE="$parameters_file" AWS_BUCKET_FILE="$bucket_file" \
    AWS_PREFIX_FILE="$prefix_file" AWS_S3_SOURCE_FILE="$s3_source_file" \
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
  assert_contains "s/value: \"2m\"/value: \"331s\"/" "$remote_script"
  assert_contains 'trap cleanup EXIT' "$remote_script"
  assert_contains 'restore_needed=true' "$remote_script"
  assert_contains 'kubectl -n beach logs "$k6_pod" -c k6' "$remote_script"
  if grep -Fq 'kubectl -n beach exec "$k6_pod"' "$remote_script"; then
    fail 'completed k6 pod must not be accessed with kubectl exec'
  fi
  [[ "$(cat "$bucket_file")" == 'beach-test-results' ]] || fail 'SSM output bucket was not configured'
  [[ "$(cat "$prefix_file")" == 'rollout/smoke' ]] || fail 'SSM output prefix was not configured'
  [[ "$(cat "$s3_source_file")" == 's3://beach-test-results/rollout/smoke/command-1/i-control-plane/awsrunShellScript/0.awsrunShellScript/stdout' ]] \
    || fail 'SSM full stdout was not fetched from the expected S3 object'
  assert_contains '"metric":"raw"' "$test_dir/results/smoke/raw.json"
  assert_contains 'endpoint_samples_start' "$test_dir/results/smoke/remote-output.txt"
  rm -rf "$test_dir"
}

main() {
  test_loadtest_assets_are_pinned_and_scheduled
  test_runner_embeds_remote_experiment_contract
  printf 'PASS rollout experiment tests\n'
}

main "$@"
