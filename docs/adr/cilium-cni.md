# Pod network add-on 선택 — Cilium 및 Pod CIDR 대역 확정

## 상태

Proposed

## 컨텍스트

[실행 환경 결정](./k8s-execution-environment.md)에 따라 AWS EC2 기반 kubeadm 클러스터로 바뀌면서 **CNI 선택이 필수 결정이 되었다.**

kubeadm은 Pod network add-on을 포함하지 않는다. `kubeadm init` 직후 모든 노드는 `NotReady` 상태이고
CoreDNS Pod는 `Pending`에 머문다. CNI를 설치해야 비로소 노드가 Ready가 된다.
즉 이슈 #1의 완료 기준 "4개 Node가 Ready 상태다"는 CNI 없이는 달성할 수 없다.

반면 `plan.md`에서 Cilium의 위치는 다음과 같았다.

- `5.2 학습 목표` — "선택 심화: Cilium CNI, Hubble flow, NetworkPolicy 기반 장애 분석"
- `6.2 Should` — `S6 | Cilium CNI | kind 생성 단계에서 기본 CNI를 비활성화하고 Cilium을 설치한다`

kind는 기본 CNI(kindnet)를 제공하므로 Cilium은 "기본을 끄고 바꿔 끼우는 선택 항목"이었다.
kubeadm에서는 기본값이 없으므로 **선택 심화가 아니라 필수 구성요소**가 된다.

이 결정에 따라 계획서를 정정했다. Cilium CNI는 `6.2 Should`의 `S6`에서 `6.1 Must`의 `M12`로 올렸고,
완료 기준도 kind 기준("기본 CNI 비활성화")에서 kubeadm 기준("전 노드가 Ready")으로 바꿨다.
기존 `S7`(Hubble 장애 분석)은 `S6`이 되었다.

동시에 이슈 #7 "Cilium 및 Hubble 기반 NetworkPolicy 장애 분석"은 이미 Cilium을 전제로 설계되어 있다.
그리고 CNI 교체는 실질적으로 클러스터 재구축에 해당하므로, 되돌리기 비용이 큰 결정이다.

여기에 더해 **Pod CIDR 대역을 이 시점에 확정해야 한다.** Cilium의 기본 cluster-pool IPAM은
`10.0.0.0/8`에서 Pod IP를 할당한다.

**대상 VPC(`beach-vpc`)의 CIDR을 조회한 결과 `10.0.0.0/16`이다.** 즉 Cilium 기본값을 그대로 쓰면
Pod 대역 `10.0.0.0/8`이 VPC 대역 `10.0.0.0/16`을 통째로 포함한다. 증상은 "Pod는 뜨지만 노드 간
통신이나 AWS API 호출이 간헐적으로 실패"로 나타나 원인 추적이 어렵고, 대역을 바꾸려면 클러스터를
다시 만들어야 한다. **이 저장소의 환경에서는 가정이 아니라 실제로 발생하는 충돌이다.**

## 결정

Pod network add-on으로 **Cilium**을 채택한다.

### 설치 방식

- **Helm**으로 설치하고 값을 `deploy/k8s/cilium/values.yaml`로 저장소에 커밋한다.
  `cilium-cli`의 기본값은 버전에 따라 달라질 수 있어 재현성 측면에서 values 파일을 기준으로 한다.
- 버전은 patch 단위까지 고정하고, 설치할 Kubernetes 버전과의 호환성을 사전에 확인한다.

### 초기 구성 범위

| 항목 | 이슈 #1에서의 설정 | 비고 |
|---|---|---|
| IPAM | cluster-pool | Pod CIDR 명시 |
| `kubeProxyReplacement` | **비활성** (kube-proxy 유지) | 이슈 #7에서 재검토 |
| Hubble | **비활성** | 이슈 #7에서 활성화 |
| NetworkPolicy | 정책 미적용 | 이슈 #7에서 설계 |
| 암호화(WireGuard/IPsec) | 미사용 | 범위 밖 |

이슈 #1의 목적은 "4개 노드가 Ready"까지다. 기능을 켤수록 노드가 Ready가 되지 않는 원인 후보가 늘어나므로
**최소 구성으로 시작하고 기능은 해당 이슈에서 켠다.**

### Pod CIDR

Pod CIDR을 **`10.244.0.0/16`** 으로 고정하고, 두 곳의 값을 반드시 일치시킨다.

