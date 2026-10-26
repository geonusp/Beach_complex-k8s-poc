# 이슈 #4 — HPA 실험 실행 결과

2026-10-26 사용자 smoke 재실행 이후 baseline·load·stress·extreme 실측과 결과 분석을 완료했다. CPU requests 조정 근거, HPA 확장·축소, 대표 load 반복의 미확장 결과 및 최종 복구 확인은 아래 회차별 기록에 남겼다. 앞선 실패·미실행 표기는 해당 시점의 이력이며 최신 상태와 구분한다.

## 확인한 실행

결과 원본 경로는 저장소 루트 기준이다. 아래 UTC 시각은 결과 디렉터리 라벨 기준이며 부하 시작 시각을 의미하지 않는다.

| UTC 라벨 | 프로필 | 확인 결과 | 원본 디렉터리 |
|---|---|---|---|
| 2026-10-21T16:27:23Z | smoke | SSM 전송 전 Argument list too long으로 실패 | deploy/k8s/loadtest/results/issue-4/hpa-20261021T162723Z-40184/ |
| 2026-10-21T16:29:40Z | baseline | SSM 전송 전 Argument list too long으로 실패 | deploy/k8s/loadtest/results/issue-4/hpa-20261021T162940Z-40738/ |
| 2026-10-21T16:54:49Z | smoke | 원격 전송 후 노드 식별 정보 사전 검사 실패 | deploy/k8s/loadtest/results/issue-4/hpa-20261021T165449Z-47553/ |

마지막 smoke의 remote-output.txt에는 다음 증거가 있다.

- 1행: profile=smoke
- 2934행: ValueError: Terraform and Kubernetes node identity differ
- 5863행: experiment_exit_status=1
- ssm-error.txt는 0바이트이며 summary.json도 0바이트다. 전송 오류가 없다는 사실만으로 실험 성공으로 판단하지 않는다.
- final_state_verified 표식은 확인되지 않았다. 출력된 수동 복구 안내는 복구 완료의 증거가 아니다.

## 확인 범위와 원본 보존

위 기록은 보존된 로컬 파일을 확인한 결과다. 이번 문서 정리에서 클러스터 재실행이나 복구 검증은 하지 않았다. 실패 원본을 보존하며, 다른 위치에서 수행한 후속 실행 결과가 있는지는 이 문서로 단정하지 않는다.

구현·실행 안내: C:/Users/pro/Documents/GitHub/BeachWorkspace/Beach_complex-k8s-poc/tempdocs/issue-4/HPA_IMPLEMENTATION.md

관련 PR: https://github.com/geonusp/Beach_complex-k8s-poc/pull/33

## 2026-10-26 사용자 smoke 실행

원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T191209Z-1423/`. 실행 코드는 `27e52517` 위 Control Plane 라벨 검사 수정이 있는 미커밋 상태다. 원본에 실행 커밋·diff가 직접 기록된 것은 아니므로 채팅 작업 기록과 구분한다.

- k6 요청 301건, 오류율 0, dropped iterations 0, 원본 표본 완전성 확인.
- p50 2.580142ms, p95 4.182485ms, p99 11.646769ms. `summary.json`의 nearest-rank 방식·전체 요청 범위 값이다.
- k6 부하 완료 후 `k6_throttled_seconds` Prometheus 결과가 비어 `Missing Prometheus evidence`로 중단됐다. `experiment_exit_status=1`, `passed=false`이므로 전체 smoke 성공 기록이 아니다.
- `final_state_verified=2026-10-26T19:15:10.653545271Z`가 기록됐다. runner의 Pod·endpoint·API 최종 확인은 통과했다. smoke는 HPA를 생성하지 않으므로 확장·축소 증거가 아니다.
- 읽기 전용 후속 조회에서 실제 kubelet ServiceMonitor가 `container_cpu_cfs_throttled_seconds_total`을 drop하는 것을 확인했다. 동일 구간의 throttled CFS periods / 전체 periods 비율은 표본 5개가 0으로 조회됐다. 빈 seconds 결과를 0으로 간주한 것이 아니다.
- 후속 runner 수정은 `k6_throttled_period_ratio`(0~1)를 수집한다. throttling 시간(초)과 다른 지표이며 누락 결과에 대한 실패 판정은 유지한다. 이 회차 분석 당시 수정 후 smoke는 미실행이었으며, 이후 `hpa-20261026T192521Z-3851`에서 301건·HTTP200·최종 복구와 전체 판정 통과를 확인했다. 상세는 아래 수정 후 smoke 성공 기록을 따른다.

차트 기본 규칙: https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-91.9.0/charts/kube-prometheus-stack/values.yaml

지표 정의: https://github.com/google/cadvisor/blob/master/docs/storage/prometheus.md

### 앞선 실행의 중단 보고 정정

`hpa-20261026T190546Z-1764`는 로컬 도구 세션 종료 후 하위 프로세스가 계속 실행됐다. 원본에서 19:07:29Z 부하 시작·19:08:44Z 부하 완료·19:08:48Z 최종 복구 확인을 확인했다. 같은 throttling seconds 지표 누락으로 종료값 1이다. 이전 채팅의 "k6가 시작되지 않았다"는 보고를 정정한다. 이 기록을 성공 회차로 처리하지 않는다.

## 2026-10-26 수정 후 사용자 smoke 성공

원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T192521Z-3851/`. 로컬에 보존된 파일이며 외부 독자가 직접 접근할 수 있는 공개 첨부물은 아니다.

