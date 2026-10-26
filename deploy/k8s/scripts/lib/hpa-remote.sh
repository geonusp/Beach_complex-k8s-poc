# Sourced into the SSM experiment subshell; work_dir/profile/rate come from the local runner.
set -Eeuo pipefail
export KUBECONFIG=/root/.kube/config
k=(kubectl --request-timeout=10s -n beach)
job_name="beach-k6-hpa-${work_dir##*.}"; job_name="${job_name,,}"
hpa_created=false; job_created=false; collector_pid=''; hpa_changed=false; configmap_created=false
start="$(date -u +%s)"
utc() { date -u +%Y-%m-%dT%H:%M:%S.%NZ; }
snapshot() {
  "${k[@]}" get pods,deployments,services,endpointslices,nodes,hpa,jobs -o json > "$work_dir/state.json"
  python3 "$work_dir/hpa_results.py" sample "$work_dir/state.json"
}
finish() {
  status=$?; trap - EXIT; set +e
  echo "recovery_requested=$(utc)"
  if [[ "$job_created" == true ]]; then
    "${k[@]}" delete job "$job_name" --wait=true --timeout=60s || status=1
  fi
  if [[ -n "$collector_pid" ]]; then
    timeout 10s tail --pid="$collector_pid" -f /dev/null || { kill "$collector_pid" 2>/dev/null; status=1; }
    wait "$collector_pid" || true
    echo "k6_log_lines_bytes=$(wc -lc < "$work_dir/k6.log")"
    cat "$work_dir/k6.log"
  fi
  if [[ "$hpa_created" == true ]]; then
    if "${k[@]}" delete hpa "$job_name" --ignore-not-found --wait=true --timeout=30s && "${k[@]}" scale deployment/beach --replicas=2; then
      hpa_created=false
    else status=1; fi
  fi
  if [[ ( "$job_created" == true || "$hpa_changed" == true ) && "$hpa_created" == false ]]; then
    deadline=$((SECONDS + 180)); verified=false
    while ((SECONDS < deadline)); do
      if snapshot && python3 "$work_dir/hpa_results.py" restored "$work_dir/state.json"; then
        ip="$("${k[@]}" get service beach -o jsonpath='{.spec.clusterIP}')"
        if curl --fail --silent --show-error --max-time 5 "http://$ip/api/beaches" > "$work_dir/api-final.json"; then
          echo "final_state_verified=$(utc)"; verified=true; break
        fi
      fi
      sleep 3
    done
    [[ "$verified" == true ]] || status=1
  fi
  [[ "$configmap_created" == false ]] || "${k[@]}" delete configmap "$job_name" --wait=true --timeout=30s || status=1
  echo 'final_state:'; cat "$work_dir/state.json"; echo
  "${k[@]}" get events --sort-by=.metadata.creationTimestamp
  echo "remote_work_dir=$work_dir"
  echo "Manual recovery: inspect HPA $job_name and Job $job_name; stop this Job, remove only this experiment HPA, scale deployment/beach to 2, then verify rollout, endpoints and API."
  rmdir /tmp/beach-hpa-active || status=1
  exit "$status"
}
mkdir /tmp/beach-hpa-active || { echo 'ERROR: another HPA experiment or stale lock exists; inspect before retrying'; exit 1; }
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "profile=$profile"; echo "request_rate=$rate"; echo "started=$(utc)"
snapshot
echo 'initial_state:'; cat "$work_dir/state.json"; echo
kubectl --request-timeout=10s get pods -A -o json > "$work_dir/all-pods.json"
python3 - "$work_dir" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); data = json.loads((p/'state.json').read_text())
data['all_pods'] = json.loads((p/'all-pods.json').read_text())['items']
(p/'preflight.json').write_text(json.dumps(data))
PY
python3 "$work_dir/hpa_results.py" preflight "$work_dir/preflight.json" "$work_dir/context.json"
kubectl --request-timeout=10s get --raw /apis/metrics.k8s.io/v1beta1/namespaces/beach/pods > "$work_dir/metrics-before.json"
cat "$work_dir/metrics-before.json"; echo
if [[ "$profile" == load || "$profile" == stress ]]; then
  sed "s/name: beach-experiment/name: $job_name/" "$work_dir/hpa.yaml" > "$work_dir/run-hpa.yaml"
  hpa_created=true; hpa_changed=true
  "${k[@]}" create -f "$work_dir/run-hpa.yaml"