**검증 완료.** 계정 내 VPC는 `beach-vpc`(`10.0.0.0/16`)와 기본 VPC(`172.31.0.0/16`) 두 개이며,
`10.244.0.0/16`은 둘 중 어느 대역과도 겹치지 않는다.

```
kubeadm init --pod-network-cidr=10.244.0.0/16
```

```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.244.0.0/16
```

VPC를 새로 만들거나 CIDR을 바꾸는 경우에는 이 검증을 다시 수행하고, 겹치면 양쪽 값을 함께 바꾼다.

### 범위 제외

- kube-proxy replacement 적용 여부 → 이슈 #7
- Hubble, Hubble Relay, Hubble UI 구성 → 이슈 #7
- NetworkPolicy 정책 설계 → 이슈 #7
- eBPF datapath 심화, Service datapath 성능 비교 → `cilium-ebpf-roadmap.md`
- Cluster Mesh, 암호화, Ingress Controller로서의 Cilium

## 근거

- **이슈 #7이 Hubble을 전제로 설계되어 있다.** Hubble은 Cilium의 관측 컴포넌트이므로
  다른 CNI를 고르면 이슈 #7을 통째로 다시 설계해야 한다.
  다만 이것은 **기술적 우위가 아니라 경로 의존성**이다. Istio를 택했다면 fault injection과
  Kiali 기반으로 같은 목적의 실험을 설계할 수 있었다. 이 항목은 "이미 정한 것을 뒤집는 비용"으로만
  읽어야 하고, Cilium이 관측에서 더 낫다는 근거로 쓰면 안 된다.
- **NetworkPolicy 장애 분석에는 flow 수준 관측이 필요하다.** "정책 때문에 막혔다"를 증명하려면
  드롭된 플로우를 볼 수 있어야 한다. Hubble은 이걸 제공하고, 이것이 이슈 #7의 핵심이다.
- **eBPF datapath 학습이 계획서의 학습 목표에 있다.** `5.2 학습 목표`의 선택 심화 항목이고
  별도 로드맵 문서(`cilium-ebpf-roadmap.md`)까지 준비되어 있다.
