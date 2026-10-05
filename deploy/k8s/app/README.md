# Beach 애플리케이션 Kubernetes 리소스

이 디렉터리는 이슈 #2의 Beach 애플리케이션 기본 리소스를 관리한다.

## 적용

```bash
kubectl apply -k deploy/k8s/app
```

`secret.example.yaml`을 복사해 실제 Secret을 만든 뒤 적용한다. 실제 Secret 파일은 저장소에 넣지 않는다.

```bash
kubectl apply -f deploy/k8s/app/secret.yaml
kubectl apply -k deploy/k8s/app
```

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