| 항목 | 결과 |
| --- | --- |
| 프로필 | smoke, 기본 5 req/s·60초 |
| 원본 요청 수 / k6 summary 요청 수 | 301 / 301 |
| HTTP 응답 | 200 301건, 실패 0건 |
| dropped iterations | 0 |
| 처리량 | 5.004640589918368 req/s |
| p50 / p95 / p99 | 2.525794 / 4.564186 / 16.806064 ms |
| k6 CPU | 0.007885054934210527, 0.015164326511151169 cores |
| k6 throttled period ratio | 0.006428106285481429, 0.0021194425008512433 (0~1 비율, NaN 아님) |
| 최종 복구 확인 UTC | 2026-10-26T19:28:22.422610158Z |
| 종료값 / 요약 판정 | `experiment_exit_status=0`, `passed=true` |

원본 Point 합계·k6 summary·저장된 summary의 요청 수가 일치하고, 오류율·duration 표본 완전성을 확인했다. 지연시간은 전체 요청의 nearest-rank 방식이다. SSM 오류 파일은 0바이트다. CPU와 throttling 지표는 해당 k6 Pod `beach-k6-hpa-n578ug-5d94s`의 Prometheus 원본 표본이며, 전체 시간의 최대값으로 확대하지 않는다.

사용자 실행 당시 작업 기록은 `feat/4-hpa-measurement`의 기준 HEAD `27e52517` 위 3파일 미커밋 수정 상태다. 실행 원본에 별도 커밋·diff snapshot은 없으므로 깨끗한 기준 커밋의 결과로 취급하지 않는다.

다음 단계는 baseline 5분 측정 → 실제 CPU·memory를 근거로 requests 검토 → 필요 시 변경·배포 후 baseline 재측정이다. 그 검토가 끝난 뒤 load/stress와 같은 조건 반복 비교를 진행한다. 이번 smoke 성공만으로 이슈 #4 완료를 선언하지 않는다.

## 2026-10-26 최초 baseline 및 requests 검토

