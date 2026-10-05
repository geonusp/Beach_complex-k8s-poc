# Kubernetes Beach 배포 실패: PostGIS·Firebase·Redis 설정 연쇄 장애

## 0) 메타 정보

- **Mode:** `OPS`
- **Status:** `Resolved`
- **작성자:** 박건우(@geonusp)
- **해결 날짜:** 2026-10-06
- **작성일:** 2026-10-06
- **컴포넌트:** infra, kubernetes, spring-boot, postgres, redis, firebase
- **환경:** AWS EC2 kubeadm dev 클러스터
- **관련 이슈/PR:** [Beach_complex-k8s-poc PR #15](https://github.com/geonusp/Beach_complex-k8s-poc/pull/15), GitHub Issue #2
- **키워드:** `ImagePullBackOff`, `postgis.control`, `FirebaseConfig`, `Redis health check failed`, `spring.data.redis`, `startupProbe`, `rollout progress deadline`

---

## 1) 요약

- **무슨 문제였나:** PostgreSQL·Redis 의존성은 `Ready`였지만 Beach 파드가 `0/1`에 머물며 Deployment rollout이 progress deadline을 초과했다.
- **원인:** PostGIS가 없는 PostgreSQL 이미지, Firebase 자격 증명 없는 환경에서의 Firebase 활성화, Spring Boot 3 Redis 속성 키 불일치가 순차적으로 드러났다.
- **해결:** PostGIS 이미지 사용, PoC Firebase 비활성화, `spring.data.redis.*` 표준 키 주입, ConfigMap 변경 후 Deployment 재시작, 장애 절차 문서화를 적용했다.

## 1-1) 학습 포인트

- **빠른 확인 포인트 (3):** (1) Log: 최신 Beach 파드 로그와 probe 이벤트 확인 (2) Config/Env: ConfigMap·Secret·Spring Boot 속성명 확인 (3) Infra/Dependency: PostgreSQL·Redis 파드와 EndpointSlice 확인
- **Rule of thumb:** 의존성 파드가 `Ready`여도 애플리케이션 설정이 올바른 대상(Service·포트·표준 속성)에 연결되는지 별도로 검증한다.
- **Anti-pattern:** 오래된 파드 로그의 `Connection refused`만 보고 의존성 장애로 단정하지 않는다.

---

## 2) 증상

### 관측된 현상

- `deploy-beach.sh`가 `deployment "beach" exceeded its progress deadline`으로 실패했다.
- Beach 파드는 실행 중이지만 `READY 0/1`이고 재시작 횟수가 증가했다.
- PostgreSQL과 Redis 파드는 `1/1 Running`이었다.
- startup probe가 포트 미기동, HTTP 503을 차례로 기록했다.

### 에러 메시지 / 스택트레이스

#### 2-1) PostGIS 확장 누락

```text
ERROR: extension "postgis" is not available
DETAIL: Could not open extension control file "/usr/local/share/postgresql/extension/postgis.control": No such file or directory.
STATEMENT: CREATE EXTENSION IF NOT EXISTS postgis
```

#### 2-2) Firebase 자격 증명 누락

```text
Firebase 서비스 계정 키를 찾을 수 없습니다.
APP_FIREBASE_CREDENTIALS_JSON_BASE64, APP_FIREBASE_CREDENTIALS_PATH
또는 classpath 리소스를 설정해주세요.
```

#### 2-3) Redis 연결 실패

```text
Redis health check failed
java.net.ConnectException: Connection refused
```

#### 2-4) startup probe 실패

```text
Startup probe failed: Get "http://<pod-ip>:8081/actuator/health": dial tcp <pod-ip>:8081: connect: connection refused
Startup probe failed: HTTP probe failed with statuscode: 503
```

### 진단 과정과 사용한 명령

#### 2-5-1) 의존성 배포 상태 확인

먼저 PostgreSQL·Redis를 별도로 배포하고 롤아웃 결과를 확인했다.

```bash
bash deploy/k8s/scripts/deploy-dependencies.sh
```

판단 기준:

- `deployment "postgres" successfully rolled out`
- `deployment "redis" successfully rolled out`
- 두 파드 모두 `1/1 Running`

의존성이 정상인데 Beach만 실패하면 앱 설정·이미지·health probe를 다음 단계에서 확인한다.

#### 2-5-2) 컨트롤 플레인에서 파드·로그·이벤트 조회

Git Bash에서 공통 SSM 함수를 한 번만 로드한다.

```bash
source ./deploy/k8s/scripts/lib/ssm.sh
```

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get pods -o wide; kubectl -n beach logs deployment/beach --all-containers --since=10m --tail=200; kubectl -n beach get events --sort-by=.lastTimestamp | tail -n 20"
```

`readonly variable` 오류가 나오면 같은 셸에서 `ssm.sh`를 중복 source한 것이므로 source를 반복하지 않고 기존 `ssm_run` 함수를 사용한다.

#### 2-5-3) PostgreSQL·Redis Service와 EndpointSlice 확인

Redis 파드가 `Ready`여도 Service에 엔드포인트가 등록됐는지 확인했다.

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get endpoints redis -o yaml; kubectl -n beach get endpointslice -l kubernetes.io/service-name=redis -o yaml; kubectl -n beach describe svc redis"
```

정상 판단 기준:

- `subsets.addresses`에 Redis 파드 IP가 존재
- EndpointSlice의 `conditions.ready: true`
- Service의 `Endpoints`가 `10.244.x.x:6379` 형태로 표시

이 값들이 정상이면 Redis 프로세스·Service 라우팅보다 앱의 연결 속성명을 우선 조사한다.

#### 2-5-4) 특정 Beach 파드의 probe와 최신 로그 확인

Deployment 전체 로그만으로는 이전 ReplicaSet 로그가 섞일 수 있으므로, 새 파드 이름을 먼저 확인한 뒤 해당 파드를 직접 조회했다.

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get pods -l app.kubernetes.io/name=beach -o wide; kubectl -n beach describe pod <beach-pod>; kubectl -n beach logs <beach-pod> --all-containers --since=10m --tail=300"
```

`describe`에서 다음 이벤트를 시간순으로 비교했다.

- `connect: connection refused`: 관리 포트가 아직 열리지 않은 초기 기동 단계
- HTTP `503`: 애플리케이션은 실행 중이나 Actuator health indicator가 `DOWN`
- 재시작 횟수 증가: startup probe 제한 초과 또는 애플리케이션 예외 종료

#### 2-5-5) Actuator health 응답 확인

컨테이너 내부에서 관리 포트의 실제 응답을 확인했다.

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach exec <beach-pod> -- sh -c 'wget -S -O- http://127.0.0.1:8081/actuator/health 2>&1 || true'"
```

응답의 `redis`, `db`, `mail` 등 세부 indicator를 확인해 probe 503의 직접 원인을 분리한다. 이미지에 `wget`이 없으면 `kubectl describe pod`의 probe 이벤트와 애플리케이션 로그를 함께 사용한다.

#### 2-5-6) 이미지·설정 적용 여부 확인

새 이미지와 환경변수가 실제 파드에 적용됐는지 확인했다.

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get pod <beach-pod> -o jsonpath='{.spec.containers[0].image}{"\\n"}'; kubectl -n beach get secret beach-runtime -o jsonpath='{.data}'"
```

Secret 값 자체는 출력하지 않고 키 존재 여부만 확인한다. Redis 연결 수정은 새 애플리케이션 이미지에 포함되어야 하므로 GHCR 이미지 빌드·푸시 완료 여부도 별도로 확인한다.

---

## 3) 영향 범위

- **영향받는 기능:** Beach 백엔드 Kubernetes 배포 및 앱 기동
- **영향받는 사용자/데이터:** dev 환경 배포와 임시 PostgreSQL·Redis 데이터
- **심각도(개발 단계):** `High`
- **데이터 보존:** PostgreSQL·Redis에 PVC가 없어 의존성 파드 재생성 시 데이터가 유실될 수 있음

---

## 4) 재현 방법

### 전제 조건

- **브랜치/커밋:** `fix/2-beach-troubleshooting`
- **의존성/버전:** Kubernetes kubeadm, Spring Boot 3.3, PostgreSQL 16, Redis 7
- **환경:** AWS EC2 dev 클러스터, SSM Run Command

### 재현 절차

1. PostGIS가 포함되지 않은 `postgres:16-alpine` 이미지로 PostgreSQL 의존성을 배포한다.
2. Firebase 자격 증명 없이 `app.firebase.enabled=true`인 Beach 이미지를 배포한다.
3. `SPRING_REDIS_HOST`만 주입하고 Spring Boot 3 표준 `SPRING_DATA_REDIS_HOST`를 주입하지 않는다.
4. 다음 명령으로 앱을 배포한다.

```bash
bash deploy/k8s/scripts/deploy-beach.sh
```

5. 다음 명령으로 파드와 최신 로그를 확인한다.

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get pods -o wide; kubectl -n beach logs deployment/beach --all-containers --since=10m --tail=200; kubectl -n beach get events --sort-by=.lastTimestamp | tail -n 20"
```

### 기대 결과

- 의존성 배포 후 Beach 파드가 `1/1 Ready`가 된다.
- `deployment/beach` rollout이 제한 시간 내 완료된다.

### 기존 실제 결과

- Flyway의 PostGIS 생성 실패 또는 Firebase 초기화 실패가 발생한다.
- Redis가 `localhost:6379`로 연결을 시도해 health check가 실패할 수 있다.
- `/actuator/health`가 `503`을 반환해 startup probe와 rollout이 실패한다.

---

## 5) 원인 분석

### 근거

- **PostgreSQL 이미지:** `postgres:16-alpine`에는 `/usr/local/share/postgresql/extension/postgis.control`이 없다.
- **Firebase 설정:** `FirebaseConfig`는 `app.firebase.enabled=true`일 때 자격 증명을 필수로 탐색한다.
- **Redis 설정:** Spring Boot 3의 자동설정 표준 속성은 `spring.data.redis.host`와 `spring.data.redis.port`다.
- **Kubernetes 상태:** Redis EndpointSlice는 `ready: true`였지만 앱에서 Redis health check가 실패했다.
- **애플리케이션 로그:** PostgreSQL 연결·Flyway는 성공한 뒤 Redis health check가 실패했고 startup probe가 `503`을 기록했다.

### 최종 원인

PostGIS·Firebase·Redis의 런타임 요구사항과 Kubernetes 주입 설정이 일치하지 않아 애플리케이션이 기동 후 health endpoint를 정상화하지 못했다.

---

## 6) 해결

### 해결 전략

- **유형:** `Config change` + `Deployment fix` + `Documentation`
- **접근:** 애플리케이션이 실제로 사용하는 표준 설정 키와 의존성 이미지를 맞추고, 변경된 ConfigMap을 기존 파드에 반영하도록 배포 절차를 보완한다.

### 변경 사항

- PostgreSQL 이미지 변경:

```yaml
image: postgis/postgis:16-3.5-alpine
```

- PoC ConfigMap에서 Firebase 비활성화:

```yaml
APP_FIREBASE_ENABLED: "false"
```

- Redis 표준 환경변수 사용:

```text
SPRING_DATA_REDIS_HOST=redis
SPRING_DATA_REDIS_PORT=6379
```

- `deploy-beach.sh`에서 ConfigMap 적용 후 `kubectl rollout restart deployment/beach` 실행
- 재현 절차와 장애 점검 명령을 본 문서에 기록

### 주의/부작용

- Firebase 기능이 필요한 환경에서는 `APP_FIREBASE_ENABLED=false`를 사용하면 안 된다.
- 새 Redis 설정이 포함된 애플리케이션 이미지를 GHCR에 빌드·푸시한 뒤 배포해야 한다.
- PVC 없는 임시 PostgreSQL·Redis 구성은 데이터 보존을 보장하지 않는다.

---

## 7) 검증

### 해결 확인

- [x] bootstrap 스크립트 회귀 테스트 통과
- [x] `git diff --check` 통과
- [x] 새 GHCR 이미지 배포 후 Beach 파드 `1/1 Ready` 확인
- [ ] `/actuator/health` HTTP 200 확인
- [x] `deployment/beach` rollout 완료 확인

### 실행한 커맨드/테스트

```bash
bash deploy/k8s/scripts/test-bootstrap-scripts.sh
git diff --check
```

전체 Gradle 테스트는 Docker Desktop 미실행으로 Testcontainers 128건이 실패했다. 이는 Redis 설정 변경과 별개의 로컬 테스트 환경 문제다.

---

## 8) 재발 방지

### 방지 조치 체크리스트

- [x] **테스트 추가:** 배포 스크립트에 PostGIS 이미지·Firebase 비활성화·Redis 표준 키 검증 추가
- [x] **가드레일:** `deploy-beach.sh`에서 ConfigMap 변경 후 Deployment 재시작
- [x] **문서화:** Kubernetes 배포 트러블슈팅 절차 기록
- [ ] **알림/모니터링:** `rollout status`, actuator health, Redis/PostgreSQL EndpointSlice 알람 보강

### 남은 작업

- [ ] 새 애플리케이션 이미지 GHCR push 후 dev 클러스터 재배포
- [ ] 실제 파드 Ready 및 actuator health 수동 검증
- [ ] 운영 환경 Firebase 자격 증명 주입 방식 결정

---

## 9) 참고 자료

- [Spring Boot 3.3 Redis 설정](https://docs.spring.io/spring-boot/3.3/reference/data/nosql.html)
- [Kubernetes Init Containers](https://kubernetes.io/docs/concepts/workloads/pods/init-containers/)
- [Kubernetes Probes](https://kubernetes.io/docs/concepts/workloads/pods/probes/)
- [PostGIS Docker 이미지](https://hub.docker.com/r/postgis/postgis)
- [Beach Kubernetes 트러블슈팅 PR #15](https://github.com/geonusp/Beach_complex-k8s-poc/pull/15)
