# SSM Run Command 실험 결과 저장소

## 상태

Proposed — 구현 PR에서 Terraform 구성과 SSM 결과 회수를 검증한 뒤 Accepted로 전환한다.

## 컨텍스트

이슈 #3의 Rolling Update 실험은 k6 원본 결과와 rollout 중 EndpointSlice 관찰값을 보존해야 한다.
현재 k6 Job은 `raw.json`을 `emptyDir`에 기록하므로 Job Pod가 사라지면 원본이 함께 사라진다.
실험 스크립트는 SSM Run Command의 stdout을 가져오지만, SSM의 표준 출력 응답은 첫 24,000자까지만 반환한다.
원본 k6 JSON을 stdout으로 받아도 큰 결과는 잘릴 수 있다.

결과 저장을 위해 별도 상시 서버를 두는 것은 측정 도구에 비해 운영 부담과 비용이 크다.
또한 클러스터는 실험이 끝나면 Terraform으로 제거하는 개발용 ephemeral 환경이다.

## 결정

**실험 시점에만 사용하는 비공개 S3 버킷을 Kubernetes dev Terraform 환경에서 생성하고, SSM Run Command의 전체 출력 임시 저장소로 사용한다.**

```text
[로컬 PC (현재) / CI (향후)]
    ──① SendCommand──▶ [AWS Systems Manager Run Command]
                              ──② 명령 전달──▶ [EC2 관리 노드 / SSM Agent]
                              ◀─③ stdout/stderr─ [EC2 관리 노드]
                              ──④ 출력 저장────▶ [Amazon S3]

[Amazon S3] ──⑤ 결과 객체 다운로드 (S3 읽기 권한)──▶ [로컬 PC (현재) / CI (향후)]

④ S3 쓰기 권한: 대상 EC2 인스턴스 프로파일
```

현재 실험 스크립트의 관리 대상 EC2는 Control Plane 인스턴스다. 다만 결과 저장은 Control Plane의 별도 업로드 작업이 아니라 SSM Run Command 출력 기능이 수행한다. GitHub Actions는 아직 연결되어 있지 않으며, 연결하더라도 호출·회수 주체만 바뀐다. **선택지 4는 이 흐름과 다른 향후 구조**로, k6 Job이 S3에 직접 업로드한다.

- **권한 주체:** 로컬 PC/CI 실행 주체는 SSM 명령 실행과 결과 객체 다운로드 권한을 가진다. S3에 명령 출력을 쓰는 권한은 명령 대상 EC2의 인스턴스 프로파일 역할이 제공한다. 이 흐름에서 k6 Pod가 S3에 직접 업로드하지 않는다.
- Terraform은 버킷, Block Public Access, 서버 측 암호화, 노드 공유 역할의 prefix 한정 업로드 권한을 관리한다. 현재 호출 대상은 Control Plane이지만 IAM 역할은 네 노드가 공유하므로 권한이 Control Plane에만 격리된 구성은 아니다.
- `run-rollout-experiment.sh`는 `--output-s3-bucket-name`과 실행별 prefix를 지정한다. 원격 스크립트는 k6 원본 JSON을 마커로 둘러 stdout에 기록한다.
- 로컬 스크립트는 S3에 저장된 전체 stdout을 결과 디렉터리로 회수하고 요약과 원본 JSON을 분리 저장한다.
- 실험 스크립트는 기존처럼 Control Plane을 SSM Run Command 대상으로 사용한다. SSM Agent가 명령 출력(stdout/stderr)을 S3에 저장하며, Control Plane의 별도 AWS CLI 업로드 단계는 두지 않는다.
- 향후 k6 실행을 Kubernetes Job으로 정착시키고 파일 단위 결과 업로드가 필요해지면, k6 Job이 결과물을 S3에 직접 업로드하는 구조를 별도로 검토한다. 이는 오토스케일러 도입만으로 자동 결정하지 않으며, Job에 부여할 최소 권한 AWS 자격 증명 방식도 함께 설계한다.
- 이 버킷은 장기 아카이브가 아니다. 결과 파일은 `terraform destroy` 전에 로컬로 회수하며, destroy 시 버킷과 S3 객체도 함께 삭제한다.
- 결과는 destroy 전에 로컬로 회수하며 S3만을 유일한 보존 위치로 삼지 않는다. #3·#5의 일부 증거는 Git에도 보존하지만 #4·#6의 전체 원본은 로컬 보관으로 외부 접근이 제한된다. [실험 결과 종합](../experiments/issue-8/README.md)의 회차별 접근성을 따른다.

