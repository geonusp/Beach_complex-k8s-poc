# 이슈 #6 — App Worker Node 장애 실험 결과

## 범위와 판정

운영자가 `test/6-node-failure-recovery-followup` 브랜치의 `77db2016`까지 반영된 환경에서 Redis가 배치된 app-2 중단 실험을 실행했다. 원본 회차는 `node-20261029T213437Z-33402`다. 생존 app-1에서 Beach·Redis의 대체 Pod가 Ready가 되고 요청이 회복된 증거가 있다. PostgreSQL은 app-1에서 계속 실행됐다.

**원래 EC2·Node의 완전한 최종 복구는 이 실행으로 검증되지 않았다.** 당시 `final()`이 장애 taint와 종료 중 이전 Pod를 검사하지 않아, 마지막 스냅샷에 이 상태가 남았는데도 통과했다. `node-phases-20261029.json`은 원본 `phases.json`의 바이트 단위 사본이며 `passed: true`도 당시 판정 기록으로 보존한다. 이 값을 강화된 복구 기준의 통과로 인용하면 안 된다.

후속 코드 `4557dc29`는 두 app 노드의 unschedulable·장애 taint 3종과 대상 노드의 beach Namespace 종료 중 Pod 잔존을 거부한다. 기존 5분 재시도 루프 안에서 해소되지 않으면 실패한다. 보존된 마지막 스냅샷은 이 코드로 재판정하면 거부된다. 이전 회차 자체의 한계는 유지한다. 이후 `95900ede` 반영 후 실제 재실행과 최종 복구 확인은 [최신 회차](NODE_RESULTS_20261030.md)에 별도로 기록했다.

## 실행 절차와 UTC 타임라인

기존 개발 환경에서 운영자가 다음 명령으로 app-2를 중단했다. 재실행은 실제 EC2 중단과 복구를 수반하며, 의존성 분산·용량·관측 사전 조건을 다시 충족해야 한다. 이번 문서 작성 중에는 실행하지 않았다.

```bash
PYTHON=python bash deploy/k8s/scripts/run-node-failure-experiment.sh --confirm-dev app-2
```

| 사건 | UTC | t0부터 관측 시간 |
| --- | --- | ---: |
| 중단 시작 t0 | `2026-10-29T21:38:37.918555400Z` | 0초 |
| Node 장애 감지 | `2026-10-29T21:39:31.994216+00:00` | 54.08초 |
| 기존 endpoint 제외 관측 | `2026-10-29T21:39:31.994514+00:00` | 54.08초 |
| 대체 Pod Ready 관측 | `2026-10-29T21:45:35.182754+00:00` | 417.26초 |
| Ready 이후 안정 30초 창 종료 | `2026-10-29T21:46:05.182754+00:00` | 447.26초 |
| 같은 EC2 재시작 요청 | `2026-10-29T21:54:36.087792800Z` | — |
| 마지막 상태 스냅샷 | `2026-10-29T21:55:05.903356+00:00` | — |
| 이전 코드의 최종 통과 기록 | `2026-10-29T21:55:06.689239739Z` | 완전 복구 증거로 사용 불가 |

집계의 완화 시간은 endpoint 제외 이후 API 안정 창을 찾은 407.08초다. 대체 Pod Ready 이후 안정 창 경계인 447.26초와 다른 기준이며, 어느 값도 EC2 최종 복구 시간이나 연속 서비스 중단 시간을 뜻하지 않는다. t0·재시작은 실행 PC, Node 관측은 CP, 요청 표본은 obs-1 시계라 시계 오차가 섞여 있다.

## 사용자 영향