fi
"${k[@]}" create configmap "$job_name" --from-file="$work_dir/hpa.js"
configmap_created=true
sed -e "s/beach-k6-failure/$job_name/g" -e 's/failure.js/hpa.js/g' "$work_dir/k6-failure-job.yaml" > "$work_dir/job.yaml"
"${k[@]}" set env --local -f "$work_dir/job.yaml" HPA_PROFILE="$profile" K6_RATE="$rate" K6_NEW_MACHINE_READABLE_SUMMARY=false -o json > "$work_dir/run-job.json"
"${k[@]}" create -f "$work_dir/run-job.json"
job_created=true
kubectl -n beach logs --follow --pod-running-timeout=120s --request-timeout=0 "job/$job_name" -c k6 > "$work_dir/k6.log" 2>&1 &
collector_pid=$!
deadline=$((SECONDS + 720)); completed=false
while ((SECONDS < deadline)); do
  snapshot
  kubectl --request-timeout=10s get --raw /apis/metrics.k8s.io/v1beta1/namespaces/beach/pods
  echo
  job_state="$("${k[@]}" get job "$job_name" -o jsonpath='{.status.succeeded}:{.status.failed}')"
  case "$job_state" in 1:*) completed=true; break;; *:1) echo 'ERROR: k6 failed or safety threshold aborted'; exit 1;; esac
  sleep 10
done
[[ "$completed" == true ]] || { echo 'ERROR: k6 deadline exceeded'; exit 1; }
echo "load_finished=$(utc)"
if [[ "$hpa_created" == true ]]; then
  deadline=$((SECONDS + 660)); down=false
  while ((SECONDS < deadline)); do
    snapshot
    if python3 "$work_dir/hpa_results.py" down "$work_dir/state.json"; then down=true; break; fi
    sleep 10
  done
  [[ "$down" == true ]] || { echo 'ERROR: HPA did not return to two replicas'; exit 1; }
fi
prometheus_api=/api/v1/namespaces/monitoring/services/http:kube-prometheus-stack-prometheus:9090/proxy/api/v1
end="$(date -u +%s)"
printf '%s\t%s\n' k6_cpu_cores 'sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="beach",pod=~"beach-k6-.*",container="k6"}[1m]))' >> "$work_dir/promql-queries.tsv"
# The chart drops throttled seconds; retain evidence as the fraction of throttled CFS periods.
printf '%s\t%s\n' k6_throttled_period_ratio 'sum by (pod) (rate(container_cpu_cfs_throttled_periods_total{namespace="beach",pod=~"beach-k6-.*",container="k6"}[1m])) / sum by (pod) (rate(container_cpu_cfs_periods_total{namespace="beach",pod=~"beach-k6-.*",container="k6"}[1m]))' >> "$work_dir/promql-queries.tsv"
while IFS=$'\t' read -r -u 3 name query; do
  encoded="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$query")"
  kubectl --request-timeout=30s get --raw "$prometheus_api/query_range?query=$encoded&start=$start&end=$end&step=30" > "$work_dir/prom-$name.json"
  python3 - "$name" "$work_dir/prom-$name.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[2])); print(json.dumps(dict(event='prometheus', name=sys.argv[1], data=body)))
assert body['status'] == 'success' and body['data']['result'], 'Missing Prometheus evidence'
PY
done 3< "$work_dir/promql-queries.tsv"
