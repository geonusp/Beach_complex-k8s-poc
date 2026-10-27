# 노드 접근 방식 — SSH 대신 SSM Session Manager

## 상태

Proposed

## 컨텍스트

기존 관측 서버 모듈(`deploy/observability/terraform/modules/observability_ec2`)은 SSH 접근을 전제로 한다.

```hcl
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id            = aws_security_group.this.id
  referenced_security_group_id = var.app_server_security_group_id
  description                  = "SSH from the application server"
  from_port                    = 22
  ip_protocol                  = "tcp"
  to_port                      = 22
}
```

22번이 운영자 IP가 아니라 **애플리케이션 서버 Security Group에서만** 열려 있다.
즉 관측 서버에 접속하려면 앱 서버를 경유지로 거쳐야 한다. 키페어는 `key_name` 변수로 받지만
`.pem` 파일 자체는 Terraform 관리 범위 밖이다.

이 구조가 실제로 만드는 비용은 두 가지다.

**1. 운영자의 공인 IP가 계속 바뀐다.**
앱 서버에 붙으려면 앱 서버 SG에 현재 IP가 열려 있어야 한다. 가정·사무실 회선은 동적 IP라
수시로 바뀌고, 그때마다 SG 규칙을 고쳐야 한다. 그런데 **앱 서버 SG는 이 저장소가 아니라
백엔드 저장소와 AWS 콘솔에서 관리된다.** 접속 한 번 하려고 다른 저장소의 인프라를 건드리는 일이 반복된다.

**2. 노드의 IP와 호스트키가 재생성마다 바뀐다.**
Kubernetes 노드는 실험 단위로 `destroy` 후 재생성하는 운영 모델을 택했다
([실행 환경 결정](./k8s-execution-environment.md) 참고). 재생성하면 private IP가 달라지고
호스트키도 새로 생긴다. SSH를 쓰면 대상 주소 갱신, `known_hosts` 정리, 키 배포를 매번 해야 한다.

여기에 더해 **접근 대상이 1대에서 4대로 늘어난다.** 이슈 #1의 부트스트랩은
`kubeadm init` → 토큰 발급 → 워커 3대 `join` → 노드 라벨 부여를 순서대로 원격 실행해야 하므로,
위 비용이 그대로 4배가 된다. 이슈 #2 이후의 모든 실험도 같은 경로를 쓴다.

마지막으로 이슈 #1의 완료 기준에 "실제 Secret과 kubeconfig가 저장소에 포함되지 않는다"가 있다.
키페어 `.pem` 파일은 그 위험의 대표 사례다.

## 결정

**SSM Session Manager와 Run Command를 Kubernetes 노드의 유일한 접근 경로로 한다.**

- SSH 22번 인바운드 규칙을 **만들지 않는다.**
- 키페어를 쓰지 않는다. `key_name`을 지정하지 않는다.
- 노드가 공유하는 IAM Role에 관리형 정책 `AmazonSSMManagedInstanceCore`를 부착한다. 현재 Terraform은 GHCR 파라미터 읽기와 SSM 결과 S3 출력 쓰기용 인라인 정책도 함께 부여한다.
- 부트스트랩 스크립트는 대상을 **instance ID로 지정**하고, 그 값은 Terraform output에서 읽는다.
  IP를 하드코딩하지 않는다.
- 네트워크 경로는 **퍼블릭 서브넷 + IGW**를 통한 아웃바운드 443이다. VPC 엔드포인트는 만들지 않는다.

  **경로 검증 완료.** `beach-vpc`의 `public-a`(`10.0.1.0/24`)와 `public-b`(`10.0.2.0/24`)는
  기본 경로 `0.0.0.0/0`이 인터넷 게이트웨이로 향하는 라우트 테이블에 연결되어 있다.
  두 서브넷은 `MapPublicIpOnLaunch`가 `false`이므로 Terraform에서
  `associate_public_ip_address = true`를 명시해야 한다. 기존 관측 서버 모듈도 같은 방식을 쓴다.

  **프라이빗 서브넷은 현재 사용할 수 없다.** `private-a`·`private-b`의 라우트 테이블에는
  VPC 로컬 경로만 있고 **NAT Gateway가 존재하지 않는다.** 노드를 프라이빗에 두려면
  NAT Gateway(약 `$32.85/월` + 처리량)나 VPC 엔드포인트 3개를 새로 만들어야 한다.
