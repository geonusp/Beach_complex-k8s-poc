# 관측 스택 설치 방식

## 상태

Proposed — `kube-prometheus-stack` Helm 차트를 축소 구성으로 사용한다.

## 컨텍스트

이슈 #5는 Beach 애플리케이션과 Kubernetes workload 지표를 Prometheus·Grafana로 관측하도록 요구한다.
필요한 지표와 그 출처는 다음과 같다.

| 지표 | 출처 |
| --- | --- |
| HTTP 요청량·오류율·latency, JVM memory·GC | Beach Pod `/actuator/prometheus` (management 포트 8081) |
| Pod CPU·memory | kubelet 내장 cAdvisor |
| Pod restart 횟수 | kube-state-metrics |
| 노드 CPU·메모리·디스크 | node-exporter |

제약은 다음과 같다.

- 관측 워크로드는 `obs-1`(t3.medium, 메모리 4GiB, 루트 볼륨 30GB)에 둔다. 이슈 #3·#4의 k6 Job도 같은 노드를 쓴다.
- 클러스터는 측정할 때만 만들고 끝나면 `terraform destroy` 한다. 설치는 bootstrap 스크립트로 매번 재현돼야 한다.
- Control Plane에는 `helm`이 이미 있다(`install-cilium.sh`).
- kubeadm은 etcd·scheduler·controller-manager의 metrics를 `127.0.0.1`에만 바인드하고, kube-proxy도 기본값으로는 같다.

이전 EC2 구성(`deploy/observability/compose/`)은 docker-compose와 정적 target이라 Pod IP가 바뀌는 Kubernetes에 그대로 쓸 수 없다.

## 결정

**`kube-prometheus-stack` Helm 차트를 고정 버전으로 설치하고, 값 파일로 구성요소를 줄인다.**

- 포함: Prometheus Operator, Prometheus, Grafana, kube-state-metrics, node-exporter
- 제외: Alertmanager, kubeadm control plane 구성요소(etcd·scheduler·controller-manager·kube-proxy) scrape
- node-exporter DaemonSet을 뺀 모든 구성요소에 `nodeSelector: node-role=observability`를 둔다.
- Beach는 `PodMonitor`로 Pod의 8081을 직접 scrape한다. Service에 8081을 추가하지 않는다.
- 보존: `retention: 2d`, `retentionSize: 5GB`, `scrapeInterval: 30s`, 저장소는 `emptyDir`
- Grafana·Prometheus는 `ClusterIP`로 두고 SSM 포트 포워딩으로 접근한다.

### 범위 제외

- Alertmanager와 알림 규칙
- 영구 저장소(EBS PV), 장기 보존(Thanos, remote write)
- 로그(Loki), 분산 추적(Tempo)
- NetworkPolicy로 8081 접근 제한

## 근거

- **필요한 수집기가 한 번에 들어온다.** restart 지표에 필요한 kube-state-metrics와 kubelet·cAdvisor scrape 설정이 기본 포함된다.
  직접 작성하면 kubelet scrape의 TLS·RBAC 설정을 직접 만들어야 한다.
- **Pod IP 변화를 operator가 처리한다.** `PodMonitor`로 선언만 하면 target이 Pod 교체(Rolling Update, HPA)를 따라간다.
  이슈 #3·#4처럼 Pod가 자주 바뀌는 실험과 맞는다.
- **업계에서 널리 쓰는 구성이다.** 포트폴리오 PoC로서 설명 비용이 낮다.
- **구성요소를 끌 수 있다.** 값 파일로 Alertmanager와 바인드 문제로 `DOWN`이 될 target을 빼서 `obs-1` 자원과
  "Prometheus target이 정상 상태다" 완료 기준을 함께 맞출 수 있다.

## 결과

### 긍정적 영향

- `install-observability.sh` 하나로 매 클러스터에서 같은 구성이 재현된다.
- Grafana 기본 dashboard(노드·Pod·workload)를 바로 쓸 수 있다.
- 이슈 #4에서 HPA·부하 실험 중 Pod·노드 지표를 같은 도구로 본다.

### 부정적 영향

