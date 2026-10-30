# 이슈 #6 — Pod 장애 실험 결과 (PR 1)

## 범위와 상태

Related #6. Pod 장애·공통 측정 단계다. 개발 클러스터에서 운영자가 Beach Pod 1개를 삭제하는 실험을 실행했고, 원본 재집계와 최종 상태를 검증했다. 이 문서는 Pod 회차의 결과다. Node 장애·다른 Worker 재배치·최종 복구까지 확인한 최신 결과는 [Node 결과](NODE_RESULTS_20261030.md)에 기록했다.

검증 코드: `b6e9b9cc8c31a2d0dc20f805a2c9bbc8b7915dd1`. 최초 성공 실행 이후 남아 있는 ConfigMap과 충돌하는 반복 실행 오류를 수정한 버전이다.

## 실행 조건과 절차

- 다른 배포·실험·사용자 트래픽이 없는 개발 클러스터에서 실행한다. dev Terraform output, AWS SSM/S3 접근 권한, 로컬 Bash·Terraform·AWS CLI·Python 3가 필요하다.
- 관측성 사전 검사 후 Beach 2/2 Ready, 서로 다른 Ready App Worker에 1개씩, endpoint UID 일치, PostgreSQL·Redis Ready를 검사한다.
- 관측 노드의 `grafana/k6:2.3.0` Job으로 `/api/beaches`에 5 req/s, 420초 부하를 보낸다. 약 2분 기준 구간이 정상인 경우에만 기록한 UID 사전조건으로 Pod 1개를 grace period 0으로 삭제한다.
- 새 UID Ready·생존 Pod 유지·endpoint 복귀를 관찰하고 남은 부하 구간의 오류율과 처리량을 검증한다.

기존 dev state가 있는 저장소 루트의 Git Bash에서 실행한다. 이 명령은 실제 Pod를 삭제한다.

```bash
bash deploy/k8s/scripts/run-pod-failure-experiment.sh --confirm-dev
```

실험을 동시에 실행하지 않는다. 결과 label은 실험 회차 폴더명이며 재사용하지 않는다. Python 3 명령이 `python`인 환경에서는 runner 명령 앞에 `PYTHON=python`을 지정한다.

Windows Git Bash에서 Python 단위 테스트는 별도 전제가 있다. 테스트가 실행하는 자식 Bash와 fixture는 `python3` 실행 파일을 PATH에서 찾으므로, 부모 셸의 alias·함수 또는 runner의 `PYTHON=python`만으로는 해결되지 않는다. `python3` PATH 래퍼를 둔 환경에서 전체 8개가 통과했다. 테스트의 `PYTHON` 지원은 이번 변경에 추가하지 않았다.

## 실행 이력

| 로컬 결과 label | 결과 | 요청 / 실패 | 새 Pod Ready 관찰까지 |
| --- | --- | --- | --- |
| `20261016T173353Z-15583` | 최초 성공 | 2,100 / 0 | 62.61초 |
| `20261016T175738Z-16100` | 준비 단계 실패 | 요청 시작 전 | Pod 삭제 전 중단 |
| `20261020T124057Z-20284` | 수정 후 반복 실행 성공 | 2,101 / 0 | 64.56초 |

준비 단계 실패 회차의 `remote-output.txt` 30행은 `configmaps "beach-k6-failure" already exists`다. 고정 이름을 실행별 이름으로 변경하고, 원격 준비 실패 시 집계기를 호출하기 전에 원래 오류를 표시하도록 수정했다. 최신 회차의 Job/ConfigMap 이름은 `beach-k6-failure-lafhlc`, 원격 종료 상태는 `0`이다. 이전 결과·리소스가 남은 상태의 순차 재실행을 확인했다.

## 최신 회차 UTC 타임라인과 배치

| 사건 | UTC |
| --- | --- |
| 삭제 명령 시작 t0 | `2026-10-20T12:44:29.965971038Z` |
| 새 UID Ready 및 endpoint 정상 상태 관찰 | `2026-10-20T12:45:34.526643144Z` |
| API 안정 30초 창 종료, 복구 구간 시작 | `2026-10-20T12:46:04.526643+00:00` |
| 최종 상태 snapshot | `2026-10-20T12:49:32.029018+00:00` |

