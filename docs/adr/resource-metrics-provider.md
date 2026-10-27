# Resource metrics 제공 방식

## 상태

Proposed — Metrics Server를 `obs-1`에 설치하고, kubelet 인증서 검증은 `serverTLSBootstrap`으로 유지한다.
현재 저장소의 bootstrap에 CSR 승인·Metrics Server 설치 단계가 포함돼 있다. 아래에는 2026-10-14 검증 기록을 보존하며, 이 문서 검토로 Proposed 상태를 변경하지 않는다.

## 컨텍스트

이슈 #5는 `kubectl top node`와 `kubectl top pod`가 값을 반환하기를 요구하고, 이슈 #4의 HPA는 CPU 사용률로 Pod 수를 조정한다.
둘 다 Prometheus가 아니라 API server의 Resource Metrics API(`metrics.k8s.io`)를 읽는다.
kubeadm은 이 API의 제공자를 설치하지 않는다.

제약은 다음과 같다.

- kubeadm이 만드는 kubelet은 기본적으로 **자체 서명 serving 인증서**를 쓴다. 클러스터 CA로 검증하는 클라이언트는 kubelet `:10250`에 접속할 때 `x509` 오류로 실패한다.
- 클러스터는 측정할 때만 만들고 끝나면 `terraform destroy` 한다. 설정은 bootstrap 스크립트로 매번 재현돼야 한다.
- 노드는 4대(cp-1, app-1, app-2, obs-1)이고 노드를 추가하지 않는다. Control Plane에는 taint가 있고, `obs-1`은 관측 워크로드와 k6 Job이 쓴다.
- 2026-10-14 측정에서 app-2 메모리 사용률은 69%였다.

이 ADR은 세 가지를 함께 결정한다. API 제공자, kubelet TLS 처리, 배치 노드다. 세 결정은 서로 전제가 된다.

## 결정

1. **API 제공자:** `metrics-server` Helm 차트 `3.14.0`을 `kube-system`에 설치한다. replica는 1개다.
2. **kubelet TLS:** `--kubelet-insecure-tls`를 쓰지 않는다. `kubeadm init` 설정의 `KubeletConfiguration`에 `serverTLSBootstrap: true`를 넣고, bootstrap이 kubelet-serving CSR을 승인한다.
   - 승인 조건은 signer `kubernetes.io/kubelet-serving`, 요청자 `system:node:<Terraform 노드 이름>`, 미처리 상태를 모두 만족하는 것이다.
3. **배치:** `nodeSelector: node-role: observability`로 `obs-1`에 둔다.

bootstrap 순서는 노드 라벨 → kubelet serving CSR 승인 → Metrics Server 설치다. 라벨이 있어야 배치되고, 인증서가 있어야 kubelet에 접속할 수 있다.

### 범위 제외

- Metrics Server 고가용성(replica 2개 이상, PodDisruptionBudget)
- kubelet serving 인증서 갱신 자동화. 단명 클러스터라 만료 전에 destroy한다.
- CSR의 SAN(노드 IP·hostname) 검사
- Prometheus 지표를 `metrics.k8s.io`·custom metrics API로 제공하는 구성

## 근거

- **HPA와 `kubectl top`이 요구하는 API를 가장 단순하게 제공한다.** Metrics Server는 kubelet의 resource metrics만 메모리에 들고 있는 경량 구성요소다. 실측 사용량은 CPU 3m, 메모리 16Mi다.
- **HPA가 Prometheus 상태에 묶이지 않는다.** Prometheus는 PR 4에서 `obs-1`에 들어오며 TSDB 크기·scrape 지연의 영향을 받는다. 이슈 #4는 CPU 기반 HPA라 Prometheus 데이터를 거칠 이유가 없다.
- **인증서 검증을 끄지 않는다.** `--kubelet-insecure-tls`는 설정 1줄이지만 Metrics Server 문서도 테스트 용도로만 권장한다. 클러스터를 매번 새로 만들기 때문에 bootstrap에 CSR 승인 단계를 넣는 비용이 작다.
- **측정 대상과 측정 도구를 다른 노드에 둔다.**
  - nodeSelector가 없으면 Control Plane taint 때문에 App 노드에 배치된다.
  - App 노드에 부하가 몰리는 순간이 HPA가 판단해야 하는 순간이다. 그때 Metrics Server가 Beach Pod와 자원을 다투거나 eviction되면 HPA 판단이 멈춘다.
  - Control Plane에 두려면 toleration이 필요하고 apiserver·etcd와 같은 노드를 쓴다.
- **관측 구성요소를 한 노드에 모은다.** [관측 스택 설치 방식](./observability-stack-installation.md)과 같은 배치 원칙이다.

Metrics Server는 위치와 무관하게 모든 노드의 kubelet `:10250`에 접속하므로 배치 노드가 수집 범위를 바꾸지 않는다.

## 결과

### 긍정적 영향

- `kubectl top node`·`kubectl top pod -A`가 값을 반환한다. 2026-10-14 실제 클러스터에서 노드 4대와 전체 Pod 값, Metrics Server 로그의 `x509` 오류 0건을 확인했다.
- 이슈 #4 HPA의 선행 조건이 갖춰진다.
- kubelet이 클러스터 CA 인증서를 쓰므로 PR 4의 Prometheus kubelet scrape도 나중에 TLS 검증을 켤 수 있다.

