# 기술 결정 기록 (ADR)

## 1. 목적

- Beach Kubernetes Production-Readiness PoC에서 내린 주요 기술·아키텍처 결정과 그 이유를 기록한다.
- 시간이 지나도 "왜 이렇게 했는지"를 문서만 보고 이해할 수 있게 한다.

## 2. 범위

이 디렉터리의 ADR은 **이 저장소의 Kubernetes PoC에 한정**한다.
백엔드 도메인 ADR(`Beach-complex/docs/adr`)과 **번호 체계를 공유하지 않으며 독립적으로 관리한다.**
문서 파일명은 번호 없이 주제를 나타내는 이름을 쓴다.

백엔드 쪽 결정이 이 PoC의 전제가 되는 경우에는 해당 ADR을 저장소명과 함께 참조로만 인용한다.

## 3. 기록 대상

되돌리기 비용이 크거나 여러 이슈에 걸치는 결정만 기록한다.

- 클러스터 실행 환경과 토폴로지
- CNI, 런타임 등 교체 시 클러스터 재구축이 필요한 구성요소
- 네트워크 대역처럼 나중에 바꾸기 어려운 값
- 배포·관측·보안의 구조적 방침

단일 PR에서 되돌릴 수 있는 구현 방식은 ADR로 남기지 않고 해당 PR 문서나 `deploy/*/README.md`에 기록한다.

## 4. 결정 목록

| 주제 | 요약 결정 | 상태 | 문서 |
| --- | --- | --- | --- |
| Kubernetes 실행 환경 | kind 로컬에서 AWS EC2 kubeadm 4노드로 전환. 역할 분리는 node label + `nodeSelector` | Proposed | [k8s-execution-environment](./k8s-execution-environment.md) |
| Pod network add-on | Cilium 채택, Pod CIDR `10.244.0.0/16` 고정 | Proposed | [cilium-cni](./cilium-cni.md) |
| 노드 접근 방식 | SSH·키페어 대신 SSM Session Manager. 인바운드 22번 없음 | Proposed | [node-access-ssm](./node-access-ssm.md) |
| Ephemeral 의존성 배치 | PostgreSQL·Redis는 App Worker에 배치하고 `obs-1`은 관측성 전용 유지 | Accepted | [ephemeral-dependency-placement](./ephemeral-dependency-placement.md) |
| k6 부하 생성기 실행 위치 | 현재 `obs-1` Kubernetes Job 사용. HPA 고부하 때 별도 EC2 재검토 | Proposed | [load-generator-placement](./load-generator-placement.md) |
| 성능 테스트 오케스트레이션 | k6 컨테이너 + `obs-1` Kubernetes Job을 기본으로 하고 GitHub Actions는 선택적 자동화 | Proposed | [performance-test-orchestration](./performance-test-orchestration.md) |
| SSM 실험 결과 저장 | SSM 전체 출력과 k6 원본 JSON을 임시 비공개 S3 버킷으로 회수하고 Terraform destroy 시 제거 | Proposed | [ssm-run-command-output-storage](./ssm-run-command-output-storage.md) |
| readiness 외부 의존성 정책 | 제안은 기본 Redis 제외이나 현재 구현은 `readinessState,redis`. 차이와 실측 한계는 문서 상단 참조 | Proposed | [readiness-dependency-policy](./readiness-dependency-policy.md) |
| 관측 스택 설치 방식 | `kube-prometheus-stack` Helm 차트 축소 구성(Alertmanager·control plane scrape 제외)을 `obs-1`에 배치 | Proposed | [observability-stack-installation](./observability-stack-installation.md) |
| Resource metrics 제공 방식 | Metrics Server를 `obs-1`에 배치하고 `--kubelet-insecure-tls` 대신 `serverTLSBootstrap` + kubelet-serving CSR 승인 | Proposed | [resource-metrics-provider](./resource-metrics-provider.md) |

## 5. 문서 템플릿

~~~markdown
# [제목]

## 상태

[Proposed | Accepted | Deprecated | Superseded | Rejected]

## 컨텍스트

## 결정

### 범위 제외

## 근거

## 결과

### 긍정적 영향

### 부정적 영향

## 대안

### 선택지 1: [이름]

- 장점:
- 단점:
- 결론:

## 검증 계획

## 롤백 / 재검토 기준

## 참고

### 공식 문서 링크

### 관련 이슈 / PR

### 관련 문서

## 작성일자
~~~
