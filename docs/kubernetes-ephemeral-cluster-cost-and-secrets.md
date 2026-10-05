# 단명 Kubernetes 클러스터 비용 절감과 GHCR 인증 복구

## 목적

이 프로젝트의 AWS Kubernetes 클러스터는 상시 서비스가 아니라 검증이 필요할 때만 생성한다.
월 실행 시간을 40시간 이하로 제한하고, 검증이 끝나면 Terraform으로 인프라를 완전히 삭제한다.

이 운영 방식에서는 클러스터를 삭제할 때 Kubernetes Secret도 함께 사라진다. 따라서 private GHCR
이미지를 계속 사용하려면 새 클러스터가 생성될 때마다 `ghcr-pull` Secret을 자동으로 복구해야 한다.

## 비용 운영 원칙

1. 대부분의 개발·매니페스트 검증은 로컬 kind에서 수행한다.
2. AWS에서는 실제 EC2 네트워크, kubeadm, Cilium, 노드 배치만 짧게 검증한다.
3. 검증이 끝나면 `terraform destroy`로 EC2와 EBS를 함께 삭제한다.
4. `terraform stop`만 사용하면 EBS와 일부 리소스 비용이 남을 수 있으므로 최대 절감 목적에는 destroy가 우선이다.
5. 실행 중인 리소스와 미삭제 리소스를 AWS 콘솔에서 확인한다.

예시로 현재 4노드 구성에서 40시간 실행하면 EC2·IPv4·gp3 비용은 대략 수 달러 수준이지만,
상시 실행하면 월 비용이 누적된다. 실제 단가는 리전과 시점에 따라 달라지므로 배포 전 AWS 요금 페이지에서 확인한다.

## Secret 수명 주기

```text
GitHub에서 PAT 최초 발급
  ↓ 1회
AWS SSM Parameter Store SecureString에 저장
  ↓ terraform apply
Control Plane IAM 역할에 해당 파라미터 GetParameter 권한 부여
  ↓ 클러스터 재생성
sync-ghcr-secret.sh가 SSM 값을 읽고 ghcr-pull Secret 재생성
  ↓
private GHCR 이미지 pull 및 애플리케이션 배포
```

중요한 점은 클러스터가 GitHub에서 PAT를 새로 발급하는 것이 아니라, 운영자가 사전에 SSM에 저장한
PAT를 재사용한다는 것이다. PAT 값은 Git, Terraform 코드, Terraform 변수 파일에 넣지 않는다.

## 최초 1회 준비

GitHub에서 `write:packages` 권한이 있는 PAT를 발급한 뒤 AWS SSM에 `SecureString`으로 저장한다.
토큰 값은 셸 히스토리와 CI 로그에 남지 않도록 안전한 입력 방식을 사용한다.

```bash
aws ssm put-parameter \
  --name /beach/dev/ghcr/token \
  --type SecureString \
  --value "$GITHUB_PAT"
```

Terraform 변수의 기본 경로는 `/beach/dev/ghcr/token`이다. 다른 경로를 사용하면
`ghcr_token_parameter_name`을 같은 값으로 설정한다.

## 클러스터 재생성 절차

```bash
terraform -chdir=deploy/k8s/terraform/environments/dev apply

export GHCR_USERNAME=geonusp
export GHCR_TOKEN_PARAMETER_NAME=/beach/dev/ghcr/token
bash deploy/k8s/scripts/bootstrap-cluster.sh
bash deploy/k8s/scripts/sync-ghcr-secret.sh
```

그 다음 Namespace, runtime Secret, Kustomize 애플리케이션을 적용한다.
`sync-ghcr-secret.sh`는 Namespace가 없으면 생성하고, 이미 Secret이 있어도 `kubectl apply`로 갱신하므로
재실행할 수 있다.

검증이 끝나면 다음 순서로 비용을 차단한다.

```bash
terraform -chdir=deploy/k8s/terraform/environments/dev destroy
```

## 보안과 권한 범위

- PAT는 SSM `SecureString`에만 저장한다.
- EC2 노드 IAM 역할에는 지정한 SSM 파라미터의 `ssm:GetParameter`만 부여한다.
- 스크립트는 PAT를 SSM Run Command payload에 삽입하지 않는다.
- `sync-ghcr-secret.sh` 로그에는 PAT를 출력하지 않는다.
- PAT 만료·폐기 시 GitHub에서 새 PAT를 발급하고 SSM 값을 갱신한다.
- SSM 파라미터와 EBS는 클러스터 destroy와 별개로 남을 수 있으므로 필요 시 별도 삭제한다.

## 선택지 비교

| 방식 | 비용 | 운영 난이도 | 판단 |
| --- | --- | --- | --- |
| GHCR public 전환 | Secret 비용 없음 | 낮음 | private 패키지 요구가 없을 때만 |
| PAT 수동 `kubectl create secret` | 낮음 | 반복 작업 발생 | 단명 클러스터에는 부적합 |
| SSM SecureString + 자동 복구 | 낮음 | IAM·초기 설정 필요 | 현재 PoC 권장 |
| External Secrets Operator | 추가 컴포넌트 필요 | 높음 | 장기 운영 단계에서 검토 |

## 참고 자료

- [AWS Systems Manager Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)
- [AWS GetParameter API](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_GetParameter.html)
- [AWS EC2 On-Demand Pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [GitHub Personal Access Tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token)