원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T193217Z-4037/`. 사용자가 실행했으며 로컬 원본은 외부에서 직접 접근할 수 없다. 실행 당시 작업 기록은 앞선 smoke와 동일한 기준 HEAD 위 3파일 미커밋 변경 상태이며, 실행 원본 자체에는 코드 diff snapshot이 없다.

- `passed=true`, `experiment_exit_status=0`, `final_state_verified=2026-10-26T19:39:22.646107070Z`.
- 원본 요청 수·k6 summary·저장 summary 모두 1,500건. HTTP 200 1,500건, 실패·dropped iterations 0.
- 처리량 5.000400694530828 req/s, p50 2.553697ms, p95 4.224806ms, p99 11.221794ms(전체 요청, nearest-rank).
- 실제 실행 requests는 CPU 250m·memory 512Mi, limits는 CPU 1·memory 1Gi였다.

| Pod 끝 이름 | Metrics Server CPU 관측 최대 | Prometheus CPU 관측 최대(rate 5분) | Prometheus memory working set 관측 최대 |
| --- | ---: | ---: | ---: |
| xw4ht | 40.809697m | 13.035926m | 455962624 bytes (434.84Mi) |
| zfp5w | 15.104386m | 6.782250m | 461975552 bytes (440.57Mi) |

Metrics Server는 Pod별 32개 표본, Prometheus는 Pod별 11개 표본이다. 각 CPU 표본은 집계 구간이 있으므로 순간 최대 CPU를 의미하지 않는다. 5분 rate 초기 표본은 부하 이전 구간을 포함하므로 짧은 구간 표본과 혼동하지 않는다. Pod 간 부하 불균형도 있어 두 Pod 평균만으로 요청량을 정하지 않는다.

### 다음 회차를 위한 requests 변경안

`deploy/k8s/app/deployment.yaml`의 CPU requests를 250m → 100m으로 변경했다. 이는 이번 5 req/s baseline의 관측 최대 40.81m에 약 2.45배 여유를 둔 실험용 시작값이다. memory requests는 관측 최대 440.57Mi에 약 71Mi 여유가 있는 512Mi를 유지한다. limits는 변경하지 않는다. 저부하·이미 실행 중인 JVM의 5분 관측이며 시작 구간이나 고부하 요구량의 확정 근거는 아니다.

HPA CPU 목표 60%는 요청량 250m일 때 평균 Pod CPU 150m, 100m일 때 60m에 해당한다. 이 값은 HPA 계산상의 목표이며 정확히 그 시점에 확장된다는 보장은 아니다. 새 requests로 실제 배포·rollout·endpoint/API를 확인한 뒤 baseline 재측정, 이후 load/stress로 사용량·오류·확장·축소를 검증한다. 현재는 로컬 매니페스트만 변경했으며 실제 클러스터 적용은 미실행이다. 문제가 생기면 CPU requests를 기존 250m으로 되돌리고 rollout·endpoint/API 복구를 확인한다.

공식 관계: https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/

Reviewer의 읽기 전용 검토에서 requests 변경안의 blocking finding은 없었다. baseline 중 HPA 확장 가능성을 언급한 비차단 의견은 실행 조건과 대조해 정정했다. 기존 HPA는 사전 검사에서 거부하며 HPA 생성은 load/stress에 한정되므로 정상 baseline은 HPA 없이 2 replicas 고정이다. 낮아진 requests에 따른 HPA 민감도와 새 Pod JVM 시작 CPU는 load/stress에서 구분해 관측한다. Reviewer는 원시 표본 재계산·실제 적용·테스트를 수행하지 않았다.

## requests 적용 후 baseline 사전 검사 중단 및 처리 변경

사용자 출력에서 CPU requests 적용과 rollout 완료를 확인했다. 후속 회차 `hpa-20261026T194824Z-4588`은 실제 k6 시작 전 `verify-observability.sh`의 `http_5xx_ratio returned NaN`으로 중단됐다. SSM `0b57fd90-ce1a-4ff8-bc7a-a519fd1559d9` stdout은 전체 요청률 0·오류율 NaN이다. 이 회차를 5xx 발생이나 baseline 성공으로 해석하지 않는다.

사용자 요청에 따라, 사전 검사의 전체 요청률이 0인 경우에만 HTTP 오류율·p95의 NaN을 측정 불가 WARNING으로 기록하고 진행한다. 원본 NaN은 보존하며 0으로 변환하지 않는다. 요청률이 양수인 경우의 NaN 및 다른 필수 지표 이상·빈 결과·down target은 실패한다. 사전 검사 통과는 오류율0이나 p95 측정 성공의 증거가 아니다. 실제 baseline은 k6 원본·summary로 판정한다.

관련 로컬 관측성 테스트 6개와 변경 셸 문법 검사가 통과했고 Reviewer blocking finding은 없었다. bootstrap 전체는 수정 전 HEAD에서도 재현되는 Windows Python 의존성 검사 fixture 실패로 미통과다. 수정 후 실제 baseline은 아직 재실행하지 않았다.

## CPU 100m 적용 후 baseline 성공

사용자 실행 원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T200044Z-7014/`. initial_state의 실제 Deployment requests는 CPU 100m·memory 512Mi이며 limits는 CPU 1·memory 1Gi다.

- 원본 Point 합계·k6 summary·저장 summary 모두 1,501건. HTTP 200 1,501건, 실패·dropped iterations 0, 표본 완전성 확인.
- 처리량 5.001074046661434 req/s, p50 4.969817ms, p95 9.387466ms, p99 28.031737ms(전체 요청, nearest-rank).
- `passed=true`, `experiment_exit_status=0`, `final_state_verified=2026-10-26T20:07:55.568464069Z`.
- Prometheus CPU rate 5분 관측 최대는 Pod별 32.783445m·33.052814m, memory working set 관측 최대는 420831232·419831808 bytes다. 각각 11개 표본이며 순간 최대나 시작 구간의 최대값으로 해석하지 않는다.
- k6 CPU 표본 최대 0.016940376200728826 cores, throttled period ratio 최대 0.006289308176100629. 각 10개 표본이다.
- 사전 관측성 확인 출력에 NaN·WARNING은 없었다. 따라서 이번 성공은 새 NaN 허용 분기가 실제로 실행됐다는 증거는 아니다.

