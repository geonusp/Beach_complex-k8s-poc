# 성능 테스트 실행 및 오케스트레이션 도구 선택

## 상태

Proposed

## 컨텍스트

이슈 #3(Rolling Update 사용자 영향 검증)과 이슈 #4(HPA 및 k6 부하 테스트)는
k6로 Beach API에 지속 요청을 보내고 p95/p99 latency, throughput, error rate,
Pod replica 변화를 함께 확인해야 한다.

Testkube는 k6·Playwright·JMeter 등의 테스트를 Kubernetes 안에서 실행하고,
Workflow·결과·이력을 관리하는 플랫폼이다. 다만 Testkube Agent 또는 Control Plane을
클러스터에 추가하면 단순한 k6 실행보다 관리할 컴포넌트와 리소스가 늘어난다.

이 저장소의 AWS 클러스터는 월 40시간 이하만 실행하는 단명 환경이다. Terraform으로
클러스터를 삭제하면 Kubernetes 내부 상태도 사라지므로, 테스트 정의와 실행 결과는
클러스터 외부에 남겨야 한다. 현재 정의는 Git, 전체 원본은 SSM/S3 회수 후 로컬에 보관하며 일부 증거만 Git에 복사한다. CI artifact 자동 회수는 연결돼 있지 않다.

또한 기존 [k6 부하 생성기 실행 위치 ADR](./load-generator-placement.md)은
현재 `obs-1`의 Kubernetes Job을 사용하고, HPA 고부하 단계에서 별도 EC2를 재검토하도록 정리한다.

## 결정

기본 성능 테스트 도구는 **Grafana k6 OSS 컨테이너**로 유지하고, 현재 테스트 오케스트레이션은
**`obs-1`에서 실행하는 Kubernetes Job**으로 구성한다.

- k6 시나리오와 임계값은 저장소에 JavaScript 파일로 관리한다.
- 현재 기본 진입점은 SSM 실험 실행 스크립트이며 내부에서 Job 실행과 로그 회수를 수행한다. GitHub Actions의 수동 실행(`workflow_dispatch`)과
  결과 artifact 보관은 반복 실행이 필요할 때 선택적으로 추가한다.
- k6 Job은 `nodeSelector`로 `obs-1`에 배치하고 CPU·메모리 `requests/limits`를 지정한다.
- k6 원본 결과(JSON/summary)는 GitHub Actions artifact 또는 저장소 외부 보관 위치에 저장한다.
- HPA 고부하 실험에서 관측 노드 자원 경쟁이 발생하면 별도 EC2 부하 생성기로 전환한다.
- Testkube Agent, Testkube Control Plane, Argo Workflows는 기본 클러스터 구성에 포함하지 않는다.

### 적용 범위

- 이슈 #3 Rolling Update 사용자 영향 검증
- 이슈 #4 HPA 및 k6 부하 테스트
- 동일한 실행 위치와 요청 경로를 사용하는 후속 성능 실험

### 범위 제외

- Testkube 대시보드·테스트 이력 플랫폼 구축
- k6 분산 부하 생성 및 여러 부하 생성기 자동 조율
- Grafana Cloud k6 유료/외부 실행 환경
- Argo Workflows 기반의 다단계 테스트 파이프라인

## 근거

