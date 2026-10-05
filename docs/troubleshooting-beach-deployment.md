# Beach Kubernetes 배포 트러블슈팅

이 문서는 단명 kubeadm 클러스터에서 Beach 배포가 `rollout status` 제한 시간 안에 완료되지 않을 때의 점검 순서와 해결 방법을 정리한다.

## 1. 기본 확인

의존성(PostgreSQL·Redis)을 먼저 배포한 뒤 Beach를 배포한다.

```bash
bash deploy/k8s/scripts/deploy-dependencies.sh
```

```bash
bash deploy/k8s/scripts/deploy-beach.sh
```

`deploy-beach.sh`는 기본 180초 동안 `deployment/beach`의 롤아웃을 기다린다. 필요하면 실행 시점에만 제한 시간을 늘릴 수 있다.

```bash
BEACH_DEPLOY_TIMEOUT_SECONDS=300 bash deploy/k8s/scripts/deploy-beach.sh
```

## 2. 파드 상태와 최신 로그 확인

Git Bash에서 `ssm.sh`는 같은 셸에 한 번만 source한다.

```bash
source ./deploy/k8s/scripts/lib/ssm.sh
```

```bash
ssm_run "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get pods -o wide; kubectl -n beach logs deployment/beach --all-containers --since=10m --tail=200; kubectl -n beach get events --sort-by=.lastTimestamp | tail -n 20"
```

`ssm.sh`를 같은 셸에서 두 번 source하면 `readonly variable` 오류가 발생할 수 있다. 그런 경우 source를 반복하지 말고 이미 정의된 `ssm_run`을 사용한다.

## 3. PostgreSQL PostGIS 오류

### 증상

```text
extension "postgis" is not available
Could not open extension control file .../postgis.control
```

### 원인

기본 `postgres:16-alpine` 이미지에는 PostGIS 확장이 포함되어 있지 않다. Flyway가 `CREATE EXTENSION postgis`를 수행하므로 앱 기동이 실패한다.

### 해결

`deploy/k8s/dependencies/postgres.yaml`에서 다음 이미지를 사용한다.

```yaml
image: postgis/postgis:16-3.5-alpine
```

변경 후 의존성을 먼저 재배포한다.

```bash
bash deploy/k8s/scripts/deploy-dependencies.sh
```

PostgreSQL 배포가 `1/1 Running`이 된 뒤 Beach를 재배포한다.

## 4. Firebase 자격 증명 누락

### 증상

```text
Firebase 서비스 계정 키를 찾을 수 없습니다.
APP_FIREBASE_CREDENTIALS_JSON_BASE64, APP_FIREBASE_CREDENTIALS_PATH
또는 classpath 리소스를 설정해주세요.
```

### 원인

PoC 배포에는 Firebase 서비스 계정 Secret을 주입하지 않는데 애플리케이션 기본값은 `app.firebase.enabled=true`이다.

### 해결

Firebase를 사용하지 않는 PoC 환경에서는 `deploy/k8s/app/configmap.yaml`에 다음을 설정한다.

```yaml
APP_FIREBASE_ENABLED: "false"
```

ConfigMap만 변경하면 기존 파드에는 자동 반영되지 않는다. `deploy-beach.sh`는 ConfigMap 적용 후 `kubectl rollout restart deployment/beach`를 수행하므로 스크립트를 다시 실행한다.

## 5. GHCR 이미지 오류

### `NotFound` 또는 `ImagePullBackOff`

```text
failed to resolve image ...: not found
```

GitHub Actions의 이미지 빌드·푸시가 완료되었는지 확인하고, Kubernetes 이미지 경로가 워크플로와 동일한지 확인한다.

```text
ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest
```

### `401 Unauthorized`

Private GHCR 패키지는 `ghcr-pull` Secret이 필요하다. 토큰은 Git에 저장하지 않고 AWS SSM SecureString에 저장한다.

```bash
bash deploy/k8s/scripts/sync-ghcr-secret.sh
```

## 6. Redis `Connection refused`

### 증상

```text
Redis health check failed
java.net.ConnectException: Connection refused
```

Redis 파드와 Service가 `Ready`인데도 애플리케이션에서 `localhost:6379` 연결을 시도하면 이 오류가 발생할 수 있다.

### 원인

Spring Boot 3의 Redis 자동설정 표준 속성은 `spring.data.redis.host`와 `spring.data.redis.port`다. `spring.redis.*`만 설정하면 자동설정이 기본값인 `localhost:6379`를 사용할 수 있다.

### 해결

애플리케이션 설정과 Kubernetes 런타임 Secret·ConfigMap에 다음 키를 사용한다.

```text
SPRING_DATA_REDIS_HOST=redis
SPRING_DATA_REDIS_PORT=6379
```

설정 변경은 컨테이너 이미지에 포함되므로 새 이미지를 빌드·푸시한 뒤 `deploy-beach.sh`를 실행한다.

## 7. 재배포 전 체크리스트

- `deploy-dependencies.sh`가 PostgreSQL·Redis 롤아웃을 통과했는가
- PostgreSQL 이미지가 `postgis/postgis:16-3.5-alpine`인가
- Beach ConfigMap에 `APP_FIREBASE_ENABLED: "false"`가 있는가
- GHCR 이미지가 실제로 존재하고 `ghcr-pull` Secret이 있는가
- Spring Boot 3 Redis 키가 `SPRING_DATA_REDIS_*`로 주입되는가
- 최신 파드 로그를 기준으로 판단했는가
- 실패한 이전 파드의 오래된 로그와 현재 파드 로그를 혼동하지 않았는가

## 8. 데이터 보존 주의

현재 PostgreSQL과 Redis는 PVC 없이 실행되는 임시 구성이다. `terraform destroy` 또는 의존성 파드 재생성 시 데이터가 사라질 수 있으므로, 운영 데이터에는 사용하지 않는다.
