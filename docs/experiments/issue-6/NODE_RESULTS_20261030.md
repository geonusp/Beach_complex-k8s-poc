# 이슈 #6 — PostgreSQL 배치 Node 장애와 최종 복구 확인

## 변경 요약과 판정

운영자가 `test/6-node-failure-recovery-followup`의 `95900eded0d531c15d1953a0ce1adc1805d94ffe` 반영 후 `node-20261029T233550Z-45508` 회차를 실행했다. 대상은 app-2(`beach-complex-app-2`, `i-0230600b4adf137fa`)다. 기존 Redis 배치 노드 실험과 달리 이번 사전 snapshot에서 PostgreSQL은 app-2, Redis는 app-1에 있었다.

**이번 회차는 다른 Worker 재배치와 같은 EC2·Node의 최종 복구 판정을 통과했다.** 기존 Pod 실험과 함께 #6의 Pod 교체·Node 감지·EndpointSlice 변화·다른 Worker 재배치·사용자 영향 측정·사후 복구 확인 증거를 확보했다. 이전 회차의 복구 판정 한계는 [기존 결과](NODE_RESULTS_20261029.md)에 그대로 보존한다. 원격 이슈 상태는 변경하지 않았다.

PostgreSQL은 비영속 Pod 재생성으로 UID와 데이터 fingerprint가 바뀌었다(`database_recreated=true`, `database_fingerprint_match=false`). **데이터 보존 성공을 뜻하지 않는다.** 재배치 후 fingerprint를 기준으로 고정한 runner가 이후 추가 변경과 최종 복구를 검사했다. Redis 생존 UID는 유지됐다.

## 검증 결과

원본을 현재 HEAD의 `node_failure_results.summarize()`로 재집계해 저장된 `phases.json`과 객체 단위로 일치함을 확인했다. 원본 snapshot 197개 중 최초·최종 상태에 `final()`을 다시 적용해 통과했다. 집계 사본 `node-phases-20261030.json`은 원본과 바이트 단위로 일치한다. 문서 작성 중 AWS·클러스터를 조작하거나 장애 실험을 재실행하지 않았다.

| 사건 | UTC | t0부터 관측 시간 |
| --- | --- | ---: |
| 중단 시작 t0 | `2026-10-29T23:40:51.154159000Z` | 0초 |
| Node 장애 감지 | `2026-10-29T23:41:45.572565+00:00` | 54.42초 |
| 기존 endpoint 제외 | `2026-10-29T23:41:45.572912+00:00` | 54.42초 |
| endpoint 제외 후 최초 API 안정 30초 창 종료 | `2026-10-29T23:42:15.572912+00:00` | 84.42초 |
| 대체 Pod Ready 관측 | `2026-10-29T23:47:50.974223+00:00` | 419.82초 |
| Ready 후 안정 30초 창 종료 | `2026-10-29T23:48:20.974223+00:00` | 449.82초 |
| 같은 EC2 재시작 요청 | `2026-10-29T23:56:23.400593300Z` | — |
| 최종 snapshot | `2026-10-29T23:57:45.883612+00:00` | — |
| 최종 상태 검증 완료 | `2026-10-29T23:57:46.475700609Z` | — |

84.42초는 endpoint 제외 후 찾은 최초 API 안정 창이다. 이후까지 지속된 무오류를 뜻하지 않는다. 419.82초는 재배치 정상 상태의 관찰 시간, 449.82초는 Ready 이후 안정 창 경계이며 연속 서비스 중단 시간이나 EC2 최종 복구 시간이 아니다.

| 구간 | 요청 | 실패 | 실패율 | 처리량(req/s) | p95(ms) | p99(ms) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 기준 | 835 | 0 | 0% | 5.0024 | 11.755232 | 22.901795 |
| 장애·안정 확인 | 2,249 | 181 | 8.0480% | 4.9998 | 22.012165 | 5000.251653 |
| 회복 후 | 2,043 | 0 | 0% | 4.9994 | 5.228202 | 15.343490 |

