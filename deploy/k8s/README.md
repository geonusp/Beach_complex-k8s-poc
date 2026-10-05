# Kubernetes 클러스터 생성 및 삭제 절차

AWS EC2 4노드 kubeadm 클러스터를 만들고 내리는 운영 문서다.
**상시 운영하지 않는다.** 검증할 때만 만들고 끝나면 완전히 삭제한다.

| 노드 | 역할 | 인스턴스 | 서브넷 |
| --- | --- | --- | --- |
| `cp-1` | control-plane | t3.medium | public-a (us-east-1a) |
| `app-1` | app | t3.small | public-a (us-east-1a) |
| `app-2` | app | t3.small | public-b (us-east-1b) |
| `obs-1` | observability | t3.medium | public-b (us-east-1b) |

---

## 1. 사전 준비

### 필요한 도구

| 도구 | 용도 | 확인 |
| --- | --- | --- |
| Terraform 1.5 이상 | 인프라 생성 | `terraform version` |
| AWS CLI v2 | SSM 명령 실행 | `aws sts get-caller-identity` |
| `base64` | 원격 스크립트 전송 | coreutils에 포함 |
| `python3` | 노드 목록 파싱 | `python3 --version` |

`kubectl`과 `helm`은 로컬에 없어도 된다. 모든 클러스터 조작은 SSM으로 control plane에서 실행한다.

### Windows Git Bash 사용 시

PowerShell에서 `bash`를 호출하면 WSL Bash가 실행될 수 있다. Windows에 설치된 AWS CLI·Terraform을
사용하려면 **Git Bash**에서 실행한다. `python3`가 Microsoft Store 실행 별칭으로 잡히는 경우에는
다음처럼 Python Launcher를 연결한다.

```bash
export AWS_PAGER=""
python3(){ py -3 "$@"; }
export -f python3
```

`start-session`은 별도의 Session Manager Plugin이 필요하지만, bootstrap과 검증은 SSM Run Command로
수행하므로 대화형 세션 없이도 진행할 수 있다.

### terraform.tfvars 작성

```bash
cd deploy/k8s/terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
```

채워야 하는 값이다. `terraform.tfvars`는 `.gitignore` 대상이므로 커밋되지 않는다.

| 변수 | 값 | 확인 방법 |
| --- | --- | --- |
| `vpc_id` | `beach-vpc` | `aws ec2 describe-vpcs --query "Vpcs[?CidrBlock=='10.0.0.0/16'].VpcId"` |
| `ami_id` | Ubuntu 24.04 x86_64 | 아래 명령 |
| `nodes[].subnet_id` | public-a, public-b | `aws ec2 describe-subnets --query "Subnets[?MapPublicIpOnLaunch==\`false\`].[SubnetId,CidrBlock,AvailabilityZone]" --output table` |
| `kubernetes_version` | `v1.36` | 고정값. 아래 "버전 고정" 참고 |
| `operator_cidr` | `null` | 기본값 그대로 둔다 |

```bash
aws ssm get-parameters --region us-east-1 \
  --names /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query "Parameters[0].Value" --output text
```

> **프라이빗 서브넷을 쓰면 안 된다.** `private-a`·`private-b`에는 NAT Gateway가 없어
> 패키지 설치와 SSM 접속이 모두 막힌다.

---

## 2. 생성

### 2-0. 원클릭 생성 및 배포

Terraform 인프라 생성부터 kubeadm·Cilium·GHCR 인증·PostgreSQL·Redis·Beach 배포까지
의존성 순서대로 실행하려면 저장소 루트에서 다음 스크립트를 사용한다.

```bash
bash deploy/k8s/scripts/provision-and-deploy.sh
```

이 스크립트는 다음 단계를 순차 실행한다.

1. `terraform apply -auto-approve`
2. `bootstrap-cluster.sh`
3. `sync-ghcr-secret.sh`
4. `deploy-dependencies.sh`
5. `deploy-beach.sh`

단계별 동작을 직접 확인해야 하거나 중간 단계만 재실행할 때는 아래 수동 절차를 사용한다.

### 2-1. 인프라

```bash
cd deploy/k8s/terraform/environments/dev
terraform init
terraform plan      # 10 to add, 0 to change, 0 to destroy 를 확인한다
terraform apply
```

`apply`가 끝나면 **여기서부터 과금이 시작된다.**

### 2-2. cloud-init 완료 대기

EC2가 `running`이 되어도 containerd와 kubeadm 설치는 아직 진행 중이다. 노드마다 확인한다.

```bash
aws ssm start-session --target <instance-id>
sudo cloud-init status --wait     # status: done 을 기다린다
```

`status: error`면 `/var/log/cloud-init-output.log`를 본다.

### 2-3. 클러스터 부트스트랩

```bash
cd ../../../../..          # 저장소 루트
bash deploy/k8s/scripts/bootstrap-cluster.sh
```

네 단계를 순서대로 실행한다. 각 단계는 **멱등**이라 중간에 실패하면 같은 명령을 다시 돌리면 된다.

