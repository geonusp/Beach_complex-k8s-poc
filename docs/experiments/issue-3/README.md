# 이슈 #3 Rolling Update 실험 결과

## 현재 범위

2026-10-12(KST)에 수행한 `pr4-smoke-fixed` 단일 회차를 기록한다. 이는 조정된 현재 설정에서 실험 도구와 결과 회수를 검증한 smoke 실험이며, PR 1 시점 기본 설정과 PR 2 조정 설정의 비교 실험은 아니다. 따라서 이 기록만으로 이슈 #3의 기본·조정 설정 비교 완료를 주장하지 않는다.

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

## 원본 증거

- [raw.json](smoke/pr4-smoke-fixed/raw.json): k6 시계열 원본. SHA-256 `560cb0751a6e2c56e2f50afc95b518a7dd0135460948a491c894961901bfade1`.
- [remote-output.txt](smoke/pr4-smoke-fixed/remote-output.txt): rollout 출력, k6 요약, EndpointSlice 전후 기록. SHA-256 `6dd552512f4157735d62c20352811610344a95574f34cddfe3db4af512540cf6`.
- 원래 로컬 회수 위치: `deploy/k8s/loadtest/results/pr4-smoke-fixed/` (`.gitignore` 대상).
- SSM의 S3 출력 prefix: `rollout/pr4-smoke-fixed/`. 이번 실행의 Command ID와 전체 객체 URI는 이 로컬 결과 파일에 기록되지 않았다.

## 해석과 남은 작업

이번 회차는 `K6_DURATION` 내장 옵션 충돌을 고친 뒤 `rollout` 시나리오가 초당 1회로 실행되고 원본 결과가 회수됨을 보여준다. 단일 요청 경로와 클러스터 내부 호출만 측정했으므로 외부 Ingress 경로의 사용자 체감이나 다른 요청 유형까지 일반화하지 않는다. 또한 전체 구간의 지연 시간만 저장됐으므로 배포 구간만의 p95·p99는 아직 제시할 수 없다.

이슈 #3의 남은 결과는 동일한 조건의 기본·조정 설정 비교 회차와 readiness 실패 시 endpoint 제외 실험이다. 비교 회차를 수행하기 전까지 이 smoke 결과를 baseline 또는 tuned 비교 수치로 사용하지 않는다.