| 구간 | 요청 | 실패 | 실패율 | 처리량(req/s) | p95(ms) | p99(ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 기준 | 728 | 0 | 0% | 5.0017 | 12.503821 | 25.630115 |
| 장애·안정 확인 | 2,237 | 49 | 2.1904% | 5.0015 | 7.335906 | 22.803009 |
| 회복 후 | 2,175 | 0 | 0% | 4.9980 | 10.342520 | 23.718724 |

실패 49건은 모두 연결 실패이며 HTTP 5xx는 모든 구간 0건이다. 모든 구간에서 dropped iterations는 0, `samples_complete`는 true이며 `baseline_valid`도 true다. p95/p99는 실패 요청을 포함한 `http_req_duration` 시각 표본에 nearest-rank를 적용한 구간 값이다. latency가 기준 수준으로 회복됐다는 판정은 하지 않는다.

## 최종 상태와 해석 한계

- 마지막 app-2는 Ready=True였지만 `node.kubernetes.io/unreachable`·`node.cilium.io/agent-not-ready` taint와 종료 중인 이전 Beach·Redis Pod가 남았다. 재시작 요청과 실제 최종 복구 완료를 구분해야 한다.
- 최종 관측 배치에서 PostgreSQL·새 Redis는 app-1에 함께 있다. app-2 복귀 후 자동 재분산은 없으며 다음 의존성 배포 스크립트 실행 시 1:1을 검증한다. 이 배포는 두 의존성 Pod를 교체하므로 비영속 DB·캐시가 초기화된다.
- PostgreSQL이 있던 노드의 장애·재배치·초기화는 미검증이다. `db-before`·`db-final` 비교는 PostgreSQL이 살아 있는 상태의 비교이며 PostgreSQL 장애 시 데이터 보존 증거가 아니다.
- Node 장애는 같은 노드에서의 Pod 교체와 달리 Node 감지·endpoint 제외·다른 Worker 재배치를 포함한다. Pod 장애 결과는 기존 `README.md`에 기록돼 있다.
- Redis 단독 장애 요청 실패율은 미측정이다. 이번 수치는 Beach Pod와 Redis가 함께 있던 Node 장애의 사용자 영향이다.
- 시계 오차·복귀 후 장시간 안정성은 미검증이다. 단일 Control Plane 구성이므로 클러스터 전체 HA를 검증하지 않았다.

## 원본 보존과 검증

원본은 `.gitignore` 대상인 `deploy/k8s/loadtest/results/issue-6/node-20261029T213437Z-33402/`에 보존한다. 기존 Pod 실험과 같이 Git에는 설명과 집계 JSON만 넣는다. 원본은 이 커밋으로 내려받을 수 없으며, 외부 보관 위치와 독자 접근 경로는 미확정이다. 로컬 원본을 정리하기 전에 별도 보관과 해시 검증이 필요하다.

| 원본 파일 | 바이트 | SHA-256 |
| --- | ---: | --- |
| `remote-output.txt` | 36676203 | `7291c09436f0eb8fcbf5614bf1d1d0930c2686fded24793fbf6706d37497e1cc` |
| `phases.json` | 1887 | `b2e77392ac454321bfa5d6a519e5ffb748f07435e10f0eec0e3799dc516b0139` |
| `final.txt` | 313030 | `47f6d65147ac7f4a82468402edf370113b36f1ff248460fe2a58feb1c04cfbdc` |
| `context.json` | 136 | `3a7977806ebc4a51246e0762592a698e9863723bb24e7ac8fc2bcd656d2ca0a2` |
| `local-marks.txt` | 83 | `42a11941ce6b13445af8e07166e0f438678b6f5e86e848fee9638a29dacda53f` |

`4557dc29`의 집계 코드로 원본을 재집계한 결과는 저장된 JSON과 객체 단위로 일치했다. 작업 트리의 집계 사본은 원본과 바이트 단위로도 일치했다. Git 저장 시 저장소의 LF 정책에 따라 줄바꿈이 정규화되므로, 커밋된 JSON은 객체 단위로 대조한다. 강화된 최종 판정 함수는 마지막 스냅샷을 `Final app worker scheduling recovery incomplete`로 거부했다. 이번 검증은 로컬 파일 재집계·재판정이며 AWS·클러스터를 조작하지 않았다.

## 출처

- [이슈 #6](https://github.com/geonusp/Beach_complex-k8s-poc/issues/6)
- [Kubernetes Node 상태](https://kubernetes.io/docs/reference/node/node-status/)
- [Kubernetes Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)
- [k6 JSON output](https://grafana.com/docs/k6/latest/results-output/real-time/json/)