| 역할 | Pod | UID | Node |
| --- | --- | --- | --- |
| 삭제 대상 | `beach-5fcc9958d9-rzntx` | `8077144b-9b2c-4f2a-b157-b8f827ff58e5` | `beach-complex-app-2` |
| 생존 | `beach-5fcc9958d9-zfp5w` | `a2a67b6c-2128-4d29-9c27-7a5234304709` | `beach-complex-app-1` |
| 새 Pod | `beach-5fcc9958d9-xw4ht` | `6eaad9c6-63b5-4042-b2ba-c54732bd9c70` | `beach-complex-app-2` |

원본의 snapshot 184개 중 최초·최종 상태를 집계 코드의 `state()`로 검증했다. 최종 Beach Pod 2개 Ready, 생존 UID 유지, 삭제 UID 부재, EndpointSlice의 준비된 UID 집합 일치, PostgreSQL·Redis Ready를 확인했다. 새 Pod는 원래와 같은 Worker에서 교체됐다. 다른 Worker로의 재배치 증거는 Node 실험에서 별도로 확보해야 한다.

## 최신 회차 사용자 영향

| 구간 | 요청 | 실패 | 처리량(req/s) | p95(ms) | p99(ms) |
| --- | ---: | ---: | ---: | ---: | ---: |
| 기준 | 612 | 0 | 5.0083 | 6.568511 | 14.102727 |
| 장애·안정 확인 | 472 | 0 | 4.9915 | 11.757978 | 27.718230 |
| 복구 후 | 1,017 | 0 | 4.9995 | 10.535716 | 24.599466 |

모든 구간에서 HTTP 5xx·연결 실패·dropped iterations는 0이며 요청 수와 duration/실패 표본 수가 일치했다. 전체 2,101건을 원본에서 재집계한 결과가 저장된 `phases.json`과 객체 단위로 일치했다. `passed=true`, `baseline_valid=true`다.

기준은 요청 시작부터 t0 전, 장애 구간은 t0부터 새 Pod Ready 이후 첫 안정 30초 창 종료까지, 복구 구간은 그 이후다. 안정 기준은 오류율 0 및 기준 처리량의 95% 이상이고, 이후 최소 60초를 관찰한다. 따라서 64.56초는 서비스 중단 시간이 아니라 새 Pod 정상 상태를 처음 관찰하기까지의 시간이다. 측정된 요청 실패는 없었다. latency 자체가 기준 수준으로 돌아왔다는 판정은 하지 않는다.

p95/p99는 실패 요청도 포함하는 `http_req_duration` 시각 표본에 nearest-rank를 적용했다. 전체 summary를 장애 구간 지표로 사용하지 않았다.

## 원본 보존과 재현

원본은 저장소에서 제외되는 `deploy/k8s/loadtest/results/issue-6/<label>/`에 있다. `phases-20261016.json`, `phases-20261020.json`은 각 성공 회차의 집계 사본이다. 최신 원본 파일은 21,196,704바이트이며 Git에는 넣지 않았다.

| 실험 회차 폴더명 | 파일 | SHA-256 |
| --- | --- | --- |
| `20261016T173353Z-15583` | `remote-output.txt` | `633ecfb55b685df2af2cf0b37bf804ebd2b81ef25d1158c54f148674bfb98977` |
| `20261016T173353Z-15583` | `phases.json` | `271f2dfdd2ba65c1a7372237af9634ad8d674ff3ce08e6914f05d514d669b793` |
| `20261016T173353Z-15583` | `observability.txt` | `18f6458b9a720877db818fdcd712d542b1feeb954405955c3754fcf26109d806` |
| `20261020T124057Z-20284` | `remote-output.txt` | `b6b5fe45608c1dfb012f57b859b45f2a3cb3b401dc7676e9a3a398d93060150c` |
| `20261020T124057Z-20284` | `phases.json` | `d7b013265fd3c3c3a8c5fb422f375beeac9963dc00a366f293945bb84a26a645` |
| `20261020T124057Z-20284` | `observability.txt` | `5f888e87108fcbd8ca007b93f4c3f350c91640de294eee8096337b186c217e98` |

두 성공 회차의 `ssm-error.txt`는 모두 0바이트다.

```bash
python deploy/k8s/scripts/failure_results.py summarize deploy/k8s/loadtest/results/issue-6/20261020T124057Z-20284/remote-output.txt
```

