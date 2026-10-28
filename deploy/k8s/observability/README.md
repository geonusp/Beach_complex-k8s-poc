# Kubernetes 관측 스택

이 디렉터리는 이슈 #5의 Prometheus·Grafana 구성을 관리한다.
설치 방식의 근거는 [관측 스택 설치 방식 ADR](../../../docs/adr/observability-stack-installation.md),
Metrics Server의 배치 근거는 [Resource metrics 제공 방식 ADR](../../../docs/adr/resource-metrics-provider.md)에 있다.

| 파일 | 역할 |
| --- | --- |
| `kube-prometheus-stack-values.yaml` | `kube-prometheus-stack` 91.9.0 축소 구성 값 |
| `beach-podmonitor.yaml` | Beach Pod management 포트(8081) scrape 설정 |
| `promql-queries.tsv` | 검증과 대시보드가 함께 쓰는 핵심 PromQL 9개 |
| `dashboards/beach-overview.json` | Grafana `Beach Overview` 대시보드 |

## 설치

`provision-and-deploy.sh`의 마지막 단계(`step 6/6`)에서 자동으로 설치된다. 따로 실행하려면 다음을 실행한다.

```bash
bash deploy/k8s/scripts/install-observability.sh
```

재실행해도 Grafana 관리자 Secret(`monitoring/grafana-admin`)은 바뀌지 않는다.

## 구성요소와 배치

| 구성요소 | 배치 | 설치 |
| --- | --- | --- |
| Prometheus Operator | `obs-1` | `kube-prometheus-stack` |
| Prometheus | `obs-1` | `kube-prometheus-stack` |
| Grafana | `obs-1` | `kube-prometheus-stack` |
| kube-state-metrics | `obs-1` | `kube-prometheus-stack` |
| node-exporter | 모든 노드(DaemonSet) | `kube-prometheus-stack` |
| Metrics Server | `obs-1` | `install-metrics-server.sh` (bootstrap `step 6/6`) |

`obs-1` 고정은 `nodeSelector: node-role: observability`로 한다. node-exporter는 노드 지표를 모으려고 모든 노드에 뜬다.

## 제외한 구성요소

| 구성요소 | 이유 |
| --- | --- |
| Alertmanager, 기본 알림 규칙 | 알림은 이슈 #5 범위 밖이다. |
| etcd, kube-scheduler, kube-controller-manager scrape | kubeadm이 metrics를 `127.0.0.1`에만 바인드해 target이 `down`이 된다. |
| kube-proxy scrape | 기본 metrics bind address가 `127.0.0.1`이라 같은 이유로 제외한다. |

API server, kubelet·cAdvisor, CoreDNS, node-exporter, kube-state-metrics, Beach는 수집한다.

## 보존과 자원

| 항목 | 값 |
| --- | --- |
| scrape·evaluation 간격 | 30s |
| 보존 기간 / 크기 | 2d / 5GB |
| 저장소 | `emptyDir`. 클러스터 destroy와 함께 사라진다. |

| 구성요소 | CPU request | 메모리 request | 메모리 limit |
| --- | --- | --- | --- |
| Prometheus | 200m | 512Mi | 1536Mi |
| Grafana | 50m | 512Mi | 1Gi |
| Prometheus Operator | 50m | 64Mi | 128Mi |
| kube-state-metrics | 20m | 64Mi | 128Mi |

## Grafana 접근

Grafana는 `ClusterIP`이며 외부에 노출하지 않는다. SSM 포트 포워딩으로 접근한다.

1. Control Plane SSM 셸에서 Grafana Service를 포워딩한다.

   ```bash
   sudo kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
   ```

2. 저장소 루트에서 Control Plane 3000 포트를 로컬 3001 포트로 포워딩한다. 로컬 3000은 프론트엔드가 쓰므로 피한다.

   ```bash
   aws ssm start-session --target "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" --document-name AWS-StartPortForwardingSession --parameters portNumber=3000,localPortNumber=3001
   ```

   인스턴스 ID는 Terraform output에서 바로 읽으므로 클러스터를 다시 만들어도 명령을 고치지 않는다.

3. 브라우저에서 `http://localhost:3001`에 접속한다. 사용자는 `admin`이고 비밀번호는 Control Plane에서 확인한다.

   ```bash
   sudo kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
   ```

## 대시보드

`Beach Overview`(uid `beach-overview`)는 `dashboards/beach-overview.json`에서 자동 등록된다.
`install-observability.sh`가 `grafana_dashboard=1` 라벨 ConfigMap(`monitoring/beach-dashboards`)을 만들고 Grafana sidecar가 이를 읽는다.
Grafana 저장소도 클러스터와 함께 사라지므로 저장소의 JSON이 원본이다.

