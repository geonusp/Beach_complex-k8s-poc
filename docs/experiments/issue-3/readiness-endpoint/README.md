# 이슈 #3 Redis 장애 시 readiness 및 EndpointSlice 검증

## 실험 조건

| 항목 | 값 |
| --- | --- |
| 실행일 | 2026-10-13 05:44 UTC (2026-10-13 14:44 KST) |
| 실행 방식 | 로컬 `bash deploy/k8s/scripts/run-readiness-experiment.sh` → SSM Run Command → Control Plane `kubectl` |
| namespace | `beach` |
| 앱 이미지 | `ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest` (가변 태그; digest 미수집) |
| Redis | Deployment의 원래 desired/Ready replica 1/1, 장애 중 0/0, 복구 후 1/1 |
| Beach | Deployment 2/2 Ready, 두 Pod 모두 재시작 0회 |
| 실험 대상 | `readinessState,redis`를 포함한 readiness group과 Beach Service EndpointSlice |
| 원본 파일 | [remote-output.txt](remote-output.txt) |
| 원본 SHA-256 | `c3b19384fcd45f5b45882df4a648baa6f42055e42aab8ee96c2fe5a5b706c3f0` |

## 단계별 관찰

| 단계 | 관찰 시각 (UTC) | Beach Pod 상태 | EndpointSlice 상태 |
| --- | --- | --- | --- |
| before | 05:44:05 | `beach-5d79ddb666-5c4p9`, `beach-5d79ddb666-gfhps` 모두 `1/1 Running`, 재시작 0 | `10.244.0.121`, `10.244.1.5` 모두 `ready: true`, `serving: true`, `terminating: false` |
| during | 05:44:33~34 | 같은 두 Pod 모두 `0/1 Running`, 재시작 0 | 같은 두 주소 모두 `ready: false`, `serving: false`, `terminating: false` |
| after | 05:44:45 | 같은 두 Pod 모두 `1/1 Running`, 재시작 0 | 같은 두 주소 모두 `ready: true`, `serving: true`, `terminating: false` |

05:44:06에 Redis를 0 replica로 축소했다. 05:44:34에 두 Pod의 readiness 실패와 준비된 endpoint 0개를 확인하고 Redis를 원래 1 replica로 복구했다. Redis rollout 성공 후 05:44:45에 Beach Pod 및 endpoint 재포함을 확인했다. 원본 출력의 마지막에는 `PASS: readiness failure, endpoint exclusion and recovery observed`, `readiness_exit_status=0`이 기록됐다.

장애 주입부터 제외 확인까지 약 28초, 복구 시작부터 재포함 확인까지 약 11초였다. 이는 반복 조회로 확인한 시각의 차이이며 실제 상태 전환의 정확한 지연 시간은 아니다. Redis 장애가 두 Pod에 동시에 영향을 주어 준비된 endpoint가 일시적으로 0개가 됐다.

## 해석과 한계

이 결과는 Redis health 실패에 따른 Beach readiness 전환과 Service의 준비된 endpoint 제외·재포함을 확인한다. Beach의 Redis 사용 기능, 단일 Pod 장애, 외부 요청 성공률, Redis 데이터 보존 여부는 측정하지 않았다. `latest` 이미지 digest를 수집하지 않았으므로 바이너리 버전까지 특정할 수 없다.

원본 파일은 SSM에서 회수한 stdout이다. 로그 안에 UTC 시각, Deployment·Pod·EndpointSlice 출력, Redis rollout 결과와 앱 로그가 포함돼 있다. 원래 로컬 회수 위치는 `deploy/k8s/loadtest/results/readiness/20261013T054400Z-5966/remote-output.txt`이며 `.gitignore` 대상이다.