S3 `rollout/issue-6/<label>/`는 임시 전송 위치이며 Terraform destroy 시 삭제된다. 두 성공 회차의 모든 결과 파일을 각각 `<label>.tar.gz`로 압축해 `C:/Users/pro/.buzz/OUTBOX/ISSUE_6_RAW_EVIDENCE_20261020/`에 별도 보관했다. 각 보관본을 다시 읽어 압축 전 파일별 SHA-256과 일치하는지 확인했다. 같은 폴더의 `MANIFEST.json`에 생성 UTC 시각, 원본 경로, 파일별 해시, 압축본 크기·해시를 기록했다.

이는 같은 PC의 로컬 추가 사본이며 PR 독자가 내려받을 수 있는 외부 보관본은 아니다. destroy나 로컬 원본 정리 전에 두 압축본과 manifest를 영구 외부 보관 위치에 복사하고 다운로드·해시 일치를 확인해야 한다. 외부 보관 위치와 독자 접근 경로는 아직 미확정이다.

## 실패 시 확인

실패 회차의 원본을 삭제하거나 즉시 재실행하지 않는다. SSM 단절 시 원격 실행 종료 여부를 먼저 확인한다. runner는 rollout과 실제 Pod·의존성·EndpointSlice 상태를 확인한다. 복구 명령 호출만으로 복구 완료를 판단하지 않는다. Pod가 Pending이면 이벤트·자원·배치 제약을 확인하고, 정상화하기 전 Node 실험을 시작하지 않는다.

## 한계와 남은 증거

- 5 req/s·단일 경로 Pod 실험이다. 고부하·통계적 편차·여러 runner 동시 실행 검증은 PR 1의 추가 완료 조건이 아니다.
- polling sleep은 2초지만 API 호출·처리 시간이 추가된다. Ready 관찰 시각은 실제 전환 시각과 다르다. API 객체 강제 삭제는 기존 컨테이너 프로세스 종료 증거가 아니다.
- 이번 증거는 Pod API 강제 삭제 후 교체·복구와 해당 부하에서 관측한 사용자 영향이다. 프로세스 즉사·진행 중 요청 보존·Node 장애 내성을 입증하지 않는다. Pod별 요청 수와 실제 프로세스 종료 시각은 기록하지 않아 실패 0건의 원인을 확정할 수 없다. Node 장애·다른 Worker 재배치는 PR 2에서 별도로 검증하며 프로세스 크래시 실험은 PR 2 범위로 추가하지 않는다.
- t0·replacement_ready는 Control Plane의 `date`, k6 요청 표본은 obs-1의 k6 Pod 시계다. 노드 간 시계 오차와 실험 당시 시간 동기화 상태는 미검증이며 오프셋이 있으면 구간별 요청·오류·latency 귀속이 달라질 수 있다. 64.56초의 두 관찰 시각은 모두 Control Plane 시계지만 실제 전환 시각은 아니다.
- 단일 Control Plane이므로 클러스터 전체 HA 검증이 아니다. Node 감지·다른 Worker 재배치는 PR 2 범위다.
- 이번 Grafana 화면은 아직 첨부하지 않았다. 수치는 저장한 k6 원본과 Kubernetes snapshot에 근거한다.
- 원본과 압축 보관본은 Git에서 받을 수 없는 로컬 파일이다. 기존 문서·요약은 `259b91fc`에 포함됐으며, 이번 리뷰 보완은 로컬 문서 변경이다.

## 출처

- [이슈 #6](https://github.com/geonusp/Beach_complex-k8s-poc/issues/6)
- [Pod 강제 삭제](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#forced-pod-termination)
- [EndpointSlice conditions](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/#conditions)
- [k6 JSON output](https://grafana.com/docs/k6/latest/results-output/real-time/json/)

## Node 후속 실험 완료 증거

2026-10-29 UTC 운영자 실행 회차 `node-20261029T233550Z-45508`에서 Node 감지·다른 Worker 재배치·사용자 영향 측정·동일 EC2 최종 복구를 확인했다. 위 본문의 PR 2 미검증 표현은 Pod 실험 당시의 범위다. 현재 #6 결과는 [최신 Node 결과](NODE_RESULTS_20261030.md)를 함께 참조한다. 장애 구간 요청 실패 181/2,249건, PostgreSQL 비영속 재생성과 fingerprint 변경을 기록했다.
