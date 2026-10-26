#!/usr/bin/env bash
# Idle development cluster only. This command creates load and temporarily scales Beach.
set -Eeuo pipefail
export SSM_COMMAND_TIMEOUT_SECONDS=2400
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib/ssm.sh"
[[ $# -ge 2 && $# -le 4 && "$1" == --confirm-dev ]] || fail 'Usage: run-hpa-experiment.sh --confirm-dev <smoke|baseline|load|stress|extreme> [rate] [label]'
profile="$2"
case "$profile" in smoke|baseline) default_rate=5;; load) default_rate=40;; stress) default_rate=80;; extreme) default_rate=120;; *) fail 'unknown profile';; esac
rate="${3:-$default_rate}"; label="${4:-hpa-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
[[ "$rate" =~ ^[1-9][0-9]{0,2}$ && "$rate" -le 200 ]] || fail 'rate must be in 1..200'
[[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || fail 'invalid result label'
python_bin="${PYTHON:-python3}"
require_tools "$python_bin"
result_dir="${BEACH_HPA_RESULT_DIR:-$repo_root/deploy/k8s/loadtest/results/issue-4}/$label"
mkdir -p "$(dirname "$result_dir")"
mkdir "$result_dir" || fail 'result label exists; preserve previous evidence'
cp_id="$(terraform_output control_plane_instance_id)"
bucket="$(terraform_output experiment_results_bucket_name)"
for name in node_instance_ids node_hostnames node_roles node_private_ips; do terraform_output_json "$name" > "$result_dir/$name.json"; done
"$python_bin" - "$result_dir" "$cp_id" <<'PY'
import json, pathlib, re, sys
p = pathlib.Path(sys.argv[1]); names = dict(ids="node_instance_ids", hosts="node_hostnames", roles="node_roles", ips="node_private_ips")
c = {key: json.loads((p / (name + '.json')).read_text()) for key, name in names.items()}
assert len(set(c['ids'].values())) == len(c['ids']), 'Duplicate instance IDs'
assert [c['ids'][k] for k, role in c['roles'].items() if role == 'control-plane'] == [sys.argv[2]], 'Wrong control plane'
assert all(re.fullmatch(r'i-[a-f0-9]+', value) for value in c['ids'].values()), 'Invalid instance ID'
(p / 'context.json').write_text(json.dumps(c))
(p / 'instances.txt').write_text(' '.join(c['ids'].values()))
PY
read -r -a instances < <(cat "$result_dir/instances.txt"; echo)
aws sts get-caller-identity > "$result_dir/aws-identity.json"
aws ec2 describe-instances --instance-ids "${instances[@]}" > "$result_dir/aws-instances.json"
aws ec2 describe-instance-credit-specifications --instance-ids "${instances[@]}" > "$result_dir/aws-credit-mode.json"
credits() {
  local instance
  for instance in "${instances[@]}"; do
    aws cloudwatch get-metric-statistics --namespace AWS/EC2 --metric-name CPUCreditBalance --dimensions "Name=InstanceId,Value=$instance" --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 300 --statistics Minimum > "$result_dir/credit-$1-$instance.json"
  done
}
credits before
log "starting HPA $profile; results: $result_dir"
bash "$script_dir/verify-observability.sh" > "$result_dir/observability.txt" 2>&1 || { cat "$result_dir/observability.txt" >&2; fail 'observability verification failed'; }
payload="work_dir=\"\$(mktemp -d /tmp/beach-hpa.XXXXXX)\"; profile='$profile'; rate='$rate'"$'\n'
for file in loadtest/hpa.js loadtest/k6-failure-job.yaml app/hpa.yaml observability/promql-queries.tsv scripts/hpa_results.py scripts/failure_results.py scripts/node_failure_results.py; do
  payload+="echo '$(base64 -w0 "$repo_root/deploy/k8s/$file")' | base64 -d > \"\$work_dir/${file##*/}\""$'\n'
done
payload+="echo '$(base64 -w0 "$result_dir/context.json")' | base64 -d > \"\$work_dir/context.json\""$'\n'
# The wrapper returns success to SSM even after failure so S3 contains the full failure evidence.
payload+=$'\nset +e\n(\n'
payload+="$(cat "$script_dir/lib/hpa-remote.sh")"$'\n) 2>&1\nstatus=$?\nprintf "experiment_exit_status=%s\\n" "$status"\nexit 0\n'
log "running HPA $profile through SSM; waiting for evidence and recovery"
if ! (ssm_run "$cp_id" "$payload" "$bucket" "rollout/issue-4/$label") > "$result_dir/remote-output.txt" 2> "$result_dir/ssm-error.txt"; then
  cat "$result_dir/ssm-error.txt" >&2
  fail "SSM execution/retrieval failed; inspect $result_dir and S3 rollout/issue-4/$label; remote recovery is unverified"
fi
credits after
"$python_bin" "$script_dir/hpa_results.py" summarize "$result_dir/remote-output.txt" > "$result_dir/summary.json" || fail "experiment incomplete; preserve $result_dir and inspect recovery markers"
log "HPA experiment evidence collected; results: $result_dir"