| 단계 | 스크립트 | 하는 일 |
| --- | --- | --- |
| 1 | `init-control-plane.sh` | `kubeadm init` |
| 2 | `join-workers.sh` | 토큰 발급 후 워커 3대 join |
| 3 | `install-cilium.sh` | Helm으로 Cilium 설치 |
| 4 | `label-nodes.sh` | 노드 역할 라벨 부여 |

개별 실행도 가능하다.

```bash
bash deploy/k8s/scripts/join-workers.sh     # join만 다시
bash deploy/k8s/scripts/label-nodes.sh      # 라벨만 다시
```

실패한 단계만 다시 실행할 수 있다. `bootstrap-cluster.sh`를 다시 실행하면 이미 초기화된
Control Plane과 join 완료 Worker는 건너뛰고 Cilium·라벨·최종 검증을 재수행한다.

---

## 3. 확인

```bash
aws ssm start-session --target "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)"
sudo -i
kubectl get nodes -o wide
```

기대 결과다.

```
NAME                   STATUS   ROLES            AGE   VERSION
beach-complex-app-1    Ready    app              ...   v1.36.x
beach-complex-app-2    Ready    app              ...   v1.36.x
beach-complex-cp-1     Ready    control-plane    ...   v1.36.x
beach-complex-obs-1    Ready    observability    ...   v1.36.x
```

**4대 전부 Ready, ROLES가 네 역할로 구분**되면 이슈 #1의 완료 기준을 만족한다.

추가 확인이다.

```bash
kubectl -n kube-system get pods -l k8s-app=cilium      # 4/4 Running
kubectl -n kube-system get pods -l k8s-app=kube-dns    # Running (CNI 전에는 Pending)
kubectl get nodes -L node-role                          # nodeSelector용 라벨 확인
```

### 실제 검증 결과

2026-10-05 `us-east-1`에서 다음 결과를 확인했다.

- Kubernetes 노드 4개 모두 `Ready`
- Control Plane 1개, App Worker 2개, Observability Worker 1개
- Kubernetes `v1.36.5`
- Cilium `1.20.2`, DaemonSet `4/4 Running`
- CoreDNS `2/2 Running`
- `bootstrap-cluster.sh` 최종 로그: `bootstrap completed`

### Beach 애플리케이션 배포 검증 (이슈 #2)

클러스터가 준비된 뒤 GHCR 이미지 pull 인증과 런타임 Secret을 Control Plane에서 준비하고,
Kustomize 매니페스트를 적용한다.

```bash
kubectl apply -f deploy/k8s/app/namespace.yaml
kubectl apply -f deploy/k8s/app/secret.yaml
kubectl -n beach create secret docker-registry ghcr-pull --docker-server=ghcr.io --docker-username="$GHCR_USERNAME" --docker-password="$GHCR_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
kustomize edit set image beach-backend=ghcr.io/geonusp/beach_complex-k8s-poc-backend:<IMAGE_SHA>
kubectl apply -k deploy/k8s/app
BEACH_URL=https://beach.example.com BEACH_EXTERNAL_PATH=/api/beaches bash deploy/k8s/scripts/verify-beach.sh
```

검증 기준:

- Beach Pod 2개가 `Ready`다.
- 두 Pod가 서로 다른 `node-role=app` Worker에 배치된다.
- Service endpoint가 Ready Pod 2개를 가리킨다.
- `Ingress`가 `nginx` IngressClass로 생성된다.
- `BEACH_URL`을 지정하면 외부 `/api/beaches` 요청도 성공한다. `/actuator/health`는 management 포트의 내부 probe로만 확인한다.

검증 후에는 반드시 `terraform destroy`를 실행한다.

### 로컬에서 kubectl 쓰기 (선택)

`operator_cidr`가 `null`이라 6443이 외부에 열려 있지 않다. SSM 포트 포워딩을 쓴다.
이 방식은 Windows에 Session Manager Plugin이 설치되어 있어야 한다. 설치되어 있지 않으면
Control Plane 내부 검증만 사용하거나 SSM Run Command를 사용한다.

```bash
aws ssm start-session \
  --target "$(terraform -chdir=deploy/k8s/terraform/environments/dev output -raw control_plane_instance_id)" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}'
```

control plane의 `/etc/kubernetes/admin.conf`를 받아 `server:`를 `https://127.0.0.1:6443`으로 바꿔 쓴다.
**kubeconfig는 저장소에 두지 않는다.** `~/.kube/` 아래에 보관한다.

---

## 4. 문제 해결

증상별로 먼저 볼 곳이다.

| 증상 | 원인 후보 | 확인 |
| --- | --- | --- |
| 노드가 전부 `NotReady` | **CNI 미설치** | `kubectl -n kube-system get ds cilium` |
| `kubectl`이 안 붙음 | kubeconfig 없음 | control plane에서 `sudo -i` 후 실행 |
| SSM 접속 안 됨 | 퍼블릭 IP 미할당, IAM | `aws ec2 describe-instances`에서 PublicIpAddress 확인 |
| `cloud-init status`가 error | 패키지 설치 실패 | `/var/log/cloud-init-output.log` |
| `kubeadm init` 실패 | **containerd cgroup driver** | `containerd config dump \| grep -i SystemdCgroup` → `true` |
| Pod는 뜨는데 통신이 간헐 실패 | **Pod CIDR 충돌** | `kubectl get pod -o wide`의 IP가 `10.244.x.x`인지 |
| `kubeadm join` 실패 | 토큰 만료(24시간) | `join-workers.sh`를 다시 실행하면 새로 발급한다 |
| kubelet이 재시작 반복 | **`kubeadm init` 전이면 정상** | init 이후에도 그러면 `journalctl -u kubelet` |

