# 이슈 #3 Rolling Update 실험 결과

## 현재 범위

2026-10-12(KST)에 수행한 `pr4-smoke-fixed` smoke 회차와 `issue-3-rollout-20261012` Rolling Update 회차, 2026-10-13(KST)에 수행한 Redis 장애 시 readiness 검증 회차를 기록한다. 세 회차 모두 현재 설정을 사용했으며, PR 1 시점 기본 설정과 PR 2 조정 설정의 비교 실험은 아니다. 따라서 이 기록만으로 기본·조정 설정 비교 완료를 주장하지 않는다.

## `pr4-smoke-fixed` 실행 조건

| 항목 | 값 |
| --- | --- |
| 대상 | `GET http://beach.beach.svc.cluster.local/api/beaches` (클러스터 내부 Service) |
| 이미지 A → B | `ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest` → `ghcr.io/geonusp/beach_complex-k8s-poc-backend:dd3bf27b380fc9550aeb5fc260c6b83da249c9f2` |
| 요청률 | 초당 1회, k6 `constant-arrival-rate`의 `rollout` 시나리오 |
| 시간 | warm-up 30초, 롤아웃 후 관찰 30초, k6 전체 실행 390초 |
| k6 | `grafana/k6:2.3.0`; Job 매니페스트의 `node-role: observability` 선택자 사용 |
| Beach | 실험 스크립트의 사전 조건: Ready replica 2개 |
| 관찰 시각 | EndpointSlice 기록 기준 2026-10-11 20:07:59~20:09:44 UTC |

`latest`는 가변 태그다. 이번 실행의 이미지 digest와 실제 k6 Pod 노드, App Worker CPU credit은 결과에 수집되지 않았으므로 재현 조건으로 확정하지 않는다.

## 측정 결과

| 지표 | 결과 |
| --- | --- |
| Rolling Update | 성공, 105초 |
| HTTP 요청 | 390건, 원본 JSON의 `http_reqs` 모두 200 |
| 처리량 | 약 1.00 req/s (`http_reqs.rate: 0.9999849`) |
| 5xx / 요청 실패 | 0건 / 0건 (`beach_status_5xx.count: 0`, `http_req_failed.rate: 0`) |
| 누락된 반복 | 1건 (`dropped_iterations.count: 1`) |
| 응답 시간 | 중앙값 6.98ms, p95 15.15ms, 최대 2711.50ms; **전체 390초 구간 기준** |
| 검사 | 780회 통과, 0회 실패 |
| 이미지 원복 | 실험 후 Control Plane의 `kubectl get deployment beach` 결과가 이미지 A(`latest`)임을 확인 |

EndpointSlice는 롤아웃 전 `10.244.0.251:true`, `10.244.1.178:true`였고, 롤아웃 후 `10.244.1.178:false`, `10.244.0.40:true`, `10.244.1.197:true`로 기록됐다. 이전 endpoint 하나가 제외되고 새 endpoint 두 개가 Ready인 최종 상태는 확인되지만, 샘플이 전후 두 시점뿐이므로 **롤아웃 내내 Ready endpoint가 유지됐는지** 또는 그 최소 개수는 이 기록으로 증명할 수 없다.

## `issue-3-rollout-20261012` Rolling Update 회차

| 항목 | 값 |
| --- | --- |
| 실행일 | 2026-10-12 (KST) |
| 이미지 A → B | `ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest` → `ghcr.io/geonusp/beach_complex-k8s-poc-backend:rollout-20261012` |
| 이미지 의미 | B는 현재 소스를 별도 태그로 빌드한 이미지다. 애플리케이션 코드 버전 변경이 아니라 이미지 교체에 따른 Kubernetes 롤아웃 동작을 확인했다. 이미지 digest는 수집하지 않았다. |
| 요청 조건 | `GET /api/beaches`, 클러스터 내부 Service, 초당 1회 |
| 시간 | warm-up 30초, 롤아웃 제한 300초, 관찰 30초, 안전 여유 30초; k6 전체 390초 |
| 롤아웃 결과 | 성공, 126초 |
| HTTP 요청 | 389건, 모두 200 |
| 오류 | 5xx 0건, `http_req_failed.rate` 0 |
| k6 검사 | 778회 통과, 0회 실패 |
| 누락된 반복 | 1건 (`dropped_iterations.count: 1`) |
| 응답 시간 | 중앙값 7.41ms, 평균 26.55ms, p95 21.70ms, p99 126.27ms, 최대 3499.32ms; **전체 390초 구간 기준** |