- 로컬에서 `kubectl`을 쓸 때는 Control Plane의 6443을 운영자 CIDR로 여는 방식과
  SSM 포트 포워딩 중 선택할 수 있게 하고, 기본값은 포트 포워딩으로 둔다.

### 범위 제외

- **기존 관측 서버 모듈의 SSH 방식은 바꾸지 않는다.** 동작 중인 스택이고, 이 결정은 새로 만드는
  Kubernetes 노드에만 적용한다.
- 세션 로그를 S3 또는 CloudWatch Logs에 보관하는 설정
- 프라이빗 서브넷 전환과 그에 따른 VPC 엔드포인트 구성
- 백엔드 애플리케이션 서버의 접근 방식

## 근거

- **대상 지정이 IP가 아니라 instance ID다.** 재생성해도 스크립트를 고칠 필요가 없다.
  재현성이 완료 기준인 이 프로젝트에서 가장 큰 이득이다.
- **SSM 접속을 위한 인바운드 규칙이 필요 없다.** 노드 간 통신용 SG self 규칙과 선택적 API 접근 규칙은 별도로 존재한다. 노드가 아웃바운드 443으로 SSM 엔드포인트에 연결하고
  세션은 그 위에서 역방향으로 열린다. 22번을 어디에도 노출하지 않는다.
- **키페어 수명주기 문제가 사라진다.** 배포·보관·폐기할 `.pem` 파일이 없다.
- **앱 서버 SG 의존이 사라진다.** 기존 모듈은 `app_server_security_group_id`를 필수 입력으로 받는데,
  Kubernetes 노드 모듈에서는 이 입력을 제거하기로 했다. SSH를 열려면 그 의존이 되살아난다.
- **접속 기록이 CloudTrail에 남는다.** SSH는 노드 내부 로그에만 남는다.
- IAM Role과 instance profile은 기존 모듈에도 이미 있다. 다만 정책이 하나도 붙지 않은 빈 Role이므로,
  관리형 정책 한 줄을 추가하는 것 외에 새로 도입하는 구성요소가 없다.

## 결과

### 긍정적 영향

- 클러스터를 몇 번을 재생성해도 부트스트랩 스크립트가 그대로 동작한다.
- Security Group이 단순해진다. 외부 인바운드는 Control Plane 6443(선택) 하나뿐이다.
- 저장소에 들어갈 수 있는 비밀 자재가 하나 줄어든다.
- 노드 4대에 같은 명령을 일괄 실행하기 쉽다.

### 부정적 영향

- **아웃바운드 443 경로가 반드시 필요하다.** 현재 VPC에는 NAT Gateway가 없으므로
  프라이빗 서브넷으로 옮기려면 NAT Gateway나 VPC 엔드포인트 3개(`ssm`, `ssmmessages`, `ec2messages`)를
  새로 만들어야 하고 둘 다 시간당 과금된다. 퍼블릭 서브넷 배치가 사실상 유일한 저비용 경로다.
- Session Manager 대화형 접속·포트 포워딩에는 로컬 `session-manager-plugin`이 필요하다. Run Command만 사용하는 부트스트랩·실험 실행은 이 플러그인을 요구하지 않는다.
- **Run Command 출력이 잘린다.** 기본 한도가 있어 `kubeadm init`처럼 긴 출력은
  S3 또는 CloudWatch Logs로 내보내야 할 수 있다.
- SSM Agent에 의존한다. Ubuntu Server 24.04 AMI에는 기본 포함되지만 부팅 후 확인이 필요하다.
- **비상 경로가 없다.** SSM Agent가 죽거나 IAM 설정이 잘못되면 접속할 방법이 사라진다.
  이때는 EC2 Serial Console을 쓰거나 인스턴스를 교체한다. cloud-init으로 설치가 자동화되어 있으므로
  교체 비용은 낮다.

## 대안

### 선택지 1: SSM Session Manager / Run Command

- 장점: instance ID 기반이라 재생성에 강하다. 인바운드 0. 키 관리 없음. 감사 기록.
- 단점: 아웃바운드 443 의존, 플러그인 설치, 출력 크기 제한, 비상 경로 부재.
- 결론: **채택**