최초 CPU250m baseline의 p95 4.224806ms·p99 11.221794ms보다 이번 수치는 높다. Pod 교체·JVM 상태·시점 등이 달라 requests 변경만을 원인으로 단정하지 않는다. 현재 CPU100m을 다음 load/stress를 위한 실험값으로 유지하고, 반복 비교와 부하 중 자원·오류·replica 관측으로 평가한다. baseline은 HPA 없이 실행하므로 확장·축소 검증은 아직이다. 다음은 load 기본40 req/s·600초이며, 이후 HPA 축소와 최종 복구를 별도로 기다린다.

## load 40 req/s 실행 결과

사용자 실행 원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T201102Z-7602/`.

- `passed=true`, `scale_out_observed=true`, `scale_down_observed=true`, `experiment_exit_status=0`.
- 원본 Point 합계·k6 summary·저장 summary 모두 24,001건. HTTP 200 24,001건, 실패·dropped iterations 0. 모든 비교 구간의 표본 완전성을 확인했다.
- 4 Ready 관측 UTC: 2026-10-26T20:14:19.768414Z. 이후 20:26:49.851625Z에 3개, 20:27:52.269255Z에 ready/current/desired 모두 2개를 관측했다. 축소 관측은 정리 단계의 강제 2개 설정 이전이다.
- 최종 Pod·endpoint·API 복구 확인 UTC: 2026-10-26T20:31:48.913074108Z. SSM 오류 파일은 0바이트다.

| 구간 | 요청 수 | 실패율 | 처리량(req/s) | p50(ms) | p95(ms) | p99(ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 전체 | 24001 | 0 | 40.000591 | 2.923282 | 7.222153 | 18.761568 |
| 최초 Ready 확장 관측 전 | 3705 | 0 | 40.006981 | 3.708512 | 9.254689 | 28.991471 |
| 최초 Ready 확장 관측 후 | 20296 | 0 | 39.999425 | 2.835375 | 6.870626 | 17.445707 |

지연시간은 전체 요청의 nearest-rank 방식이며 구간 경계는 10초 주기 replica 관측을 사용한다. 확장 후 지연시간 감소가 관측됐지만 JVM·시간 경과 등의 영향과 분리한 인과 검증은 아니다. constant-arrival-rate 40 req/s를 지정했고 확장 전부터 그 부하를 처리했으므로 처리량이 약40으로 유지된 것을 병목이나 확장 효과 부재로 단정하지 않는다. 이번 회차만으로 최대 수용량 증가를 입증하지 않는다. 다음은 stress 기본80 req/s·600초이며, 같은 조건 반복 및 편차 비교는 아직 남아 있다.

## stress 80 req/s 실행 결과 및 1차 비교

사용자 실행 원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T203244Z-8229/`.

- `passed=true`, `scale_out_observed=true`, `scale_down_observed=true`, `experiment_exit_status=0`.
- 원본 Point 합계·k6 summary·저장 summary 모두 48,001건. HTTP 200 48,001건, 실패·dropped iterations 0. 비교 구간별 표본 완전성을 확인했다.
- Ready 2→3→4를 관측했다. 20:36:01.518565Z에 Ready 3개, 20:36:23.338592Z에 Ready/current/desired 모두4개다. 이후 20:49:14.891041Z에 3개, 20:49:35.666984Z에 모두2개를 관측했다. HPA 축소는 정리 단계 전에 관측됐다.
- 최종 Pod·endpoint·API 복구 확인 UTC: 2026-10-26T20:57:18.560192541Z. SSM 오류 파일은 0바이트다.
- k6 CPU 최대 관측값 0.13637490661393098 cores, throttled period ratio 최대 관측값 0.0061349693251533735(각21표본). 순간 최대나 부하 생성기의 용량 한계로 확대하지 않는다.

