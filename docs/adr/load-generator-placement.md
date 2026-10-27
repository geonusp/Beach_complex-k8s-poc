# k6 부하 생성기 실행 위치

## 상태

Proposed — 현재는 `obs-1`의 Kubernetes Job을 사용하고, HPA 고부하 실험에서 별도 EC2를 재검토한다.

## 컨텍스트

이슈 #3(Rolling Update 사용자 영향)과 이슈 #4(HPA 및 부하 테스트)는 모두 k6로 요청을 보내면서
throughput, 오류율, p50/p95/p99 latency를 측정한다. ADR 작성 당시에는 실행 환경을 정하는 단계였으며 현재는 [`deploy/k8s/loadtest`](../../deploy/k8s/loadtest/)와 SSM 실행 스크립트가 구현돼 있다.

k6를 어디서 실행하느냐는 두 이슈의 측정값에 직접 영향을 준다.

| 실행 위치 | 측정에 끼치는 영향 |
|---|---|
| 로컬 PC | 리전까지의 왕복 지연이 p95·p99에 더해져 애플리케이션 지연이 묻힌다 |
| App Worker | k6가 Beach Pod와 CPU를 나눠 쓴다. #4에서는 HPA 판단 자체가 왜곡된다 |
| `cp-1` | Control Plane에는 워크로드를 배치하지 않는다. rollout을 처리하는 API 서버와 자원을 경쟁한다 |
| `obs-1` | 앱과 노드가 분리된다. 단, `obs-1`은 관측 워크로드 전용으로 정해져 있다 |
| 같은 리전의 별도 EC2 | 앱·관측 노드와 모두 분리된다. 인프라와 네트워크 경로가 추가된다 |

이슈 #4의 최종 HPA 실험에서는 별도 부하 생성기가 필요할 수 있지만, 현재는 몇 번의 호출과
짧은 Rolling Update 검증을 먼저 수행한다. 이슈 #3 분해 과정에서 제안한 `obs-1`의 Kubernetes Job을
현재 기본 실행 위치로 채택하고, HPA 고부하 단계에서 측정값과 자원 경쟁을 다시 평가한다.

그런데 [Ephemeral 의존성 배치 ADR](./ephemeral-dependency-placement.md)(Accepted)은
"`obs-1`은 관측 워크로드 전용으로 유지한다"고 결정했고, 근거로 "관측 스택과 자원 경계 유지"를 들었다.
현재 결정은 k6 Job에 이 원칙의 예외를 두는 것이다. Prometheus·Grafana와 자원을 공유하므로
고부하 실험에서는 관측 지표를 확인하고, 자원 경쟁이나 부하 생성 한계가 확인되면 별도 EC2로 분리한다.

또한 현재 Beach는 클러스터 밖에서 접근할 경로가 자동화되어 있지 않다. ingress-nginx 설치는
`deploy/k8s/app/README.md`에 수동 절차로만 있고, 클러스터 Security Group은 노드끼리만 통신을 허용한다.

## 결정

**현재 결정: `obs-1`에 k6 Kubernetes Job을 배치한다.**

- k6는 클러스터 내부 Job으로 실행하고, `nodeSelector`로 `obs-1`에만 배치한다.
- Job에는 CPU·메모리 `requests/limits`와 완료 후 자동 정리 TTL을 지정한다.
- 짧은 smoke/Rolling Update 검증과 낮은 요청량의 기본 테스트는 이 방식으로 수행한다.
- 현재 운영자는 [실험 결과 종합](../experiments/issue-8/README.md)의 회차별 SSM 실행 절차를 따른다. 내부적으로 Job 실행과 로그 회수를 사용하며 GitHub Actions 실행·artifact 보관은 현재 연결되지 않은 선택적 자동화다.
- HPA 고부하 실험을 시작할 때 `obs-1`의 Prometheus/Grafana와 자원 경쟁이 발생하면,
  같은 리전의 별도 EC2 부하 생성기로 전환한다.