### 선택지 2: SSH + 운영자 IP 직접 허용

- 장점: 익숙하고 도구 설치가 필요 없다. 출력 크기 제한이 없다.
- 단점: 운영자 공인 IP가 바뀔 때마다 SG를 고쳐야 한다. 노드 재생성마다 대상 주소와
  호스트키가 달라진다. 키페어를 관리해야 한다.
- 결론: **거부.** 다만 SSM이 막혔을 때의 비상 수단으로는 유효하다

### 선택지 3: SSH + 앱 서버 경유 (기존 관측 서버 방식)

- 장점: 22번을 외부에 노출하지 않는다. 기존 방식과 일관된다.
- 단점: 선택지 2의 단점에 더해, 접속하려면 **다른 저장소에서 관리되는 앱 서버 SG**를 고쳐야 한다.
  Kubernetes 노드 모듈에서 제거하기로 한 앱 서버 의존이 되살아난다.
- 결론: **거부**

### 선택지 4: VPN 또는 Tailscale 같은 오버레이 네트워크

- 장점: IP 변동 문제가 근본적으로 사라지고 노드 간 접근도 편해진다.
- 단점: 관리할 인프라와 계정이 하나 더 생긴다. PoC 범위에서 얻는 것보다 부담이 크다.
- 결론: **거부**

## 검증 계획

1. 노드 4대 모두 `aws ssm start-session --target <instance-id>`로 셸에 접속된다.
2. 각 노드 Security Group에 **인바운드 22번 규칙이 존재하지 않는다.**
3. 부트스트랩 스크립트가 `aws ssm send-command`로 `kubeadm init`과 `join`을 실행하고 결과를 회수한다.
4. `terraform destroy` 후 재생성했을 때, 스크립트 수정 없이 동일하게 동작한다.
   (instance ID는 Terraform output에서 읽으므로 변경분이 자동 반영된다)
5. 관리형 `AmazonSSMManagedInstanceCore`와 GHCR 파라미터·S3 출력용 인라인 정책의 범위가 Terraform 구성과 일치하는지 확인한다.

## 롤백 / 재검토 기준

**되돌리기 비용은 낮다.** SSH로 복귀하려면 Security Group 인바운드 규칙 하나와
`key_name` 입력을 추가하면 된다. 클러스터를 다시 만들 필요가 없다.

다음 조건에서 재검토한다.

- 노드를 프라이빗 서브넷으로 옮겨야 해서 VPC 엔드포인트 3개의 시간당 비용이 발생한다.
- Run Command 출력 크기 제한 때문에 부트스트랩 디버깅이 반복적으로 막힌다.
- SSM Agent 문제로 접근 불능 상황이 반복된다.
- 운영자가 여러 명이 되어 권한 분리가 필요해진다. 이 경우 SSM은 오히려 장점이 커지므로
  세션 로그 보관과 IAM 정책 분리를 추가로 설계한다.

## 참고

### 공식 문서 링크

- Session Manager: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html
- Session Manager 사전 요구사항: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-prerequisites.html
- SSM용 VPC 엔드포인트 구성: https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-create-vpc.html
- Run Command: https://docs.aws.amazon.com/systems-manager/latest/userguide/execute-remote-commands.html
- AmazonSSMManagedInstanceCore 정책: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html
- EC2 Serial Console: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-serial-console.html

### 관련 이슈 / PR

- 이슈 #1 작업 5 — 노드 역할에 필요한 Security Group, IAM, EBS 설정을 구성한다
- 이슈 #1 작업 7 — kubeadm init과 kubeadm join으로 클러스터를 구성한다

### 관련 문서

- [Kubernetes 실행 환경 — AWS kubeadm 4노드](./k8s-execution-environment.md) — 재생성 운영 모델의 근거
- `../../tempdocs/issue-1/pr-2-node-infrastructure.md` (로컬 참고·Git 미포함) — SG·IAM 구현
- `../../tempdocs/issue-1/pr-4-kubeadm-cilium.md` (로컬 참고·Git 미포함) — Run Command 기반 부트스트랩
- `deploy/observability/terraform/modules/observability_ec2/main.tf` — 기존 SSH 방식

## 작성일자

2026-09-20