- 의존성이 크다. CRD 10여 개와 operator가 추가되고 차트 값 구조를 알아야 한다.
- 메모리 사용이 직접 작성한 Prometheus 단일 Deployment보다 크다. `obs-1`에서 k6와 경쟁한다.
- control plane 구성요소 지표가 없다. API server는 수집하지만 etcd·scheduler·controller-manager는 보지 못한다.
- TSDB가 클러스터와 함께 사라진다. 증거는 조회 결과를 따로 회수해야 한다.

## 대안

### 선택지 1: `kube-prometheus-stack` Helm 차트 축소 구성

- 장점: 수집기·scrape 설정·dashboard가 포함된다. `PodMonitor`로 Pod 교체를 따라간다.
- 단점: 의존성과 메모리 사용이 크다.
- 결론: **채택.**

### 선택지 2: `prometheus-community/prometheus` 차트(operator 없음)

- 장점: operator·CRD가 없어 가볍다. annotation 기반 Pod 발견으로 Beach scrape가 간단하다.
- 단점: Grafana를 따로 설치하고 datasource·dashboard를 직접 구성해야 한다. 설정이 차트 한 곳에 모이지 않는다.
- 결론: 보류. `obs-1` 메모리가 부족하면 전환을 검토한다.

### 선택지 3: 직접 작성한 매니페스트

- 장점: 의존성이 가장 적고 구성을 완전히 통제한다.
- 단점: kubelet·cAdvisor scrape의 TLS·RBAC, kube-state-metrics, Grafana provisioning을 모두 직접 작성·유지해야 한다.
- 결론: 기각. 이 PoC의 목적은 관측 도구 구현이 아니라 workload 관측이다.

### 선택지 4: 관리형 서비스(Amazon Managed Service for Prometheus·Grafana)

- 장점: `obs-1` 자원을 쓰지 않고 데이터가 클러스터 destroy 뒤에도 남는다.
- 단점: 수집 agent, IAM, workspace 비용이 추가된다. 노드 IAM 역할을 노드 4대가 공유하는 현재 구조에서 권한 범위가 넓어진다.
- 결론: 기각. 단명 클러스터 PoC에 비해 설정 비용이 크다.

## 검증 계획

1. `helm template` 결과를 `kubeconform`으로 검증한다.
2. 렌더링 결과에서 `nodeSelector`와 Alertmanager 미포함을 assertion으로 확인한다.
3. 실제 클러스터에서 Prometheus `/api/v1/targets`의 모든 active target이 `up`인지 확인한다.
4. `obs-1`의 `kubectl top pod`로 Prometheus·Grafana 메모리를 측정해 자원 예산과 비교한다.

## 롤백 / 재검토 기준

- Prometheus가 `obs-1`에서 OOMKilled되거나 k6와의 경쟁으로 scrape가 밀리면 선택지 2로 전환하거나 `obs-1` 사양을 올린다.
- control plane 구성요소 지표가 필요해지면 kubeadm `ClusterConfiguration`의 `extraArgs`로 bind address를 바꾸고 해당 scrape를 켠다.
- 측정 결과를 클러스터 수명 이상 보존해야 하면 remote write나 관리형 서비스를 재검토한다.

## 참고

### 공식 문서 링크

- [kube-prometheus-stack 차트](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Prometheus Operator PodMonitor](https://prometheus-operator.dev/docs/developer/getting-started/#using-podmonitors)
- [Prometheus storage (retention)](https://prometheus.io/docs/prometheus/latest/storage/)
- [kube-state-metrics Pod 지표](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md)
- [Spring Boot Prometheus 메트릭 내보내기](https://docs.spring.io/spring-boot/reference/actuator/metrics.html#actuator.metrics.export.prometheus)

### 관련 이슈 / PR

- 이슈 #5 Prometheus 및 Grafana 관측성 구성
- 이슈 #4 HPA 및 k6 부하 테스트

### 관련 문서

- [k6 부하 생성기 실행 위치](./load-generator-placement.md)
- [Ephemeral 의존성 배치](./ephemeral-dependency-placement.md)
- [이슈 #5 구현 문서](../../tempdocs/issue-5/README.md)

## 작성일자

2026-10-11