수정 절차:

1. Grafana에서 대시보드를 수정한다.
2. **Export → Export as JSON**에서 "Export the dashboard to use in another instance"를 끄고 내보낸다.
3. `uid: beach-overview`를 유지한 채 `dashboards/beach-overview.json`을 교체한다.
4. 모든 패널의 `expr`가 `promql-queries.tsv`의 쿼리와 같아야 한다. 쿼리를 바꾸면 TSV도 함께 바꾼다. `test-bootstrap-scripts.sh`가 일치 여부를 검사한다.

## 검증

```bash
bash deploy/k8s/scripts/verify-observability.sh
```

SSM Run Command 한 번으로 다음을 출력한다. Prometheus는 API server service proxy로 조회하므로 포트 포워딩이 필요 없다.

- Beach Service ClusterIP로 `/api/beaches` 요청 30개를 보내고 scrape 두 번(65초)을 기다린다
- `kubectl top node`, `kubectl top pod -A`
- `monitoring` 네임스페이스 Pod 배치
- Prometheus active target(`job`, `health`, `scrapeUrl`, `lastError`)
- `promql-queries.tsv`의 쿼리별 결과

target이 하나라도 `up`이 아니거나 target이 없거나, 쿼리 결과가 비었으면 실패한다.
`NaN`도 원칙적으로 실패하지만, 전체 `http_request_rate`가 0일 때의 `http_5xx_ratio`·`http_p95_seconds`만 측정 불가 WARNING으로 기록하고 진행한다. 원본 `NaN`을 0으로 바꾸지 않으며, 이 분기의 통과를 오류율 0·지연시간 측정 성공으로 해석하지 않는다. 요청률이 양수인 경우와 다른 지표의 `NaN`은 실패한다.

## 부하를 준 상태에서 지표 확인

검증 스크립트의 요청 30개는 수집 경로 확인용이다. 일정한 부하에서 지표를 보려면 `run-load.sh`로 k6 부하를 준 뒤 바로 검증한다.

```bash
bash deploy/k8s/scripts/run-load.sh 5 300 <label>
```

```bash
bash deploy/k8s/scripts/verify-observability.sh | tee <저장할 경로>
```

| 인자 | 기본값 | 의미 |
| --- | --- | --- |
| `request-rate` | 5 | 초당 요청 수 (k6 `constant-arrival-rate`) |
| `duration-seconds` | 300 | 부하 시간 |
| `label` | UTC 시각과 PID | 결과 폴더 이름 |

- 롤아웃 실험과 같은 k6 Job(`deploy/k8s/loadtest/rollout.js`, `k6-job.yaml`)으로 `GET /api/beaches`를 호출한다. Beach Deployment 이미지는 바꾸지 않는다.
- 터미널에는 `load_started`·`load_finished` 시각과 k6 요약 JSON 한 줄만 출력한다. Grafana 캡처의 시간 범위로 이 두 시각을 쓴다.
- 전체 출력(k6 진행 로그, 요청 단위 원본 JSON)은 SSM 인라인 출력 한도를 넘기므로 실험 결과 S3 버킷(`rollout/load/<label>`)을 거쳐 `deploy/k8s/loadtest/results/load/<label>/remote-output.txt`에 저장한다. 이 경로는 `.gitignore` 대상이다.
- 롤아웃 실험과 Job 이름(`beach-k6-rollout`)이 같으므로 두 스크립트를 동시에 실행하지 않는다.
- `rate()` 쿼리는 5분 창을 쓴다. 부하를 300초 주고 바로 검증해도 검증 스크립트의 65초 대기 때문에 창의 일부만 부하 구간이라 요청률이 설정값보다 낮게 나온다.

이슈 #5의 실행 결과와 해석은 [docs/experiments/issue-5](../../../docs/experiments/issue-5/README.md)에 있다.

## 한계

- **8081은 클러스터 내부에서 접근할 수 있다.** Service·Ingress에는 노출하지 않지만 NetworkPolicy가 없어 다른 Pod가 Pod IP로 `/actuator/**`에 접근할 수 있다.
- **kubelet scrape는 TLS 검증을 건너뛴다.** kubelet serving 인증서는 클러스터 CA가 발급하지만(#24), 차트 기본값 `insecureSkipVerify: true`를 유지했다.
- **control plane 구성요소 지표가 없다.** etcd·scheduler·controller-manager는 수집하지 않는다.
- **지표는 클러스터와 함께 사라진다.** 증거는 `verify-observability.sh` 출력과 Grafana 화면으로 따로 남긴다.
- **Beach target은 PR #27 이후 이미지에서만 `up`이다.** 그 전 이미지는 `/actuator/prometheus`가 없어 404로 `down`이 된다.
