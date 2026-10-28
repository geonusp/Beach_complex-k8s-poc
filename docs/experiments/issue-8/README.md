# PoC 실험 결과 종합 (#8)

원본 Beach 서비스는 팀 프로젝트이며, 이 저장소의 Kubernetes 구성과 실험은 ginu가 단독 수행했다. AWS kubeadm 4노드의 기존 실험 기록을 종합한다. 이 문서 작성 중 클러스터를 재실행하거나 새 장애를 주입하지 않았다.

## 구성과 재현 안내

- [목적·4노드 구성·다이어그램](../../../README.md), [kubeadm 선택과 K3s 비교](../../adr/k8s-execution-environment.md)
- [사전 준비·Terraform 생성·bootstrap·배포·검증·삭제](../../../deploy/k8s/README.md)
- [앱·Secret·접근 경로](../../../deploy/k8s/app/README.md), [관측 스택·지표 해석](../../../deploy/k8s/observability/README.md)
- [비용·데이터 보존·비밀정보 관리](../../kubernetes-ephemeral-cluster-cost-and-secrets.md)

생성·부하·장애·삭제 명령은 실제 리소스를 변경하므로 운영자가 실행한다. 사전 조건과 복구 절차는 연결된 가이드를 따른다.

## 실험 범위와 결과

요청 측정은 내부 Service의 `GET /api/beaches` 기준이다. 아래는 조건·시점이 다른 회차이며 성능 개선의 전후 비교로 사용하지 않는다.

| 항목 | 조건·관측 | 판정·근거 |
| --- | --- | --- |
| #3 Rolling Update | 1 req/s, 전체 390초, 389건 HTTP 200, dropped iteration 1건 | 롤아웃 성공. 기본·조정 설정 비교는 범위 제외.[상세·공개 원본](../issue-3/README.md) |
| #3 Redis readiness | Redis 1→0→1, ready endpoint 2→0→2, Pod 재시작 없음 | endpoint 제외·재포함 관측. 요청 실패율 미측정.[상세·공개 원본](../issue-3/readiness-endpoint/README.md) |
| #5 관측성 | 5 req/s·300초, 1,501건·실패 0, Prometheus target 26개 up | 단일 회차 지표 조회·Grafana 화면 보존.[상세·증거](../issue-5/README.md) |
| #6 Pod 장애 | 5 req/s·420초, 2,101건·실패 0, 새 Pod Ready까지 64.56초 | Pod 1개 삭제 후 복구 관측. 64.56초는 서비스 중단 시간이 아님. Node 실측은 후속.[상세](../issue-6/README.md) |
| #4 HPA | CPU request 100m, 120 req/s 설정·600초, 71,999건·실패 0, 실측 120.013 req/s, Ready 2→4→2 | extreme 회차 확장·축소 관측. 40 req/s는 첫 회차 확장·반복 미확장으로 반복 재현 미확인, 미통과 판정 유지.[상세](../issue-4/README.md) |

## 지연시간과 집계 범위

| 회차 | p50(ms) | p95(ms) | p99(ms) | 집계 범위 |
| --- | ---: | ---: | ---: | --- |
| #3 Rolling Update 20261012 | 7.41 | 21.70 | 126.27 | 전체 390초, 배포 구간만의 값 아님 |
| #5 관측성 | 3.06 | 5.90 | 21.38 | k6 전체 요청, 서버 Prometheus 지연과 구분 |
| #6 Pod 장애 반복 회차 | 미공개 | 11.757978 | 27.718230 | 장애·안정 확인 구간 472건, 전체 summary 아님 |
| #4 extreme 120 req/s | 2.357873 | 5.872470 | 21.175062 | 전체 71,999건, nearest-rank |

수치는 각 상세 결과 문서의 집계값을 인용했다. 이 종합 문서 작성 중 k6 원본을 다시 집계하지 않았다. HPA 확장이 지연 개선이나 최대 수용량 증가를 유발했다는 인과 효과는 검증하지 않았다.

## 원본 접근성과 실행 코드

| 범위 | 근거 접근성·코드 기준 |
| --- | --- |
| #3 | 상세 문서에 원본 JSON·SSM 출력과 SHA-256 보존. 이미지 `latest` 및 digest 미수집 한계는 회차별 기록 참조 |
| #5 | k6 요약·관측 검증 출력·Grafana PNG 공개. 실험 당시 CPU request는 250m으로 현재 100m과 다름 |
| #6 | 집계 사본은 저장소에 있으나 전체 원본은 로컬 `deploy/k8s/loadtest/results/issue-6/`에만 보관. 검증 코드 `b6e9b9cc8c31a2d0dc20f805a2c9bbc8b7915dd1` |
| #4 | 전체 원본은 로컬 `deploy/k8s/loadtest/results/issue-4/`에만 보관. extreme 재집계 기준 `b84b455b`. 초기 회차는 미커밋 변경 상태여서 상세 기록의 실행 조건을 함께 확인 |

외부 검토자는 #4·#6 전체 원본을 Git에서 내려받을 수 없다. 로컬 경로·해시·집계 사본은 외부 접근 권한을 제공하지 않는다. 실행 코드와 재집계 코드 기준을 동일한 것으로 취급하지 않는다.

## #8 완료 기준 대응과 남은 범위

[문서별 정합성 검토 기록](DOCUMENT_REVIEW.md)에 저장소 문서·로컬 계획의 확인 결과와 검증 한계를 정리했다.

[이슈 #8](https://github.com/geonusp/Beach_complex-k8s-poc/issues/8)의 작업·완료 기준을 다음처럼 구분한다. 이슈 체크리스트나 종료 상태는 변경하지 않았다.

| 기준 | 현재 제공한 자료·남은 검증 |
| --- | --- |
| 프로젝트 목적·아키텍처·선택 근거 | 루트 README, 그림, 실행 환경 ADR. Terraform 인스턴스·AZ는 예시 |
| 생성·삭제 절차와 새 환경 재현 | 가이드를 현재 스크립트 단계와 대조. 새 환경에서 전체 재현은 미검증 |
| Probe·Rolling Update·HPA·장애 결과 | 위 표와 상세 문서. readiness 요청 실패율 미측정, Node 실측은 후속 |
| 관측 증거·k6·지연 비교 | #5 검증 출력·화면과 회차별 지표. #4·#6 전체 원본은 외부 접근 제한 |
| 과장 없는 성능·HA 표현 | 단일 Control Plane, 내부 경로·단기 실험, 고정 replica 대조 없음. 대규모 production 성능·클러스터 HA 미검증 |
| 주요 이슈·관련 코드 연결 | #4 결과의 PR #33·#34 링크와 회차별 코드 기준, #6 검증 코드. 모든 회차의 이미지 digest·실행 diff가 확보된 것은 아님 |
| Hubble·확장 로드맵 | #7 NetworkPolicy/Hubble, #6 Node 실측, #18 분석 데모, #13 노드 자동확장은 후속. Cilium 설치를 해당 실험 완료로 취급하지 않음 |

kind 로컬 단계는 초기 계획이며 저장소에서 실행 근거를 확인하지 못했다. 다이어그램 생성 소스의 SVG 생성은 확인했으나 PNG·PDF 렌더링은 환경 의존성이 남아 있다. PDF 페이지와 GitHub 화면 렌더링도 별도 검증이 필요하다.
