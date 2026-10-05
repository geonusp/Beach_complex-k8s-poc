# Beach 애플리케이션 Kubernetes 리소스

이 디렉터리는 이슈 #2의 Beach 애플리케이션 기본 리소스를 관리한다.

## 적용

```bash
kubectl apply -k deploy/k8s/app
```

Namespace를 먼저 만든 뒤 runtime Secret과 private GHCR pull Secret을 만들고 애플리케이션을 적용한다.
실제 Secret 파일과 토큰은 저장소에 넣지 않는다.

```bash
kubectl apply -f deploy/k8s/app/namespace.yaml
kubectl apply -f deploy/k8s/app/secret.yaml
kubectl -n beach create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username="$GHCR_USERNAME" \
  --docker-password="$GHCR_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k deploy/k8s/app
```

GHCR 패키지는 기본 private으로 취급한다. public 패키지를 선택하더라도 `ghcr-pull` Secret을
생성하는 절차를 유지하면 공개 범위 변경이 Deployment 매니페스트에 영향을 주지 않는다.

배포할 이미지 태그를 SHA로 고정하려면 적용 전에 Kustomize image를 변경한다.

```bash
kustomize edit set image beach-backend=ghcr.io/geonusp/beach_complex-k8s-poc-backend:<IMAGE_SHA>
kubectl apply -k deploy/k8s/app
```

Control Plane에서 기본 검증을 실행한다.

```bash
bash deploy/k8s/scripts/verify-beach.sh
```

## 외부 접근

Ingress는 `nginx` IngressClass를 사용한다. 클러스터에 Ingress Controller가 먼저 설치되어 있어야 한다.
PoC에서는 ingress-nginx를 선택하고, AWS Load Balancer Controller와 공인 DNS 구성은 별도 운영 작업으로 둔다.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort
```

외부 DNS를 연결하기 전에는 `kubectl port-forward` 또는 SSM 포트 포워딩으로 Ingress Controller를 검증한다.
외부 검증 경로는 management 포트의 `/actuator/health`가 아니라 애플리케이션 공개 API인
`/api/beaches`를 사용한다. management 포트는 Pod probe와 내부 검증용으로만 사용한다.
