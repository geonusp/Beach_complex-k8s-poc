# SSM Run Command로 원격 셸 스크립트를 실행하는 공통 함수.
# 이 파일은 단독 실행하지 않고 다른 스크립트에서 source 한다.

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
readonly terraform_environment="$repo_root/deploy/k8s/terraform/environments/dev"
readonly ssm_poll_interval_seconds="${SSM_POLL_INTERVAL_SECONDS:-5}"
readonly ssm_command_timeout_seconds="${SSM_COMMAND_TIMEOUT_SECONDS:-900}"

log() {
  printf '[beach-k8s] %s\n' "$*"
}

fail() {
  printf '[beach-k8s] ERROR: %s\n' "$*" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in aws terraform base64 "$@"; do
    command -v "$tool" >/dev/null || fail "$tool is required but not installed"
  done
}

# Terraform 출력을 읽는다. 부트스트랩은 IP를 하드코딩하지 않고 항상 여기서 가져온다.
# 클러스터를 재생성하면 IP와 instance ID가 바뀌지만 절차는 그대로 동작해야 한다.
terraform_output() {
  local name="$1"
  terraform -chdir="$terraform_environment" output -raw "$name" 2>/dev/null \
    || fail "terraform output '$name' is not available. Run terraform apply first."
}

terraform_output_json() {
  local name="$1"
  terraform -chdir="$terraform_environment" output -json "$name" 2>/dev/null \
    || fail "terraform output '$name' is not available. Run terraform apply first."
}

# 원격 스크립트를 base64로 실어 보낸다. JSON 이스케이프와 따옴표 문제를 피하려는 것이며
# jq 같은 추가 도구도 필요 없다.
ssm_run() {
  local instance_id="$1"
  local script="$2"
  local encoded command_id status deadline

  encoded="$(printf '%s' "$script" | base64 -w0)"

  command_id="$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --comment "beach-k8s bootstrap" \
    --parameters "commands=echo $encoded | base64 -d | bash" \
    --query 'Command.CommandId' \
    --output text)" || fail "failed to send SSM command to $instance_id"

  deadline=$((SECONDS + ssm_command_timeout_seconds))
  while true; do
    if ! status="$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null)"; then
      # Run Command invocation은 eventual consistency 때문에 전송 직후 보이지 않을 수 있다.
      status="Pending"
    fi

    case "$status" in
      Success)
        break
        ;;
      Pending|InProgress|Delayed)
        if ((SECONDS >= deadline)); then
          fail "SSM command on $instance_id did not finish within ${ssm_command_timeout_seconds}s"
        fi
        sleep "$ssm_poll_interval_seconds"
        ;;
      *)
        aws ssm get-command-invocation \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query 'StandardErrorContent' --output text >&2 || true
        fail "SSM command on $instance_id finished with status $status"
        ;;
    esac
  done

  aws ssm get-command-invocation \
    --command-id "$command_id" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text

}
