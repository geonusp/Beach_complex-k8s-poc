# Kubernetes 실행 환경 — kind 로컬에서 AWS kubeadm 4노드로 전환

## 상태

Proposed

## 컨텍스트

`plan.md`는 실행 환경을 다음과 같이 정리했다.

| 선택지 | 추천도 | 계획서의 판단 |
|---|---:|---|
| kind + cloud-provider-kind | 높음 | 로컬 비용이 낮고 표준 리소스 실험을 재현하기 쉬워 **기본안으로 사용한다** |
| minikube | 중상 | kind 사용이 어려울 때의 로컬 대안 |
| kubeadm 기반 클러스터 | 중 | 학습 가치는 높지만 **클러스터 운영 부담이 커서 선택 과제로 둔다** |
| Amazon EKS | 중 | IAM, VPC, 비용 범위가 커지므로 일시적인 클라우드 검증에만 사용한다 |

같은 문서의 `6.4 Won't`에는 "EKS 상시 운영 — 비용 발생 가능성. 로컬 Kubernetes 또는 임시 클라우드만 사용"이 있다.

그러나 이후 작성된 `cost.md`(가격 기준일 2026-09-04)는
**이미 AWS Self-managed 4노드를 기준 아키텍처로 전제하고 있다.** 역할별 노드 수, 인스턴스 크기 2안,
Spot 적용 전략, 월 비용까지 산정되어 있고, 운영 원칙도 다음과 같이 명시되어 있다.

> 평소에는 로컬 kind를 사용하고, AWS 4노드 클러스터는 검증할 때만 생성한 뒤 완전히 삭제하는 것

즉 실행 환경 전환은 이 문서에서 처음 내리는 결정이 아니라 **비용 문서에서 이미 전제된 결정**이며,
`plan.md`의 `4.5`와 `6.4`만 갱신되지 않은 상태다.
이 문서는 그 결정을 명시적으로 기록하고, 뒤처진 계획서 항목을 정정하는 역할을 한다.

이슈 #1은 그 전제를 실제 작업으로 옮긴 것이다.

전환이 필요해진 직접적인 이유는 **노드 단위 장애 영역 분리를 검증할 수 없다**는 점이다.

- 이슈 #6은 "Pod 및 App Worker **Node** 장애 복구 실험"이다. kind는 노드를 컨테이너로 흉내 내므로
  노드 장애가 실제 호스트 장애와 성질이 다르다.
- 관측 스택과 앱을 분리하는 목적은 "앱 부하가 관측에 영향을 주지 않는다"를 보이는 것이다.
  namespace는 논리 경계일 뿐 배치를 보장하지 않으므로, 같은 커널·같은 자원을 공유하는 kind 노드에서는
  분리 효과 자체가 성립하지 않는다.
- Security Group, IAM Role, EBS, AZ 같은 클라우드 운영 요소는 kind에 존재하지 않는다.

또한 백엔드 문서 저장소(`Beach-complex/docs`)의 `ADR-016 관측 인프라 IaC 도입`은 관측 인프라를
Terraform + cloud-init으로 IaC화하면서 재검토 기준에
"ECS/Kubernetes 전환이 확정되어 EC2 + Docker Compose 기반 IaC가 더 이상 주된 배포 모델이 아니게 된다"를
명시했다. 이 ADR이 그 재검토 시점에 해당한다.

## 결정

Kubernetes 실행 환경을 **AWS EC2 기반 self-managed kubeadm 클러스터 4노드**로 한다.

### 노드 구성