### 자주 헷갈리는 두 가지

**kubelet crashloop는 init 전에는 정상이다.** 설정 파일 `/var/lib/kubelet/config.yaml`을 `kubeadm init`이 만들기 때문이다. 부트스트랩 전에 `systemctl status kubelet`이 `activating`이나 `failed`여도 문제가 아니다.

**Pod CIDR은 `10.244.0.0/16`이어야 한다.** Cilium 기본값 `10.0.0.0/8`은 `beach-vpc`(`10.0.0.0/16`)를 통째로 포함한다. `kubeadm init`의 `--pod-network-cidr`과 `deploy/k8s/cilium/values.yaml`의 `clusterPoolIPv4PodCIDRList`가 **같은 값**이어야 한다.

---

## 5. 삭제

원클릭 생성 스크립트의 삭제 경로는 Terraform 확인 프롬프트를 유지한다.

```bash
cd ../../..          # 저장소 루트
bash deploy/k8s/scripts/provision-and-deploy.sh --destroy
```

수동으로 삭제하려면 아래 명령을 사용한다.

```bash
cd deploy/k8s/terraform/environments/dev
terraform destroy
```

**삭제 전 확인할 것**이다.

- `LoadBalancer` 타입 Service를 만든 적이 있으면 AWS가 생성한 ELB가 남는다. `kubectl delete svc`로 먼저 지운다.
- `terraform destroy`는 EBS까지 지운다. **EC2 `stop`은 EBS 요금이 계속 나오므로 절감 수단이 아니다.**

삭제 후 남은 리소스가 없는지 확인한다.

```bash
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Component,Values=kubernetes" "Name=instance-state-name,Values=running,stopped" \
  --query "Reservations[].Instances[].InstanceId" --output text
```

---

## 6. 비용

`us-east-1` 기준 시간당 EC2는 `t3.medium × 2 + t3.small × 2 = $0.1248`이다.
퍼블릭 IPv4 4개와 gp3 120 GiB가 더해진다.

| 실행 시간 | 대략 비용 |
| --- | ---: |
| 40시간 (권장 사용량) | 약 `$6` |
| 한 달 상시 | 약 `$172` |

**비용 위험은 단가가 아니라 삭제 누락에 있다.** 검증이 끝나면 바로 `destroy` 한다.
실험 중에는 기존 앱 EC2와 관측 EC2를 포함해 **총 6대**가 동시에 떠 있다.

---

## 7. 한계

| 한계 | 내용 | 영향 |
| --- | --- | --- |
| **단일 Control Plane** | etcd가 한 대에만 있다. CP 노드가 죽으면 클러스터 전체가 정지하고 복구 수단이 없다. etcd 스냅샷도 받지 않는다 | 장애 복구 실험은 App Worker와 Pod로 한정한다 |
| **로컬 Terraform state** | backend 블록이 없어 state가 작업자 PC에만 있다. 유실되면 리소스가 고아가 된다 | `Component=kubernetes` 태그로 수동 정리 가능 |
| **join 토큰 24시간 만료** | 재생성 시 항상 새로 발급해야 한다 | 스크립트가 매번 발급하므로 수동 개입은 없다 |
| **T 계열 CPU 크레딧** | 부하 테스트 중 크레딧이 소진되면 성능이 떨어져 측정이 왜곡된다 | 이슈 #4에서 `unlimited` 또는 m 계열 전환 검토 |
| **데이터 볼륨 없음** | etcd 데이터를 보존하지 않는다 | 의도된 설계다. 재생성 시 이전 클러스터 상태와 충돌하지 않는다 |

## 버전 고정

| 구성요소 | 버전 | 근거 |
| --- | --- | --- |
| Kubernetes | `v1.36` | Cilium v1.20.2가 e2e 테스트하는 최신 버전이다. stable은 v1.37이지만 Cilium 호환성 목록에 없다 |
| Cilium | `1.20.2` | `install-cilium.sh`의 `CILIUM_VERSION`으로 변경 가능 |

버전을 올릴 때는 [Cilium 시스템 요구사항](https://docs.cilium.io/en/stable/operations/system_requirements/)의
Kubernetes 호환성 표를 먼저 확인한다.

## 관련 문서

- [실행 환경 결정](../../docs/adr/k8s-execution-environment.md) — AWS 4노드를 택한 근거와 운영 모델
- [CNI 선택](../../docs/adr/cilium-cni.md) — Cilium 채택과 Pod CIDR 확정
- [노드 접근 방식](../../docs/adr/node-access-ssm.md) — SSH 대신 SSM을 쓰는 이유