- 별도 EC2는 현재 Terraform에 구현돼 있지 않다. [#4 HPA 실측](../experiments/issue-4/README.md)은 extreme 120 req/s까지 같은 `obs-1` Job 경로를 사용했다. 이것이 모든 고부하에서 자원 간섭이 없다는 증거는 아니다.

### 범위 제외

- 분산 부하 생성(k6 여러 대, k6 Operator)
- 인터넷 구간을 포함한 외부 사용자 경로 측정
- 공인 DNS, AWS Load Balancer Controller
- HPA 고부하용 별도 EC2 Terraform 구현

## 근거

- 현재 테스트 호출량은 작아 별도 EC2를 상시 운영할 필요가 없다.
- 클러스터 내부 Service를 직접 호출할 수 있어 별도 Ingress 공개 경로가 필요 없다.
- 별도 AMI, Terraform 리소스, SG, IAM, SSM 대상을 추가하지 않아 구현·운영 복잡도가 낮다.
- 이슈 #3과 #4의 낮은 요청량 실험은 같은 `obs-1` Job 경로를 사용해야 한다. 그래야 #8 최종 결과에서
  실행 위치, 네트워크 경로, k6 실행 환경이 다른 수치를 섞지 않고 비교할 수 있다.
- k6가 같은 노드의 Prometheus/Grafana와 CPU·메모리를 과도하게 경쟁하는 **noisy neighbor(시끄러운 이웃)**
  상황을 피해야 한다. 현재는 Job의 `requests/limits`와 CPU·throttling 표본으로 관찰하며, 필요한 요청률을 만들지 못하거나 관측 지연이 확인되면 별도 EC2 전환을 재검토한다.
- 관측 노드의 자원 경쟁은 낮은 요청량에서는 제한할 수 있고, HPA 고부하 단계에서 별도 EC2로 재검토할 수 있다.

## 결과

### 긍정적 영향

- 별도 인프라 없이 k6 smoke/Rolling Update 검증을 시작할 수 있다.
- 클러스터 내부 Service 경로를 사용해 테스트 경로가 단순하다.
- k6 Job의 자원 요청과 실행 결과를 Kubernetes 리소스로 함께 확인할 수 있다.

### 부정적 영향

- `obs-1`의 Prometheus/Grafana와 k6가 CPU·메모리를 공유한다.
- 고강도·장시간 부하에서는 관측 데이터와 HPA 측정값이 영향을 받을 수 있다.
- k6가 관측 워크로드의 noisy neighbor가 되면 메트릭 수집 지연과 테스트 결과 왜곡이 발생할 수 있다.
- HPA 실험이 커지면 별도 EC2 설계와 Terraform 변경이 필요하다.
- HPA 단계에서 별도 EC2로 전환하면 #3과 동일한 조건을 유지할 수 없으므로, #8에서 실행 위치 변경을 명시하고
  동일 조건 비교가 필요한 실험은 같은 부하 생성기에서 재실행해야 한다.

## 대안

### 선택지 1: `obs-1`에 고정한 Kubernetes Job

- 장점: 인프라 변경이 없다. PR 3개로 끝난다. 클러스터 안에서 Service를 직접 호출할 수 있어 경로가 단순하다.
- 단점: Accepted ADR의 `obs-1` 전용 원칙에 단기 예외가 필요하고, #5 이후에는 Prometheus와 자원을 경쟁한다.
  고부하 HPA 실험에서는 관측 스택과의 자원 경쟁 및 별도 EC2 전환 필요성을 확인해야 한다.
- 결론: **현재 기본 선택.** Job에 노드 선택과 requests/limits를 지정하고, HPA 고부하 단계에서 별도 EC2 전환을 평가한다.

### 선택지 2: App Worker에서 실행

- 장점: 추가 인프라가 없다.
- 단점: k6가 Beach Pod와 CPU를 나눠 쓴다. #4의 HPA 판단을 직접 왜곡한다.
- 결론: 기각.

### 선택지 3: 로컬 PC에서 실행

- 장점: 준비가 가장 쉽다.
- 단점: 리전까지의 왕복 지연과 가정용 네트워크 편차가 latency에 섞인다. 외부 접근 경로도 필요하다.
- 결론: 기각.

## 검증 계획

1. k6 Job이 `obs-1`에만 스케줄되는지 확인한다.
2. Job에서 Beach Service의 테스트 엔드포인트에 접근할 수 있는지 확인한다.
3. 짧은 k6 실행에서 임계값과 결과 artifact 저장을 확인한다.
4. Job의 CPU·메모리 사용량과 Prometheus/Grafana 수집 상태를 확인한다.
5. HPA 고부하 단계에서 관측 노드 자원 경쟁이 발생하면 별도 EC2 전환을 결정한다.

## 롤백 / 재검토 기준

- `obs-1`의 Prometheus/Grafana 수집이 지연되거나 k6가 관측 워크로드를 압박하면 별도 EC2로 전환한다.
- HPA가 필요한 요청률을 `obs-1` Job으로 만들 수 없으면 별도 EC2 또는 전용 Worker를 검토한다.
- HPA 실험이 끝나면 별도 EC2는 Terraform으로 삭제해 상시 비용을 피한다.

## 참고

### 공식 문서 링크

- [k6 constant-arrival-rate executor](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/constant-arrival-rate/)
- [k6 설치](https://grafana.com/docs/k6/latest/set-up/install-k6/)
- [ingress-nginx 설치 가이드](https://kubernetes.github.io/ingress-nginx/deploy/)
- [Kubernetes Service type NodePort](https://kubernetes.io/docs/concepts/services-networking/service/#type-nodeport)

### 관련 이슈 / PR

- 이슈 #3 Probe 및 Rolling Update 사용자 영향 검증
- 이슈 #4 HPA 및 k6 부하 테스트 — "실험 조건" 절
- 이슈 #5 Prometheus 및 Grafana 관측성 구성

### 관련 문서

- [Ephemeral 의존성 배치](./ephemeral-dependency-placement.md)
- [노드 접근 방식](./node-access-ssm.md)
- 이슈 #3 구현 문서 (로컬 참고·Git 미포함: `../../tempdocs/issue-3/README.md`)

## 작성일자

2026-10-07