| 구간 | 요청 수 | 실패율 | 처리량(req/s) | p50(ms) | p95(ms) | p99(ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 전체 | 48001 | 0 | 80.001099 | 2.447789 | 5.942933 | 16.435394 |
| 최초 Ready 확장 관측 전 | 7453 | 0 | 80.012936 | 2.552176 | 5.561275 | 13.606425 |
| 최초 Ready 확장 관측 후 | 40548 | 0 | 79.998924 | 2.424089 | 5.995008 | 16.819451 |

구간 경계는 최초 Ready가 2개보다 많아진 관측 시점(3 Ready)이다. 모든 Pod가4개 Ready가 된 시점과 다르다. stress에서 확장 후 p95/p99는 확장 전보다 높으므로 HPA가 지연시간을 일관되게 줄였다고 결론내리지 않는다. 처리량은 지정한80 req/s를 유지했고 최대 수용량은 측정하지 않았다.

| CPU100m 기준 1차 프로필 | 요청 수 | 실패율 | p50(ms) | p95(ms) | p99(ms) | HPA 확장·축소 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| baseline 5 req/s | 1501 | 0 | 4.969817 | 9.387466 | 28.031737 | 미적용 |
| load 40 req/s | 24001 | 0 | 2.923282 | 7.222153 | 18.761568 | 2→4→2 |
| stress 80 req/s | 48001 | 0 | 2.447789 | 5.942933 | 16.435394 | 2→3→4→3→2 |

여기까지 CPU100m의 baseline/load/stress 1차 실측이다. 부하별 시간·JVM 상태가 다르고 동일 조건 반복 편차는 아직 확보하지 않았으므로 #4 전체 완료로 처리하지 않는다. 기존 계획대로 CPU100m·memory512Mi·동일 이미지/요청률/기간을 유지해 baseline→load→stress를 한 차례 더 실행한 뒤 CPU credit·Pod 배치·부하 생성기 지표와 함께 비교한다. 실제 실행은 사용자가 직접 수행한다.

### 반복 범위 정정

#4 최신 본문은 동일 조건 반복·편차 기록을 요구하지만 모든 프로필의 2회 실행을 지정하지 않는다. baseline/load/stress 전체 반복은 구현 계획에서 넓게 잡은 범위였다. 대표 load(40 req/s·600초)를 같은 CPU100m·memory512Mi 등 설정으로 1회 더 실행해 기존 load와 비교하는 최소 범위로 줄인다. baseline·stress는 각1회 결과로 남기고, 회차 간 CPU credit·노드 배치·이미지·부하 생성기 조건 차이는 별도로 기록한다. 2회 비교만으로 통계적 재현성을 보장하지 않는다.

근거: https://github.com/geonusp/Beach_complex-k8s-poc/issues/4

## 대표 load 반복 결과: 요청 처리·복구 완료, HPA 확장 미관측

사용자 실행 원본: `deploy/k8s/loadtest/results/issue-4/hpa-20261026T210506Z-9127/`. 원본 재계산 결과 요청 24,001건, 실패율0, dropped iterations 0, 표본 완전성 확인. 처리량40.003837 req/s, p50 2.261418ms, p95 3.886975ms, p99 11.695912ms다. 첫 load 대비 p95는46.18%, p99는37.66% 낮다.

`experiment_exit_status=0`, `final_state_verified=2026-10-26T21:20:52.810567607Z`이며 당시 2 replicas·endpoint·API 복구와 임시 Job/HPA/ConfigMap 삭제를 확인했다. 현재 클러스터를 직접 조회한 것은 아니다.

이번에는 Ready/current가 계속2개여서 `scale_out_observed=false`, `scale_down_observed=false`, `passed=false`다. 로컬 summarize가 load의 확장·축소 필수 조건을 충족하지 못해 `experiment incomplete`를 출력했다. 요청 처리 성공과 HPA 실험 통과를 구분하며 원본 판정은 유지한다.

두 회차의 초기 Beach Pod 이름·노드 배치·이미지 digest·requests(100m/512Mi)는 일치한다. 요청 설정은40 req/s·600초다. HPA CPU utilization 관측 범위는 첫 load 3~242%(88표본), 반복9~64%(59표본)로 달랐다. 목표60%와 기본 tolerance 10%라면 반복 최대64%는 확장하지 않는 범위에 부합한다. 실제 controller tolerance 및 CPU 차이의 원인은 미확인이다. JVM 상태·CPU credit·자원 간섭을 분리한 인과 검증은 아니다.

대표 load 반복·편차 자료는 확보했으나 확장·축소의 반복 재현은 확인되지 않았다. 이번 회차를 HPA 성공으로 바꾸거나 #4 전체 완료로 처리하지 않는다. 추가 실험은 이 차이를 검토한 뒤 결정한다.

근거: 위 회차의 `summary.json`, `remote-output.txt`; `deploy/k8s/scripts/hpa_results.py`, `lib/hpa-remote.sh`; [Kubernetes HPA 공식 문서](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/).

## extreme 프로필 추가 요청

사용자 요청으로 별도 `extreme` 프로필을 추가한다. 기본 요청률120 req/s·600초 지속 부하이며 load/stress와 같은 CPU HPA, 중단 임계값, 원본 보존 및 복구 경로를 사용한다. 기존1..200 요청률 제한을 유지하고 일반 suite에 자동 추가하지 않는다. 구현·로컬 검증 완료 후 사용자가 유휴 dev 환경과 이전 복구 완료를 확인하고 다음 명령으로 개별 실행한다.

```bash
bash deploy/k8s/scripts/run-hpa-experiment.sh --confirm-dev extreme
```

120 req/s는 앞선 stress80의1.5배인 실험 시작값이며 확장을 보장하지 않는다. 오류율5% 미만·p95 2초 미만 기준의30초 이후 평가 중단과 dropped iterations0 조건을 재사용한다. 결과는 실행별 고유 UTC 라벨 폴더에 보존한다. 실패 시 후속 부하를 시작하지 않고 `remote-output.txt`의 복구 요청과 `final_state_verified`를 구분해 확인한다. 최종 복구 표식이 없으면 임시 Job/HPA/ConfigMap과2 replicas·endpoint·API를 확인하는 기존 수동 복구 안내를 따른다. 현재 extreme 실제 실험은 미실행이다.

## extreme 120 req/s 실측 통과

사용자가 실행한 `hpa-20261026T214248Z-14716/` 원본을 HEAD `b84b455b`에서 재계산해 저장 summary와 전체 일치를 확인했다. 위 미실행 기록 이후 실제 실행·완료한 결과다.

- HTTP200·원본 요청·k6 summary·저장 summary 모두71,999건. 실패율0, dropped iterations0, 모든 구간 표본 완전성 확인.
- passed=true, scale_out_observed=true, scale_down_observed=true, experiment_exit_status=0.
- Ready2→3→4→3→2. 최초3 Ready21:46:03.012966Z,4 Ready21:46:23.832776Z. 부하 완료21:54:34.112492756Z 후21:59:35.792825Z에3개,21:59:46.174226Z에 ready/current/desired 모두2개를 관측했다.
- HPA 축소 관측은 recovery_requested21:59:58.122935984Z 이전이다. 종료 당시2 replicas·endpoint·API 복구 확인은 final_state_verified22:11:21.887245289Z다. 현재 클러스터 상태를 직접 조회한 결과는 아니다.

| 구간 | 요청 수 | 처리량 req/s | 실패율 | p50 ms | p95 ms | p99 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 전체 | 71999 | 120.013132 | 0 | 2.357873 | 5.872470 | 21.175062 |
| 최초 Ready 확장 관측 전 | 11172 | 120.090892 | 0 | 2.413527 | 5.863514 | 17.474039 |
| 최초 Ready 확장 관측 후 | 60827 | 119.998860 | 0 | 2.349530 | 5.876995 | 21.880962 |

k6 CPU 최대 관측0.215760 cores, throttled period ratio 최대0.009728(각21표본).
구간 경계는 최초3 Ready 관측이며 전체4 Ready 시점이 아니다. 확장 후 p99가 더 높으므로 지연 개선을 주장하지 않는다. 최대 수용량과 동일40 req/s에서의 확장 반복 재현성도 이번 결과로 입증하지 않는다. 앞선40 req/s 미확장 기록은 그대로 보존한다.

근거: 해당 회차 summary.json·remote-output.txt, hpa_results.py·lib/hpa-remote.sh; [Kubernetes HPA 공식 문서](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/).

### 도입 목적과 최종 성과 표현

HPA 도입 목적은 트래픽 증가 시 앱 처리 용량을 늘려 과부하·병목에 대응하는 것이다. Pod 증가에 따른 개별 요청 지연 단축을 필수 성공 조건으로 두지 않는다. 이번 성과는 "CPU 기반 HPA를 구성해120 req/s 부하에서 앱 Pod2→4 확장과 부하 종료 후2개 축소를 확인했으며, 해당 회차71,999건을 요청 실패 없이 처리했다"로 표현한다. 같은 부하의2 replicas 고정 대조 실험은 없으므로 HPA가 병목을 방지한 인과 효과나 처리 한계 증가량을 입증했다고 표현하지 않는다.