장애 구간 실패는 HTTP 5xx 112건·연결 실패 69건이다. 총 5,127건이며 모든 구간 dropped iterations 0, `samples_complete=true`, `baseline_valid=true`, `passed=true`다. 실패 요청을 포함한 duration 표본의 nearest-rank p95/p99다. 무중단 성공으로 표현하지 않는다.

최종 snapshot에서 모든 Node Ready, 두 App Worker schedulable, 장애 taint 3종 없음, 대상 노드 종료 중 Pod 없음, 기존 대상 Beach UID 부재·생존 Beach UID 유지·EndpointSlice 정상 일치를 재판정했다. Beach 2개·PostgreSQL·Redis는 모두 Ready이며 app-1에 있다. app-2 복귀 후 자동 재분산은 관측되지 않았다. 원격 `final_state_verified`는 상태 검사뿐 아니라 DB fingerprint 비교·API 호출까지 통과한 runner 기록이다. 로컬 재판정은 snapshot 상태 검증이며 API·DB 호출 재실행은 아니다.

## 원본 보존

원본은 Git 제외 경로 `deploy/k8s/loadtest/results/issue-6/node-20261029T233550Z-45508/`에 유지했다. 기존 실패·이전 성공 회차를 수정하지 않았다. `final-error.txt`, `restart-error.txt`, `ssm-error.txt`, `stop-error.txt`, `summary-error.txt`는 모두 0바이트다.

| 원본 파일 | 바이트 | SHA-256 |
| --- | ---: | --- |
| `remote-output.txt` | 37024584 | `81869df2b899188a264c11f2f108fbba8403bd3aa132065e477818d25c244a82` |
| `phases.json` | 1960 | `c24f35c1212fbddcf1067eee40bf17c8ff4537fbcf46da5269bc9b9a4e87b0a6` |
| `final.txt` | 779047 | `9f0e852c7392a7a71493fd751e423fff2cf62780eab27daa9914b80854f31e1a` |
| `context.json` | 136 | `3a7977806ebc4a51246e0762592a698e9863723bb24e7ac8fc2bcd656d2ca0a2` |
| `local-marks.txt` | 83 | `bfa74e95b89cde5fbb0948937038e6417d417cee1929d8c6a17245d515808dff` |

재집계 명령(저장소 루트):

```bash
python deploy/k8s/scripts/node_failure_results.py summarize deploy/k8s/loadtest/results/issue-6/node-20261029T233550Z-45508
```

## 미확인 사항·위험

- 이번 수치는 Beach와 PostgreSQL이 함께 배치된 Node 장애의 사용자 영향이다. Redis 단독 장애 요청 실패율은 미측정이다.
- PostgreSQL 데이터 보존은 검증하지 않았으며 fingerprint 변경을 실제 기록했다. 비영속 의존성의 재배포·재분산은 데이터를 초기화할 수 있다.
- 단일 Control Plane이므로 클러스터 전체 HA 검증이 아니다. EC2 stop은 OS 종료를 포함하므로 물리 전원 손실과 동일하지 않다.
- 노드 간 시계 오차·장시간 안정성·고부하 내성은 미검증이다. 5 req/s 단일 API 부하에서의 관측 결과다.
- 전체 원본은 로컬에만 있고 외부 독자의 다운로드 경로는 미확정이다. 로컬 정리 전 별도 외부 보관과 해시 대조가 필요하다.

## Reviewer 집중 지점

회차별 PostgreSQL·Redis 배치 구분, 데이터 재생성과 보존의 구분, 장애 구간 181건 실패 표기, 최초 API 안정 창과 재배치 안정 창의 차이, 최종 taint·종료 중 Pod·EndpointSlice 판정 근거를 확인한다.

## 출처

- [이슈 #6](https://github.com/geonusp/Beach_complex-k8s-poc/issues/6)
- [Kubernetes Node 상태](https://kubernetes.io/docs/reference/node/node-status/)
- [Kubernetes ephemeral volumes](https://kubernetes.io/docs/concepts/storage/ephemeral-volumes/)
- [k6 JSON output](https://grafana.com/docs/k6/latest/results-output/real-time/json/)