| 노드 | 역할 | 대수 | 인스턴스 | 비고 |
|---|---|---:|---|---|
| Control Plane | `control-plane` | 1 | t3.medium | `node-role.kubernetes.io/control-plane:NoSchedule` taint 유지 |
| App Worker | `app` | 2 | t3.small | 앱 Pod 분산 배치, HPA 확장 대상 |
| Observability Worker | `observability` | 1 | t3.medium | 관측 워크로드 전용 (이슈 #5에서 채움) |

공통 사양은 x86_64 Ubuntu Server 24.04 LTS, root gp3 20 GiB, On-Demand다.

**x86(t3)을 쓰는 이유.** 비용 문서는 t4g(ARM/Graviton)를 최종 추천했고 상시 운영이라면 그 판단이 옳다
(t3 약 `$172/월` 대 t4g 절감형 약 `$82/월`). 그러나 아래 운영 모델대로 40시간만 실행하면
두 구성의 차이는 **미화 3달러 미만**으로 줄어든다. 그 금액을 아끼려고 멀티아치 컨테이너 이미지 빌드를
이슈 #2에 추가하고, 노드 장애마다 아키텍처를 의심 변수로 두는 것은 PoC에서 손해다.
**상시 운영으로 방향이 바뀌면 이 항목을 먼저 재검토한다.**

**Spot을 쓰지 않는다.** 비용 문서는 App Worker 2대의 Spot 전환을 권했지만, 같은 문서가
"짧은 실험에서는 절대 절감액이 작으므로 Spot 구성 자체가 학습 목표일 때 적용하는 편이 합리적"이라고
단서를 달았다. 40시간 기준 절감액은 1달러 미만이다. 다만 **Spot 중단을 노드 장애 실험의 입력으로
사용하는 것**은 이슈 #6에서 별도로 검토한다.

### 역할 분리 방식

**namespace가 아니라 node label + `nodeSelector`로 분리한다.**

- namespace(`beach`, `monitoring`)는 유지하되, 그 목적은 **쿼터·RBAC·이름 충돌 방지**로 한정한다.
- 실제 배치는 node label과 `nodeSelector`가 결정한다.
- 노드마다 라벨 두 개를 부여한다.
  - `node-role=<role>` — 매니페스트의 `nodeSelector` 키
  - `node-role.kubernetes.io/<role>=""` — `kubectl get nodes`의 ROLES 컬럼 표시용
- 라벨은 `kubeadm join` **이후** `kubectl label`로 부여한다. NodeRestriction admission plugin이
  kubelet의 `node-role.kubernetes.io/*` 자가 설정을 거부하기 때문이다.

### 운용 방식

**AWS 클러스터는 상시 운영하지 않는다.** 비용 문서의 2단계 운영 모델을 그대로 따른다.

| 단계 | 환경 | 용도 | AWS 비용 |
|---|---|---|---|
| 1 | **로컬 kind 4노드** | 매니페스트, 리소스 동작, 실험 절차의 1차 검증 | $0 |
| 2 | AWS EC2 4노드 | 노드 분리·장애 영역·클라우드 통합 검증, 부하 실험 | 실행 시간에 비례 |

- **kind는 폐기하지 않는다.** 주 개발 환경으로 유지하고, 로컬에서 통과한 것만 AWS로 올린다.
- 검증이 끝나면 `terraform destroy`로 **EBS까지 완전히 삭제한다.** EC2 `stop`은 EBS 요금이 계속
  발생하므로 절감 수단으로 쓰지 않는다.
- 클러스터 재생성이 항상 가능해야 하므로 etcd 데이터를 별도 볼륨에 보존하지 않는다.

### 계획서와의 관계

이 문서는 `plan.md`의 **`4.5 실행 환경 선택`만 정정한다.** 계획서 본문도 함께 갱신한다.

다음 항목은 **그대로 유효하다.**

- `4.4 왜 K3s가 아니라 표준 Kubernetes 환경인가` — 배포판 고유 기본값을 배제한다는 논리는
  관리형 서비스를 배제하는 근거로도 그대로 적용된다.
- `6.4 Won't`의 "EKS 상시 운영 — 로컬 Kubernetes 또는 임시 클라우드만 사용" — AWS 4노드를
  검증 시에만 생성하고 삭제하는 운영 모델은 이 항목과 어긋나지 않는다.

### 범위 제외

이 ADR은 다음을 결정하지 않는다.

- Amazon EKS 전환
- Control Plane 다중화(HA)
- 기존 compose 기반 관측 EC2의 철수 여부 → 이슈 #5
- `deploy/observability/**`의 수정. 이 저장소는 `Beach-complex/Beach_complex`의 fork이고 해당 트리는
  거기서 상속받은 코드다. 여기서 고치면 upstream 반영 시 충돌하거나 두 저장소가 갈라지므로
  **읽기 전용으로 취급하고 필요한 구조는 복사해서 쓴다.**
- 애플리케이션 배포 방식 → 이슈 #2
- Terraform 원격 backend 도입. 백엔드 문서 저장소의 `ADR-016`이 S3 backend를 명시했으나
  현재 코드에는 backend 블록이 없다.
  이 불일치는 별도 후속 과제로 다룬다.
- CNI 선택 → [Pod network add-on 선택 — Cilium](./cilium-cni.md)

## 근거

- **노드 분리는 노드가 실제로 분리되어야 검증된다.** 이슈 #1의 완료 기준이 "Control Plane 1개,
  App Worker 2개, Observability Worker 1개가 구분된다"인데, 이 구분이 의미를 가지려면
  장애 영역과 자원이 실제로 나뉘어야 한다.
- **이슈 #6의 Node 장애 실험이 성립한다.** EC2 인스턴스를 중지하는 것과 kind 노드 컨테이너를
  죽이는 것은 복구 경로가 다르다.
- **클라우드 운영 요소를 다룰 수 있다.** SG, IAM Role, EBS, AZ 배치는 kind에 없고,
  이 프로젝트가 증명하려는 운영 역량의 상당 부분이 여기에 있다.
- **기존 관측 인프라의 Terraform 자산을 확장할 수 있다.** 모듈을 그대로 공유하지는 않지만
  EC2·IAM·cloud-init 크기 가드·검증 스크립트 구조를 재사용한다.
- **kubeadm은 Kubernetes 구성요소를 직접 다룬다.** 계획서 `4.4`가 "배포판 고유 기본값이 결과에
  섞이지 않게 한다"를 이유로 표준 Kubernetes를 택했는데, 같은 논리가 관리형 서비스에도 적용된다.
  EKS는 control plane을 감추므로 `kubeadm init`/`join`, etcd, kubelet 등록 과정을 학습할 수 없다.

## 결과

### 긍정적 영향

- 노드 단위 장애 영역 분리와 `nodeSelector` 배치를 실제로 증명할 수 있다.
- 이슈 #6의 Node 장애 복구 실험이 의미 있는 형태로 성립한다.
- Security Group, IAM, EBS를 포함한 클라우드 인프라 구성이 코드로 남는다.
- control plane 구성요소(apiserver, etcd, scheduler, controller-manager)를 직접 다루게 된다.
- 관측 스택과 앱이 자원 경합 없이 분리된다.

### 부정적 영향

- **실행 시간에 비례해 비용이 발생한다.** 40시간 기준 약 `$6`이지만, 삭제를 잊고 한 달을 켜두면
  약 `$172`(20만원 상당)가 된다. 즉 비용 위험은 단가가 아니라 **삭제 누락**에 있다.
  기존 앱 EC2·관측 EC2까지 포함하면 실험 중에는 총 6대가 동시에 떠 있다.
- **단일 Control Plane이다.** CP 노드가 죽으면 클러스터 전체가 정지하고 etcd 스냅샷도 받지 않는다.
  이슈 #6의 장애 실험을 App Worker와 Pod로 한정해야 한다.
- **클러스터 운영 부담이 커진다.** 계획서가 kubeadm을 선택 과제로 둔 이유가 그대로 현실화된다.
  인증서 갱신, join 토큰 만료, CNI 상태 관리가 모두 직접 관리 대상이 된다.
- **로컬 재현이 불가능하다.** 다른 사람이 따라 하려면 AWS 계정과 권한이 필요하다.
- **실패 지점이 늘어난다.** cloud-init, containerd cgroup driver, CNI, SG가 모두 "노드가 Ready가
  되지 않는" 원인 후보가 된다.

## 대안

### 선택지 1: AWS EC2 kubeadm 4노드

- 장점: 노드 분리·장애 영역·클라우드 운영 요소를 모두 실증할 수 있다. control plane을 직접 다룬다.
- 단점: 비용과 운영 부담. 단일 CP 한계.
- 결론: **채택**

### 선택지 2: kind 유지 (계획서 기본안)

- 장점: 비용이 없고 재현이 빠르다. 매니페스트 검증에는 충분하다.
- 단점: 노드가 컨테이너라 장애 영역 분리가 성립하지 않는다. SG·IAM·EBS가 없다.
  이슈 #6의 Node 장애 실험이 형식적인 수준에 머문다.
- 결론: **주 환경에서는 거부. 매니페스트 문법 검증 용도로는 유지**

### 선택지 3: Amazon EKS

- 장점: control plane 운영 부담이 없고 AWS 통합이 좋다.
- 단점: control plane이 감춰져 kubeadm 학습 목표가 사라진다. 계획서 `6.4 Won't`의 비용 우려가
  더 크게 적용된다(control plane 시간당 요금 + 노드 비용).
- 결론: **거부.** 단, 클라우드 호환성 검증이 필요하면 임시로 사용하는 선택지는 남긴다

### 선택지 4: K3s

- 장점: 설치가 간단하고 자원 소모가 적어 같은 예산으로 노드를 더 둘 수 있다.
- 단점: 계획서 `4.4`가 "배포판 고유 기본 구성이 결과와 아키텍처 설명에 섞이지 않게 한다"를
  이유로 이미 비교 후보로 한정했다. 그 판단을 뒤집을 새 근거가 없다.
- 결론: **거부**

### 선택지 5: kind + EC2 혼합 (앱은 kind, 관측만 EC2)

- 장점: 비용을 줄이면서 일부 클라우드 요소를 다룬다.
- 단점: 두 환경에 걸친 네트워킹이 복잡해지고, 하나의 클러스터로 묶이지 않아
  `nodeSelector` 배치 실험 자체가 불가능하다.
- 결론: **거부**

## 검증 계획

이슈 #1의 완료 기준과 동일하다.

1. `kubectl get nodes`에서 4개 노드가 Ready다.
2. ROLES 컬럼에 `control-plane` 1개, `app` 2개, `observability` 1개가 표시된다.
3. `nodeSelector: node-role=observability`를 지정한 Pod가 관측 노드에 배치된다.
4. `terraform destroy` 후 같은 IaC와 부트스트랩 절차로 재생성했을 때 노드 이름·ROLES·버전이 동일하다.
5. Control Plane의 NoSchedule taint가 유지되어 앱 Pod가 배치되지 않는다.

## 롤백 / 재검토 기준

다음 조건이 발생하면 실행 환경을 재검토한다.

- 상시 비용이 감당 범위를 넘어선다. → kind로 회귀한다. 매니페스트는 그대로 재사용 가능하므로
  회귀 비용은 IaC와 부트스트랩 스크립트에 한정된다.
- 클러스터 운영 부담으로 실험 일정이 지연된다. 계획서가 예상한 위험이 현실화된 경우다.
- 단일 Control Plane 장애가 반복되어 실험 진행이 막힌다. → CP 다중화 또는 EKS를 재검토한다.
- 관리형 서비스 경험이 더 중요해진다. → EKS 전환을 별도 ADR로 다룬다.

## 참고

### 공식 문서 링크

- kubeadm으로 클러스터 생성: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- kubeadm 설치 사전 요구사항: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
- 노드에 Pod 할당 (nodeSelector): https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- Taints and Tolerations: https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- NodeRestriction admission plugin: https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#noderestriction
- kind: https://kind.sigs.k8s.io/
- EC2 요금: https://aws.amazon.com/ec2/pricing/on-demand/

### 관련 이슈 / PR

- 이슈 #1 기존 IaC 확장 및 AWS kubeadm 클러스터 구성
- 이슈 #5 Prometheus 및 Grafana 관측성 구성 (Observability Worker에 워크로드 배치)
- 이슈 #6 Pod 및 App Worker Node 장애 복구 실험

### 관련 문서

- [Pod network add-on 선택 — Cilium](./cilium-cni.md)
- `Beach-complex/docs` 저장소 `ADR-016 관측 인프라 IaC 도입 — Terraform + cloud-init`
  — 재검토 기준의 "Kubernetes 전환" 항목이 이 결정에 해당한다
- [`../cost.md`](../cost.md)
  — 4노드 기준 아키텍처와 2단계 운영 모델의 출처. 이 문서의 전제다
- [`../plan.md`](../plan.md) `4.5` — 이 문서가 정정하는 항목
- [`../../tempdocs/issue-1/`](../../tempdocs/issue-1/) — 이슈 #1 PR 1~5 구현 문서

## 작성일자

2026-09-20