### 범위 제외

- 상시 운영용 버킷이나 독립 Terraform state
- CloudWatch Logs 장기 보관, S3 Lifecycle 기반 장기 아카이브, 별도 EC2 결과 수집기
- AWS 계정 운영자 로컬 자격 증명 자체의 관리. 실험 실행자는 S3 객체 다운로드 권한을 별도로 보유해야 한다.

## 근거

- SSM Run Command는 S3 출력 대상을 지원한다. 실행 대상 관리 노드의 인스턴스 프로파일 역할이 출력 저장 권한을 제공하며, 호출 주체는 SSM을 통해 명령을 실행하고 이후 S3 결과를 회수한다. 전체 stdout을 SSM 응답 본문 대신 S3 객체에서 가져올 수 있다.
- 버킷은 실험 동안만 존재하므로 계속 실행되는 컴퓨팅 리소스가 추가되지 않는다.
- 동일 리전 내 소량 결과의 S3 저장·요청 비용은 클러스터 EC2 비용에 비해 매우 작다.
- 기존 SSM 기반 원격 실행 흐름을 유지하므로 SSH, Session Manager 대화형 세션, 인스턴스 내 AWS CLI 설치가 추가되지 않는다.

## 결과

### 긍정적 영향

- SSM 응답의 24,000자 제한으로 원본 JSON이 잘리는 문제를 피한다.
- 클러스터 Job Pod의 `emptyDir` 수명과 무관하게 로컬로 원본 결과를 회수할 수 있다.
- 버킷, 보안 설정, 업로드 권한이 Terraform 코드에 남는다.
- 클러스터와 함께 버킷을 제거할 수 있어 결과 전달용 저장소가 상시 남지 않는다.

### 부정적 영향

- Control Plane EC2 인스턴스 프로파일 역할에 S3 출력 저장 권한이 추가된다. 권한은 결과 버킷과 지정 prefix로 제한해야 한다.
- 로컬 PC/CI 실행 주체에는 SSM 명령 실행·상태 조회 권한과 해당 결과 객체를 읽을 권한이 필요하다.
- `terraform destroy` 전에 다운로드를 놓치면 S3 결과를 잃는다. 로컬 결과 파일을 확인한 뒤에만 destroy해야 한다.
- 실험 결과를 장기 보존하려면 S3에서 회수한 파일을 별도 버전 관리 저장소로 옮겨야 한다.

## 대안

### 선택지 1: SSM 응답 본문만 사용

- 장점: Terraform, IAM, 추가 저장소가 필요 없다.
- 단점: 기본 출력 응답 길이가 24,000자로 제한되어 raw JSON 보존을 보장하지 못한다.
- 결론: 기각.

### 선택지 2: CloudWatch Logs에 전체 출력 보관

- 장점: 로그 조회·검색과 보존기간 설정이 편리하다.
- 단점: 로그 그룹과 retention 설정을 추가해야 하고, 실험 원본 파일 회수에는 별도 수집 절차가 필요하다.
- 결론: 현재 소량·단기 실험에는 과하다.

### 선택지 3: Control Plane에서 직접 S3 업로드