### 부정적 영향

- **`obs-1`이 단일 장애점이 된다.** `obs-1`이 멈추면 `kubectl top`과 HPA 판단도 멈춘다.
- **`obs-1`에서 k6 Job과 같은 노드를 쓴다.** 사용량이 작아 실제 경쟁 가능성은 낮지만 고부하 실험에서 함께 관찰해야 한다.
- **`kubeadm init` 방식이 바뀌어 클러스터 재생성이 필요하다.** `serverTLSBootstrap`은 init 시점 설정이라 이전에 만든 클러스터에는 적용되지 않는다.
- bootstrap 단계가 2개 늘어난다(CSR 승인, Metrics Server 설치). CSR 승인은 노드가 늦게 join하면 기본 300초까지 기다린다.

## 대안

### 선택지 1: Metrics Server + `serverTLSBootstrap` + `obs-1` 배치

- 장점: 인증서 검증을 유지한다. HPA가 Prometheus와 분리된다. 측정 대상 노드와 분리된다.
- 단점: bootstrap에 CSR 승인 단계가 필요하다. `obs-1` 단일 장애점.
- 결론: **채택.**

### 선택지 2: Metrics Server + `--kubelet-insecure-tls`

- 장점: 설정 1줄. CSR 승인과 `kubeadm init` 변경이 필요 없다.
- 단점: kubelet 인증서 검증을 끈다. Metrics Server와 kubelet 사이 통신에서 서버 신원을 확인하지 않는다.
- 결론: 기각.

### 선택지 3: `prometheus-adapter`로 Prometheus 데이터를 `metrics.k8s.io`로 제공

- 장점: 수집 경로가 Prometheus 하나로 통일된다. custom metrics HPA로 확장할 수 있다.
- 단점: HPA가 Prometheus의 가용성·scrape 지연에 묶인다. 변환 규칙을 직접 작성해야 한다. PR 4 이전에는 쓸 수 없다.
- 결론: 기각. 요청량·latency 기반 HPA가 필요해지면 재검토한다.

### 선택지 4: Metrics Server를 App 노드에 배치 (nodeSelector 없음)

- 장점: 설정이 없다. App 노드 2대 중 하나가 멈춰도 다른 노드로 재배치될 수 있다.
- 단점: HPA가 판단해야 하는 부하 상황에서 Beach Pod와 같은 노드 자원을 쓴다. app-2는 이미 메모리 69%다.
- 결론: 기각. 단일 장애점 문제가 실제로 생기면 replica 2개 + App 노드 분산과 함께 재검토한다.

## 검증 계획

1. 오프라인: `bash deploy/k8s/scripts/test-bootstrap-scripts.sh`
   - kubeadm 설정 파일에 `serverTLSBootstrap: true`가 들어간다.
   - 알려진 노드의 kubelet-serving CSR만 승인한다.
   - Metrics Server values가 `obs-1`에 고정되고 `kubelet-insecure-tls`를 포함하지 않는다.
2. 실제 클러스터:
   - `kubectl get csr`에서 kubelet-serving CSR이 노드 4대 모두 `Approved,Issued`
   - `openssl s_client -connect <노드 IP>:10250 -CAfile /etc/kubernetes/pki/ca.crt` 결과 `Verify return code: 0 (ok)`
   - `kubectl top node`, `kubectl top pod -A` 값 반환, Metrics Server 로그 `x509` 0건, Pod가 `obs-1`에서 실행

1·2 모두 2026-10-14에 통과했다(#24, #25).

## 롤백 / 재검토 기준

- 이슈 #4 부하 실험에서 `obs-1` 장애나 자원 부족으로 HPA 판단이 멈추면 replica 2개를 App 노드에 분산하는 구성을 검토한다.
- HPA가 요청량·latency 같은 애플리케이션 지표를 기준으로 해야 하면 `prometheus-adapter`를 재검토한다.
- 클러스터 수명이 kubelet serving 인증서 유효기간에 가까워지면 CSR 자동 승인 컨트롤러(예: kubelet-csr-approver)를 검토한다.

## 참고

### 공식 문서 링크

- [Resource metrics pipeline](https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/)
- [Metrics Server 요구사항](https://github.com/kubernetes-sigs/metrics-server#requirements)
- [Metrics Server Helm 차트](https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server)
- [kubeadm kubelet serving 인증서](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/#kubelet-serving-certs)
- [Certificate Signing Requests — kubelet-serving signer](https://kubernetes.io/docs/reference/access-authn-authz/certificate-signing-requests/#kubernetes-signers)
- [Horizontal Pod Autoscaling](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/)
- [Taints and Tolerations](https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/)

### 관련 이슈 / PR

- 이슈 #5 Prometheus 및 Grafana 관측성 구성
- 이슈 #4 HPA 및 k6 부하 테스트
- PR #24 kubelet serving 인증서를 클러스터 CA로 발급
- PR #25 Metrics Server를 관측 노드에 설치
- 이슈 #23 SSM 등록 전 bootstrap 실패

### 관련 문서

- [관측 스택 설치 방식](./observability-stack-installation.md)
- [k6 부하 생성기 실행 위치](./load-generator-placement.md)
- [Kubernetes 실행 환경](./k8s-execution-environment.md)

## 작성일자

2026-10-14