- **부하 범위:** 초기 smoke/Rolling Update에 이어 [#4 extreme 120 req/s](../experiments/issue-4/README.md)까지 `obs-1` Job으로 실측했다. 별도 EC2는 아직 구현하지 않았으며 부하 생성기 지표와 관측 간섭을 함께 검토한다.
- **실험 기준 통일:** 이슈 #3과 #4의 기본 실험은 같은 `obs-1` Job과 요청 경로를 사용해 #8에서 실행 위치가 다른 수치를 섞지 않는다.
- **단명 클러스터와의 정합성:** 클러스터를 destroy해도 k6 스크립트와 CI 실행 기록은
  클러스터 외부에 남는다.
- **비용:** Testkube Agent나 Control Plane, 별도 EC2를 기본 클러스터에 추가하지 않는다.
- **학습 범위:** 이슈 #4의 목표는 테스트 플랫폼 구축이 아니라 HPA 반응과 애플리케이션
  성능 지표를 검증하는 것이다.
- **기존 결정과 일관성:** 현재 `obs-1` 예외로 실행하되, 고부하에서 자원 경쟁이나 부하 생성 한계가 확인되면 관측 워크로드와 분리하는 방안을 재검토한다.
- **noisy neighbor 방지:** k6가 Prometheus/Grafana와 CPU·메모리를 과도하게 경쟁하면 관측 데이터와
  HPA 결과가 왜곡될 수 있으므로, 고부하 단계에서는 조건부로 별도 EC2를 도입한다.

## 결과

### 긍정적 영향

- k6 스크립트와 실험 조건을 Git으로 재현할 수 있다.
- 테스트 생성기 자원과 애플리케이션 자원을 분리할 수 있다.
- Testkube 전용 컴포넌트의 설치·업그레이드·삭제 부담이 없다.
- 40시간 예산 안에서 클러스터와 부하 생성기를 함께 운용할 수 있다.

### 부정적 영향

- 테스트 실행 이력과 결과 화면을 직접 구성해야 한다.
- GitHub Actions와 Kubernetes Job 실행·결과 수집을 별도로 관리해야 한다.
- 분산 부하나 여러 팀의 테스트 케이스 관리는 Testkube보다 불편하다.
- HPA 고부하 단계에서 별도 EC2로 전환하면 Terraform과 네트워크 경로를 추가로 구성해야 한다.

## 대안

### 선택지 1: Testkube

- 장점: Kubernetes-native 테스트 실행, Workflow, 결과 이력, 대시보드를 제공한다.
- 단점: Agent/Control Plane과 관련 저장소·RBAC·이미지를 추가해야 하며, 단명 클러스터에서
  매번 설치하는 비용과 운영 복잡도가 커진다.
- 결론: **현재 기본 구성에서는 기각.** 반복 테스트 팀이나 중앙 대시보드 요구가 생기면 재검토한다.

### 선택지 2: Kubernetes Job + k6

- 장점: 별도 테스트 플랫폼 없이 클러스터 내부에서 Service를 직접 호출할 수 있다.
- 단점: `obs-1`에서 실행하면 관측성 워크로드와 자원을 경쟁할 수 있다.
- 결론: **현재 기본 선택.** Job에 `nodeSelector`, `requests/limits`, 자동 정리 TTL을 지정하고,
  HPA 고부하 단계에서 별도 EC2 전환을 평가한다.

### 선택지 3: Grafana Cloud k6

- 장점: 결과 대시보드, 이력, 분산 부하와 팀 공유 기능을 빠르게 얻을 수 있다.
- 단점: 외부 서비스 계정·토큰·비용이 필요하고, 사설 클러스터 접근 경로를 별도로 열어야 한다.
- 결론: 외부에서 접근 가능한 테스트 대상과 결과 대시보드가 필요해질 때 재검토한다.

### 선택지 4: Argo Workflows

- 장점: DB 준비, 앱 배포, 부하 실행, 결과 수집, 정리 같은 여러 단계를 Kubernetes 리소스로
  조합할 수 있다.
- 단점: Workflow Controller와 CRD를 추가해야 하며, 단일 k6 실행에는 과하다.
- 결론: 다단계 테스트 파이프라인이 생길 때만 검토한다.

## 검증 계획

1. k6 Job이 `obs-1`에만 스케줄되는지 확인한다.
2. Job에서 Beach Service의 테스트 엔드포인트에 접근할 수 있는지 확인한다.
3. smoke 시나리오로 k6 임계값과 결과 artifact 저장을 검증한다.
4. Job의 CPU·메모리 사용량과 Prometheus/Grafana 수집 상태를 확인한다.
5. HPA 고부하 단계에서 관측 노드 자원 경쟁이 발생하면 별도 EC2 전환을 결정한다.
6. 실행 위치, 요청 경로, k6 버전, 테스트 파일 버전을 결과와 함께 기록한다.

## 롤백 / 재검토 기준

- `obs-1` 자원 경쟁으로 관측 데이터가 지연되거나 필요한 요청률을 만들 수 없으면 별도 EC2로 전환한다.
- GitHub Actions artifact만으로 결과 비교가 불편해지면 Grafana Cloud k6 또는 Testkube를 검토한다.
- 테스트 단계가 세 단계 이상으로 늘고 재시도·병렬 실행·정리 보장이 필요해지면 Argo Workflows를 검토한다.
- 클러스터 내부 실행이 필요해지면 전용 부하 생성 노드 또는 taint/toleration을 먼저 설계한다.

## 참고

### 공식 문서 링크

- [Grafana k6 공식 문서](https://k6.io/docs/)
- [Grafana Cloud k6 결과 전송](https://grafana.com/docs/k6/latest/results-output/real-time/cloud/)
- [Testkube 공식 문서](https://docs.testkube.io/)
- [Argo Workflows 공식 문서](https://argoproj.github.io/argo-workflows/)
- [Kubernetes Job](https://kubernetes.io/docs/concepts/workloads/controllers/job/)

### 관련 이슈 / PR

- 이슈 #3 Probe 및 Rolling Update 사용자 영향 검증
- 이슈 #4 HPA 및 k6 부하 테스트
- 이슈 #5 Prometheus 및 Grafana 관측성 구성

### 관련 문서

- [k6 부하 생성기 실행 위치](./load-generator-placement.md)
- [Kubernetes 실행 환경](./k8s-execution-environment.md)
- [Cilium 및 Pod CIDR 결정](./cilium-cni.md)

## 작성일자

2026-10-07