- 장점: SSM stdout에 raw JSON을 섞지 않고 결과 파일을 별도 S3 객체로 저장할 수 있다.
- 단점: Control Plane에서 결과 파일을 다루는 업로드 로직과 S3 권한을 별도로 구현·유지해야 한다. 노드의 AWS CLI 설치·유지가 필요하며, 이전 GHCR 복구 과정에서 노드 내 AWS CLI 부재가 실제 장애 원인이 된 바 있다.
- 결론: 현재는 기각한다. SSM Run Command가 명령 실행과 출력 저장을 함께 제공하므로, 별도 업로드 구현이 필요 없는 현재 방식이 더 단순하다.

### 선택지 4: k6 Kubernetes Job에서 직접 S3 업로드

- 장점: 부하 생성과 결과 저장을 같은 Job 실행 흐름에 둘 수 있고, `raw.json.gz`, `summary.json` 등 결과물을 stdout 로그와 분리된 S3 객체로 저장할 수 있다.
- 단점: 현재 kubeadm 기반 클러스터에서 Pod에 안전하게 AWS 권한을 부여할 방법을 별도로 설계해야 한다. 노드 IAM 역할을 Pod가 무분별하게 공유하지 않도록 최소 권한과 자격 증명 전달 경로를 마련해야 하며, 업로드 실패 시 Job 실패·재시도 및 결과 중복 처리도 정의해야 한다.
- 결론: 현재 구현에는 채택하지 않는다. SSM Run Command의 S3 전체 출력 저장을 우선 사용한다. k6 실행을 Kubernetes Job으로 정착시키고 파일 단위 보관이 필요해지면, 전용 최소 권한 AWS 자격 증명 설계를 전제로 우선 검토할 향후 전환 후보로 둔다. 오토스케일러 도입 자체를 전환 조건으로 삼지는 않는다.

## 검증 계획

1. Terraform plan에서 S3 버킷, public access block, 암호화, scoped IAM 정책, 버킷 이름 output을 확인한다.
2. 오프라인 회귀 테스트에서 SSM send-command의 S3 인자와 결과 객체 회수, raw JSON 분리를 확인한다.
3. PR 머지 후 실제 dev apply에서 SSM stdout 객체가 생성되고, 로컬 결과 디렉터리에 원본 JSON이 저장되는지 확인한다.
4. 결과의 로컬 복사본을 확인한 뒤 Terraform destroy가 버킷과 객체까지 제거하는지 확인한다.

## 롤백 / 재검토 기준

- 버킷 정책을 prefix 한정으로 줄일 수 없으면 S3 업로드 권한을 부여하지 않고 다른 회수 방식을 검토한다.
- 실험 결과를 S3에 장기 보존해야 한다는 요구가 생기면 이 버킷을 ephemeral 환경에 포함하지 않고 별도 state/보존 정책을 설계한다.
- 결과 회수 실패 시 실험 스크립트는 성공으로 종료하지 않아야 하며, 사용자는 회수 확인 전 `terraform destroy`를 실행하지 않는다.

## 참고

### 공식 문서 링크

- [AWS Systems Manager Run Command 출력 설정](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-rc-setting-up-cwlogs.html)
- [AWS CLI `ssm send-command` 옵션](https://docs.aws.amazon.com/cli/latest/reference/ssm/send-command.html)
- [Amazon S3 요금](https://aws.amazon.com/s3/pricing/)

### 관련 이슈 / PR

- 이슈 #3 Probe 및 Rolling Update 사용자 영향 검증 — 작업 8, 9
- 이슈 #3 PR 3 — SSM 실험 출력 및 k6 원본 결과 S3 회수
- 이슈 #3 PR 4 — Rolling Update 기본·조정 설정 실험 결과 기록

### 관련 문서

- 이슈 #3 구현 문서 (로컬 참고·Git 미포함: `../../tempdocs/issue-3/README.md`)
- PR 3 구현 문서 (로컬 참고·Git 미포함: `../../tempdocs/issue-3/pr-3-ssm-s3-result-storage.md`)

## 작성일자

2026-10-10