- **kubeadm 환경에서 표준적으로 검증된 선택지다.** 설치 문서와 사례가 충분하다.
- 계획서가 이미 Cilium을 후보로 정리해 두었으므로, 다른 CNI를 고르면
  **기존 문서 자산 세 건**(계획서의 Cilium·Hubble 항목, 이슈 #7, eBPF 로드맵)이 동시에 무효가 된다.
- **L7 정책은 표준 NetworkPolicy로 대체할 수 없다.** Kubernetes 표준 NetworkPolicy는
  L3/L4(IP·포트)까지만 다룬다. `CiliumNetworkPolicy`는 HTTP 메서드와 경로 단위로 제어할 수 있어,
  이슈 #7의 장애 주입을 "포트를 막았다"가 아니라 "특정 엔드포인트만 막았다" 수준으로 설계할 수 있다.
  Istio 같은 사이드카를 붙이지 않고 가능하다는 점도 이 규모에서 의미가 있다.
  이슈 #5의 "metrics endpoint를 외부에 노출하지 않는다"도 L7 정책으로 정밀하게 표현된다.
- **성능 이점은 이 PoC의 결정 근거로 삼지 않는다.** eBPF 데이터패스가 규칙 수 증가에
  iptables보다 덜 민감하다는 것은 알려진 특성이지만, **4노드·소수 Pod 규모에서는 측정되지 않는다.**
  Calico도 eBPF 데이터플레인 모드를 제공하므로 "eBPF냐 아니냐"가 곧 "Cilium이냐 아니냐"도 아니다.
  계획서 `6.4`가 kube-proxy datapath 성능 비교를 범위 밖으로 둔 것과도 일치한다.
  이 주제는 후속 확장([`../cilium-ebpf-roadmap.md`](../cilium-ebpf-roadmap.md))에서 다룬다.

## 결과

### 긍정적 영향

- 이슈 #7의 NetworkPolicy 장애 분석을 계획대로 수행할 수 있다.
- eBPF 기반 datapath를 다루게 되어 학습 목표와 포트폴리오 가치가 커진다.
- Hubble을 켜면 서비스 간 통신을 별도 계측 없이 관측할 수 있다.
- kube-proxy replacement, 암호화, Cluster Mesh 등 후속 확장 여지가 넓다.

### 부정적 영향

- **다른 CNI보다 자원을 더 쓴다.** 노드마다 cilium agent가 뜨고 eBPF 맵이 메모리를 점유한다.
  t3.small App Worker에서는 무시할 수 없는 비중이다.
- **장애 시 진입 장벽이 높다.** eBPF 기반이라 문제 발생 시 `iptables` 확인 같은 익숙한 방법이
  통하지 않고 `cilium` CLI와 개념 학습이 선행되어야 한다.
- **Kubernetes 버전 호환성을 계속 확인해야 한다.** Kubernetes를 올릴 때 Cilium도 함께 올려야 한다.
- **Pod CIDR 충돌 위험이 있다.** 기본값이 `10.0.0.0/8`이라 AWS VPC 대역과 겹치기 쉽다.
  이 ADR에서 대역을 명시적으로 고정하는 이유다.
- **되돌리기 비용이 크다.** CNI 교체는 사실상 클러스터 재구축이다.

## 대안

### 선택지 1: Cilium

- 장점: Hubble flow 관측, NetworkPolicy, eBPF 학습 가치. 이슈 #7과 기존 문서 자산이 전제로 삼고 있다.
- 단점: 자원 소모와 학습 곡선. Pod CIDR 기본값이 VPC와 충돌하기 쉽다.
- 결론: **채택**

### 선택지 2: Calico

- 장점: NetworkPolicy를 지원하고 자료가 많다. 자원 소모가 상대적으로 적고
  `iptables` 모드에서는 디버깅이 익숙하다.
- 단점: Hubble에 해당하는 flow 관측 UI가 기본 제공되지 않아 이슈 #7의 "장애 분석"을
  다시 설계해야 한다. eBPF 학습 목표와 로드맵 문서가 무효가 된다.
- 결론: **거부.** Cilium 운영 부담이 감당 불가로 판명되면 1순위 대체 후보

### 선택지 3: flannel

- 장점: 가장 단순하고 가볍다. 설치가 빠르다.
- 단점: **NetworkPolicy를 지원하지 않는다.** 이슈 #7이 아예 불가능해진다.
- 결론: **거부**

### 선택지 4: Istio (다른 CNI 위에 서비스 메시로 L7 확보)

**L7 제어라는 축에서는 Cilium과 동일 선상의 후보다.** 오히려 기능 범위는 Istio가 더 넓다.

| L7 축 | Cilium L7 정책 | Istio |
| --- | --- | --- |
| HTTP 메서드·경로 허용/차단 | O | O |
| 결함 주입 (HTTP 오류·지연) | X — 드롭만 가능 | **O — 내장 기능** |
| 트래픽 시프팅·재시도·타임아웃 | X | O |
| mTLS | 별도 기능(WireGuard 등)으로 대체 | O |
| 흐름 관측 | Hubble | Kiali + 분산 추적 |

**이슈 #7의 "장애 주입"만 놓고 보면 Istio의 fault injection이 더 직접적이다.**
Cilium은 정책으로 패킷을 드롭할 수 있을 뿐, HTTP 500이나 지연을 주입하지는 못한다.

- 장점:
  - 위 표대로 L7 기능이 넓고, 장애 주입 실험의 표현력이 크다.
  - CNI 선택과 무관하게 적용할 수 있어 나중에 얹는 것도 가능하다.
  - 업계 표준이고 자료가 많다.
- 단점:
  - **CNI를 대체하지 않는다.** Istio를 택해도 Calico 같은 CNI는 따로 골라야 한다.
    즉 `Calico + Istio` 두 개를 운영하게 되는데, Cilium은 CNI 슬롯을 채우면서 L7까지 같이 오므로
    하나로 끝난다.
  - Pod마다 Envoy 사이드카가 붙는다. t3.small 워커에서 앱 Pod 옆에 프록시가 뜨면
    **이슈 #4의 HPA·부하 실험 결과가 프록시 CPU 사용량에 오염된다.**
  - **제어 계층이 하나 더 생긴다.** `istiod`가 `istio-system`에 뜨고 사이드카 주입을 위한
    mutating admission webhook을 등록한다. istiod나 웹훅이 응답하지 않으면 `failurePolicy`에 따라
    **Pod 생성 자체가 거부될 수 있어** 장애 원인 후보가 늘어난다.
    (노드의 Ready 여부는 kubelet과 CNI가 결정하므로 Istio와는 무관하다.)
  - 계획서 `6.4 Won't`가 "학습 비용이 크고 핵심 목표가 흐려짐"을 이유로 이미 제외했다.
- 결론: **거부.** 기능이 부족해서가 아니라 **이 규모에서 비용이 이득을 넘어서기 때문**이다.
  L7 제어 하나만 필요하다면 CNI 슬롯에서 같이 해결하는 편이 구성요소가 적다.
  서비스 메시 전반(mTLS, 트래픽 시프팅)이 목표가 되면 별도 결정으로 다룬다

### 선택지 5: AWS VPC CNI

- 장점: Pod가 VPC IP를 직접 받아 AWS 네트워킹과 통합된다. Pod CIDR 충돌 문제가 없다.
- 단점: EKS 밖에서 self-managed로 운용하려면 설정 부담이 크다. 인스턴스 타입별
  ENI·IP 할당 한도에 묶여 t3.small에서 Pod 수가 제한된다. NetworkPolicy를 쓰려면
  별도 에이전트가 추가로 필요하다.
- 결론: **거부.** EKS로 전환하면 재검토

## 검증 계획

1. `kubectl -n kube-system rollout status daemonset/cilium`이 4/4로 완료된다.
2. `kubectl get nodes`에서 4개 노드가 Ready로 전환된다. (설치 전 NotReady → 설치 후 Ready)
3. CoreDNS Pod가 `Pending`에서 `Running`으로 전환된다.
4. 서로 다른 노드의 Pod 간 통신이 성공한다.
5. Pod IP가 `10.244.0.0/16` 범위에서 할당되고 VPC CIDR과 겹치지 않는다.
6. `cilium status`가 정상을 보고한다.
7. 클러스터 재생성 후에도 같은 버전과 같은 Pod CIDR로 설치된다.

## 롤백 / 재검토 기준

- **Cilium 자원 소모가 App Worker 실험에 영향을 준다.** 이슈 #4의 HPA·부하 테스트 결과가
  agent 자원 점유로 왜곡되면 인스턴스 타입 상향 또는 Calico 전환을 검토한다.
- **Kubernetes 버전과 호환되지 않는다.** 버전 조합을 다시 고정하거나 Kubernetes 버전을 조정한다.
- **eBPF 기반 장애 진단 비용이 과도하다.** 계획서가 이미 위험으로 기록한 항목이다
  ("Cilium/Hubble 설정 지연 → Cilium 상태 복구를 우선하고 Hubble 장애 실험은 후속으로 이동").
- **kube-proxy replacement가 필요해진다.** 이슈 #7에서 별도로 판단하고 필요하면 이 ADR을 갱신한다.
- CNI를 교체하는 경우 클러스터를 재생성한다. 노드 인프라(PR 2)와 부트스트랩(PR 3)은 재사용된다.

## 참고

### 공식 문서 링크

- kubeadm Pod network add-on 설치: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/#pod-network
- Cilium Helm 설치: https://docs.cilium.io/en/stable/installation/k8s-install-helm/
- Cilium cluster-pool IPAM: https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/
- Cilium 시스템 요구사항 (방화벽 규칙 포함): https://docs.cilium.io/en/stable/operations/system_requirements/
- Cilium kube-proxy replacement: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
- Hubble: https://docs.cilium.io/en/stable/observability/hubble/
- Kubernetes NetworkPolicy: https://kubernetes.io/docs/concepts/services-networking/network-policies/
- Calico: https://docs.tigera.io/calico/latest/about/
- AWS VPC CNI: https://github.com/aws/amazon-vpc-cni-k8s

### 관련 이슈 / PR

- 이슈 #1 작업 8 — Cilium을 첫 Pod network add-on으로 설치한다
- 이슈 #7 Cilium 및 Hubble 기반 NetworkPolicy 장애 분석

### 관련 문서

- [Kubernetes 실행 환경 — AWS kubeadm 4노드](./k8s-execution-environment.md) — 이 결정의 전제
- [`../plan.md`](../plan.md) `6.1 M12` — 이 결정에 따라 정정된 항목 (정정 전에는 `6.2 S6`)
- [`../cilium-ebpf-roadmap.md`](../cilium-ebpf-roadmap.md) — 후속 eBPF 심화 로드맵
- [`../../tempdocs/issue-1/pr-4-kubeadm-cilium.md`](../../tempdocs/issue-1/pr-4-kubeadm-cilium.md) — 구현 절차

## 작성일자

2026-09-20
