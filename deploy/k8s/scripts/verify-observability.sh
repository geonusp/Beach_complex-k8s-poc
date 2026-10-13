#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/ssm.sh"

main() {
  require_tools

  local control_plane_id queries_encoded
  control_plane_id="$(terraform_output control_plane_instance_id)"
  queries_encoded="$(base64 -w0 "$repo_root/deploy/k8s/observability/promql-queries.tsv")"

  log "verifying resource metrics and Prometheus on $control_plane_id"

  # Prometheus는 API server service proxy로 조회한다. 포트 포워딩 없이 SSM Run Command 한 번으로 끝난다.
  ssm_run "$control_plane_id" "
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
prometheus_api=/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1
echo '$queries_encoded' | base64 -d > /tmp/promql-queries.tsv

echo '== kubectl top node'
kubectl top node
echo '== kubectl top pod'
kubectl top pod -A
echo '== monitoring pods'
kubectl -n monitoring get pods -o wide

echo '== prometheus targets'
kubectl get --raw \"\$prometheus_api/targets?state=active\" > /tmp/prometheus-targets.json
python3 - /tmp/prometheus-targets.json <<'PY'
import json, sys
targets = json.load(open(sys.argv[1]))['data']['activeTargets']
down = [t for t in targets if t['health'] != 'up']
for t in targets:
    print('\t'.join([t['labels'].get('job', ''), t['health'], t['scrapeUrl'], t['lastError']]))
if not targets or down:
    sys.exit('%d of %d active targets are not up' % (len(down), len(targets)))
PY

echo '== promql'
while IFS=\$'\t' read -r -u 3 name query; do
  encoded_query=\"\$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' \"\$query\")\"
  kubectl get --raw \"\$prometheus_api/query?query=\$encoded_query\" > /tmp/prometheus-query.json
  python3 - \"\$name\" /tmp/prometheus-query.json <<'PY'
import json, sys
name, path = sys.argv[1], sys.argv[2]
body = json.load(open(path))
result = body['data']['result']
print(name + '\t' + json.dumps(result, separators=(',', ':')))
if body['status'] != 'success' or not result:
    sys.exit(name + ' returned no data')
PY
done 3< /tmp/promql-queries.tsv
"

  log 'observability verification passed'
}

main "$@"
