# Ephemeral PostgreSQL·Redis 배치 위치

## 상태

Accepted

## 컨텍스트

Beach 애플리케이션은 PostgreSQL과 Redis가 있어야 정상 기동한다. 현재 AWS Kubernetes 클러스터는
검증할 때만 생성하고 `terraform destroy`로 삭제하는 단명 클러스터다. 따라서 운영용 RDS나 ElastiCache를
추가하는 대신, 검증에 필요한 의존성을 클러스터 안에 임시로 배치한다.

클러스터에는 다음 역할의 노드가 있다.

| 노드 | 역할 | 사양 | 기본 용도 |
|---|---|---|---|
| `cp-1` | control-plane | t3.medium | Kubernetes 제어 컴포넌트 |
| `app-1`, `app-2` | app | t3.small | Beach 애플리케이션 |
| `obs-1` | observability | t3.medium | Prometheus/Grafana 등 관측 워크로드 |

PostgreSQL과 Redis를 `obs-1`에 넣으면 관측성 노드의 역할이 섞이고, 이후 관측 스택과 리소스를
경쟁하게 된다. 반대로 별도의 data 노드를 추가하면 역할은 명확하지만 노드 수와 비용이 증가한다.

## 결정

PoC용 PostgreSQL과 Redis를 **Kubernetes 클러스터의 `beach` Namespace 안에 배치**하고, 두 Pod 모두
`node-role: app` 라벨이 있는 App Worker에서 실행한다.

- PostgreSQL: `Deployment` + `ClusterIP Service` 이름 `postgres`
- Redis: `Deployment` + `ClusterIP Service` 이름 `redis`
- Beach 앱은 각각 `postgres:5432`, `redis:6379`로 접근한다.
- 두 의존성은 서로 다른 App Worker 배치를 선호하는 `preferredDuringSchedulingIgnoredDuringExecution` Pod anti-affinity를 사용한다. 서로 다른 노드 배치를 보장하지 않으며 Node 장애 시 재배치·복구 동작은 미검증이다.
- Control Plane에는 워크로드를 배치하지 않는다.
- `obs-1`은 관측 워크로드 전용으로 유지한다.
- 영속 볼륨은 사용하지 않는다. 클러스터 재생성·리소스 삭제 시 데이터도 사라지는 검증 전용 구성이다.

### 범위 제외

- 운영용 PostgreSQL 고가용성, 백업, PITR
- Redis Sentinel·Cluster 구성
- RDS, ElastiCache, 별도 data 노드
- 장기 데이터 보존과 운영 환경 승격

## 근거

- App Worker에 이미 앱 Pod가 배치되므로 노드 역할을 추가하지 않고 비용을 유지할 수 있다.
- `obs-1`을 비워두면 관측 스택의 자원과 애플리케이션 데이터 계층의 자원 경계를 유지할 수 있다.
- App Worker가 t3.small이므로 의존성에는 낮은 CPU·메모리 requests/limits를 지정해 앱 Pod의 자원 고갈을 줄인다.
- 단명 PoC에서는 데이터 보존보다 클러스터 재생성 절차와 배포 검증이 우선이다.

## 결과

### 긍정적 영향

- 별도 AWS 데이터 서비스를 만들지 않아 월 비용과 destroy 대상이 작다.
- `beach` Namespace만 적용하면 앱과 의존성을 함께 재생성할 수 있다.
- 관측성 노드의 역할이 오염되지 않는다.

### 부정적 영향

- App Worker 자원을 앱과 데이터 계층이 공유한다.
- App Worker 장애 시 해당 노드의 의존성이 함께 중단될 수 있다.
- 영속 볼륨이 없어 데이터가 보존되지 않는다.

## 대안

### 선택지 1: `obs-1`에 배치

- 장점: t3.medium의 여유 자원을 사용할 수 있다.
- 단점: 관측성 노드에 데이터 계층을 섞고 이후 Prometheus/Grafana와 경쟁한다.
- 결론: 역할 경계가 흐려지므로 선택하지 않는다.

### 선택지 2: 별도 data 노드 추가

- 장점: 앱·관측·데이터 역할이 명확하고 자원 격리가 쉽다.
- 단점: EC2·EBS·IPv4 비용과 Terraform 구성이 증가한다.
- 결론: 상시 운영이나 데이터 보존이 필요해질 때 재검토한다.

### 선택지 3: RDS·ElastiCache 사용

- 장점: 관리형 백업과 가용성 기능을 사용할 수 있다.
- 단점: 단명 PoC의 40시간 예산 목표와 맞지 않고 별도 네트워크·비용 관리가 필요하다.
- 결론: 운영 환경 설계 단계에서 별도 ADR로 검토한다.

## 검증 계획

1. PostgreSQL과 Redis Pod가 `node-role=app` 노드에 배치되는지 확인한다.
2. 두 의존성 Pod가 서로 다른 App Worker에 배치되는지 확인한다.
3. Beach Pod가 `postgres:5432`, `redis:6379`로 연결되는지 확인한다.
4. 애플리케이션 rollout과 `/api/beaches` 응답을 확인한다.
5. 검증 후 Kubernetes 리소스와 Terraform 인프라를 삭제한다.

## 롤백 / 재검토 기준

- App Worker에서 OOM 또는 지속적인 DB·Redis 연결 지연이 발생하면 data 노드 추가를 검토한다.
- 데이터 보존, 백업, HA 요구가 생기면 이 결정을 폐기하고 RDS·ElastiCache 또는 별도 data 노드 ADR을 작성한다.
- Prometheus/Grafana가 App Worker 자원을 사용하거나 `obs-1`에 배치될 수밖에 없게 되면 노드 역할을 재설계한다.

## 참고

### 공식 문서 링크

- [Kubernetes nodeSelector](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/)
- [Kubernetes pod anti-affinity](https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#inter-pod-affinity-and-anti-affinity)
- [Kubernetes Service](https://kubernetes.io/docs/concepts/services-networking/service/)

### 관련 문서

- [Kubernetes 실행 환경](./k8s-execution-environment.md)
- [단명 클러스터 비용과 GHCR Secret 운영 절차](../kubernetes-ephemeral-cluster-cost-and-secrets.md)

## 작성일자

2026-10-06