EndpointSlice 샘플에서 롤아웃 전·시작 시 기존 Ready endpoint 2개가 확인됐다. 교체 중 새 Pod가 `ready=false`인 동안 기존 Ready endpoint가 유지됐고, 최종 샘플에서는 이전 endpoint가 `ready=false`, 새 endpoint 2개가 `ready=true`였다. 이는 롤아웃 중 관찰된 readiness 전환이며, Redis 장애 등을 주입한 별도의 readiness 실패 실험을 대체하지 않는다.

원본 회수 디렉터리는 `.gitignore` 대상이므로, 이 회차의 증거 파일은 문서 디렉터리에도 복사해 보존한다.

## Redis 장애 시 readiness 검증 회차

[실행 조건·단계별 결과·해석](readiness-endpoint/README.md)에 Redis 1 → 0 → 1 replica 전환과 Beach Pod 및 EndpointSlice의 Ready → NotReady → Ready 관찰 결과를 기록했다. 두 Pod는 Running 상태를 유지하고 재시작 없이 복구됐다. 공유 Redis 장애로 준비된 endpoint가 일시적으로 0개가 된 결과이며, 단일 Pod 장애와 사용자 외부 경로의 가용성은 검증하지 않았다.

## 원본 증거

- [raw.json](smoke/pr4-smoke-fixed/raw.json): k6 시계열 원본. SHA-256 `560cb0751a6e2c56e2f50afc95b518a7dd0135460948a491c894961901bfade1`.
- [remote-output.txt](smoke/pr4-smoke-fixed/remote-output.txt): rollout 출력, k6 요약, EndpointSlice 전후 기록. SHA-256 `6dd552512f4157735d62c20352811610344a95574f34cddfe3db4af512540cf6`.
- [issue-3-rollout-20261012/raw.json](issue-3-rollout-20261012/raw.json): k6 시계열 원본. SHA-256 `60dbd51330c9dc2f4218fd478792d6a47de65354a6810f10a9ef99cf8406569a`.
- [issue-3-rollout-20261012/remote-output.txt](issue-3-rollout-20261012/remote-output.txt): 롤아웃 출력, k6 요약, EndpointSlice 샘플. SHA-256 `22f2f05e4b2c5463d96089c439e4b121d789ba780f9197a1d5cdba486ae15b8c`.
- [readiness-endpoint/remote-output.txt](readiness-endpoint/remote-output.txt): Redis 장애 중 Pod·EndpointSlice 전후 출력, 복구 결과 및 앱 로그. SHA-256 `c3b19384fcd45f5b45882df4a648baa6f42055e42aab8ee96c2fe5a5b706c3f0`.
- 원래 로컬 회수 위치: `deploy/k8s/loadtest/results/pr4-smoke-fixed/` (`.gitignore` 대상).
- Rolling Update 실행의 원래 로컬 회수 위치: `deploy/k8s/loadtest/results/issue-3-rollout-20261012/` (`.gitignore` 대상).
- Redis 장애 실행의 원래 로컬 회수 위치: `deploy/k8s/loadtest/results/readiness/20261013T054400Z-5966/` (`.gitignore` 대상).
- SSM의 S3 출력 prefix: smoke 회차는 `rollout/pr4-smoke-fixed/`, Rolling Update 회차는 `rollout/issue-3-rollout-20261012/`이다. 이번 실행들의 Command ID와 전체 객체 URI는 로컬 결과 파일에 기록되지 않았다.

## 해석과 남은 작업

두 회차는 `K6_DURATION` 내장 옵션 충돌 수정 후 `rollout` 시나리오가 설정된 요청률로 실행되고 원본 결과가 회수됨을 보여준다. 단일 요청 경로와 클러스터 내부 호출만 측정했으므로 외부 Ingress 경로의 사용자 체감이나 다른 요청 유형까지 일반화하지 않는다. 또한 전체 구간의 지연 시간만 저장됐으므로 배포 구간만의 p95·p99는 제시하지 않는다.

이슈 #3의 readiness 실패 시 Service의 준비된 endpoint 제외 및 복구 후 재포함은 별도 Redis 장애 실험으로 확인했다. 기본·조정 설정 비교는 이슈 #3의 현재 범위에서 제외하며, 이 smoke 결과를 baseline 또는 tuned 비교 수치로 사용하지 않는다.
