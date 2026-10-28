# k6 롤아웃 실험 실행 중단 및 결과 회수 문제

## 0) 메타 정보

- **Mode:** `OPS`
- **Status:** `Resolved` (실행·회수 경로); 기본·조정 설정 비교 실험은 별도
- **작성자:** 박건우(@geonusp)
- **작성일:** 2026-10-11
- **해결 날짜:** 2026-10-12
- **컴포넌트:** kubernetes, k6, aws-ssm, s3, bash
- **환경:** AWS EC2 kubeadm dev 클러스터, Windows Git Bash
- **관련 이슈/PR:** Issue #3 성능 테스트, PR 4 롤아웃 결과 기록
- **키워드:** `Job`, `kubectl exec`, `kubectl logs`, `raw_json_start`, `raw_json_end`, `SSM timeout`, `ImagePullBackOff`
- **관련 문서:** [k6 실행 시간 옵션 충돌](k6-duration-option-collision.md), [성공한 smoke 실험 결과](../experiments/issue-3/README.md)

---

## 1) 요약

PR 4 롤아웃 실험을 실행하면서 세 지점에서 막혔다.

1. k6 Job이 완료된 뒤 `kubectl exec`를 시도해 실패했다. 완료된 Pod는 실행 중인 컨테이너가 없어 `exec` 대상이 될 수 없다.
2. SSM 출력에서 raw JSON 구간 마커를 찾지 못해 로컬 결과 파일 생성이 중단됐다. 원격 로그 출력과 로컬 파서가 같은 마커 계약을 사용해야 한다.
3. 로컬 `ssm_run`은 기본 900초 안에 명령이 끝나지 않으면 실패를 반환하지만, 이때 원격 SSM Run Command가 취소되는 것은 아니다. 실제 invocation이 계속 `InProgress`로 남은 것을 확인했다.

마커 처리 코드와 실행 시간 변수 충돌을 수정한 뒤 `pr4-smoke-fixed`가 실제 클러스터에서 완료됐다. 원본 JSON 회수와 image A(`latest`) 복구도 확인했다. 900초 timeout으로 이어진 비정상적인 출력 증가의 확정 원인과 재검증은 [k6 실행 시간 옵션 충돌](k6-duration-option-collision.md)에 분리해 기록했다. 이 성공은 단일 smoke 실험의 결과이며 기본·조정 설정 비교 완료를 뜻하지 않는다.

## 1-1) 학습 포인트

- **빠른 확인 포인트 (3):** (1) k6 Job Pod가 실행 중인지 완료됐는지 (2) 원격 출력과 로컬 파서의 마커가 일치하는지 (3) 로컬 timeout 뒤 원격 SSM invocation이 계속 실행 중인지
- **Rule of thumb:** Job이 완료된 뒤에는 `kubectl exec` 대신 Pod 로그를 조회하고, SSM 로컬 대기 종료를 원격 실행 종료로 해석하지 않는다.
- **Anti-pattern:** 실패 원인을 확인하기 전에 전체 raw JSON을 터미널에 덤프하거나 같은 실험을 즉시 재실행하지 않는다.

---

## 2) 증상

### 관측된 현상

- 완료된 Job Pod에서 `kubectl exec`가 실패했다.
- 원격 출력과 로컬 파서의 raw JSON 마커가 달라 결과 분리가 실패했다.
- 로컬 SSM 대기 제한을 넘었지만 원격 명령은 계속 실행 중이었다.

### 에러 메시지 / 로그

```text
error: cannot exec into a container in a completed pod; current phase is Succeeded
[beach-k8s] ERROR: raw k6 JSON markers are missing from SSM output
[beach-k8s] ERROR: SSM command on i-0eabc9e2bea950630 did not finish within 900s
```

### 진단 과정과 사용한 명령

#### 2-1) 완료된 Job Pod에 `kubectl exec` 실패

##### 관측된 현상

첫 실행에서 다음 오류가 발생했다.

```text
error: cannot exec into a container in a completed pod; current phase is Succeeded
```

##### 원인

k6 컨테이너가 종료되고 Job Pod가 `Succeeded`가 된 뒤 `kubectl exec`로 결과 파일을 읽으려 했다. `exec`는 실행 중인 컨테이너에 명령을 전달하는 기능이므로 종료된 컨테이너에는 사용할 수 없다.

##### 대응 및 확인

Job 로그를 회수하는 방식으로 변경했다. 현재 Job 컨테이너는 `raw.json`을 만든 뒤 stdout에도 출력하고, 원격 스크립트는 완료된 Pod의 로그를 읽는다.

```bash
kubectl -n beach get pods -l job-name=beach-k6-rollout -o wide
```

```bash
kubectl -n beach logs <k6-pod-name> -c k6
```

Job Pod는 `ttlSecondsAfterFinished: 3600` 설정으로 완료 후 1시간 동안 남는다. 결과를 늦게 확인해 Pod가 이미 정리됐다면 Job을 다시 실행해야 한다.

---

#### 2-2) SSM 출력에서 raw JSON 마커 누락

##### 관측된 현상

로컬 결과 회수 단계가 다음 오류로 끝났다.

```text
[beach-k8s] ERROR: raw k6 JSON markers are missing from SSM output
```

##### 원인과 조사 포인트

로컬 스크립트는 SSM 출력에서 정확히 `raw_json_start`와 `raw_json_end`를 찾아 `raw.json`을 분리한다. 초기에 원격 stdout과 로컬 파서의 마커가 일치하지 않아 추출이 실패했다.

다음 가능성은 구분해서 확인한다.

- 원격 스크립트가 k6 로그를 내보내지 못했거나, raw JSON을 감싸는 마커를 출력하지 않았다.
- Job이 실패했거나 로그 조회 단계가 실패했다.
- 출력이 잘려 마지막 마커가 사라졌다. 다만 S3 출력이 설정된 경우에는 SSM `GetCommandInvocation`의 제한된 출력 필드가 아니라 S3 결과 객체 회수 경로를 확인해야 한다.

전체 출력을 터미널에 무작정 덤프하지 않는다. 실제 raw JSON은 수십~수백 MB가 될 수 있으며, 화면 출력은 원인을 좁히지 못하고 결과를 더 다루기 어렵게 만든다.

##### 현재 마커 계약

현재 `run-rollout-experiment.sh`는 원격에서 `kubectl logs`를 읽으며 JSON point 레코드 구간을 아래 두 줄로 감싼다. 로컬 파서는 이 문자열을 기준으로 `raw.json`과 `remote-output.txt`를 나눈다.

```text
raw_json_start
{"metric":"...","type":"Point",...}
raw_json_end
```

마커 추출이 다시 실패하면 실행 스크립트에 전체 stdout 덤프를 추가하기 전에 SSM invocation 상태와 S3 출력 객체가 존재하는지 확인한다. 필요하면 S3에서 내려받은 파일에서 마커 문자열만 검색한다.

```bash
rg -n -m 5 'raw_json_start|raw_json_end|k6_summary_start|endpoint_samples_start' deploy/k8s/loadtest/results/<label>/remote-output.txt
```

마커 회귀 테스트와 셸 문법 검사는 통과했다. 이 검증은 로컬 스크립트의 형식 일치만 확인하며 실제 SSM/S3 실행 성공을 보장하지는 않는다.

---

#### 2-3) 로컬 SSM 대기 timeout과 원격 명령 지속

##### 관측된 현상

실험 실행 후 900초가 지나 로컬에서 다음 오류가 반환됐다.

```text
[beach-k8s] ERROR: SSM command on <instance-id> did not finish within 900s
```

그 뒤 `aws ssm list-command-invocations` 조회에서 해당 명령이 `InProgress`로 나타났다.

##### 원인

`SSM_COMMAND_TIMEOUT_SECONDS`는 로컬 `ssm_run`이 invocation 상태를 기다리는 최대 시간이다. 시간이 초과되면 로컬 스크립트가 실패로 종료하지만, 원격 SSM Run Command를 취소하지 않는다.

원격 스크립트에는 종료 시 image A 복구와 임시 디렉터리 정리를 수행하는 `EXIT` trap이 있다. 따라서 로컬에서 timeout 메시지를 봤다고 곧바로 원격 명령이 끝났거나 이미지 복구가 완료됐다고 판단하면 안 된다. 반대로, 원격 명령이 아직 진행 중일 수 있으므로 같은 실험을 즉시 재실행하면 기존 실행과 겹칠 수 있다.

##### 진단 절차

1. 오류 출력에 표시된 instance ID를 사용해 최근 invocation을 조회한다.

```bash
aws ssm list-command-invocations --instance-id <instance-id> --details --max-results 5 --query "CommandInvocations[].[CommandId,Status,RequestedDateTime]" --output table
```

2. 해당 `CommandId`가 `InProgress`, `Pending`, `Delayed`라면 재실행하지 말고 같은 명령의 상세 상태와 출력을 확인한다.

```bash
aws ssm get-command-invocation --command-id <command-id> --instance-id <instance-id> --query "[Status,StatusDetails,StandardErrorContent,StandardOutputUrl]" --output json
```

3. 원격 상태가 끝난 뒤 현재 Beach 이미지와 파드 상태를 확인한다.

```bash
ssm_run "<instance-id>" "export KUBECONFIG=/root/.kube/config; kubectl -n beach get deployment beach -o jsonpath='{.spec.template.spec.containers[0].image}'; kubectl -n beach get pods -l app.kubernetes.io/name=beach -o wide"
```

4. Image pull 문제인지 구분해야 하면 새 파드의 `describe`와 이벤트를 확인한다.

```bash
ssm_run "<instance-id>" "export KUBECONFIG=/root/.kube/config; kubectl -n beach describe pod <beach-pod-name>; kubectl -n beach get events --sort-by=.lastTimestamp | tail -n 20"
```

`ImagePullBackOff` 또는 `ErrImagePull` 이벤트가 있으면 이미지 태그·접근 권한·레지스트리 pull 문제를 조사한다. 파드가 이미 `Ready`이고 새 이미지로 바뀌었다면 이미지 다운로드가 현재 지연 원인이라고 단정하지 않는다.

이번 900초 초과 실행에서는 Job이 이미 `Complete`인 동안 `kubectl logs ... | awk ...`가 실행 중이었고, 이전 출력 객체는 약 302MB였다. 큰 출력의 선행 원인은 `K6_DURATION`이 k6 내장 옵션으로 해석되어 초당 1회 `rollout` 시나리오 대신 `default` 시나리오가 실행된 것이었다. 세부 증거와 수정은 [별도 문서](k6-duration-option-collision.md)를 참조한다. 프로세스가 오래 살아 있었다는 사실만으로 파이프 교착 상태를 단정하지 않는다.

##### 안전한 재실행 기준

- 이전 invocation이 아직 진행 중이면 같은 실험을 시작하지 않는다.
- 이전 invocation이 끝난 뒤 Deployment가 image A로 복구됐는지 확인한다.
- 결과 디렉터리의 label을 재사용할 때 기존 파일이 덮어써질 수 있으므로, 재실행에는 새 label을 사용한다.
- timeout을 늘리는 것은 원격 명령의 실제 지연 원인을 해결하지 않는다. invocation 상태와 해당 단계의 로그를 먼저 확인한다.

---

## 3) 영향 범위

- **영향받는 기능:** Issue #3 롤아웃 실험 실행 및 k6 결과 파일 회수
- **영향받는 사용자/데이터:** dev 환경 실험 결과; 첫 회차와 timeout 회차를 정상 비교 결과로 사용할 수 없었다.
- **심각도(개발 단계):** `High` — 실험 자동화가 완료되지 않아 결과 기록이 중단됐다.
- **데이터 보존:** SSM S3 전체 출력과 완료된 Job 로그로 당시 상태를 조사할 수 있었지만, 로컬 결과 파일이 생성되지 않은 회차가 있었다.

---

## 4) 재현 방법

### 전제 조건

- **브랜치/커밋:** 완료된 Pod에 `kubectl exec`를 쓰거나 raw JSON 마커가 일치하지 않던 수정 전 실험 스크립트
- **의존성/버전:** Kubernetes Job, Grafana k6 2.3.0, AWS SSM Run Command
- **환경:** AWS EC2 kubeadm dev 클러스터, Windows Git Bash

### 재현 절차

1. 완료된 k6 Job Pod에 `kubectl exec`를 실행하면 컨테이너 종료 오류가 발생한다.
2. 원격에서 출력한 마커와 로컬 파서가 기대하는 마커를 다르게 두면 raw JSON 분리에 실패한다.
3. `K6_DURATION` 충돌로 결과가 폭증한 회차에서 로컬 900초 대기 제한에 이르더라도, 원격 invocation은 계속 진행될 수 있다.

### 기대 결과

- Job 완료 후 로그에서 원본 JSON을 회수하고, 로컬에 결과 파일을 생성하며, 배포 이미지를 image A로 복구한다.

### 기존 실제 결과

- 순서대로 완료된 Pod에 대한 `exec` 오류, raw JSON 마커 누락 오류, 로컬 SSM 900초 timeout을 관측했다.

---

## 5) 원인 분석

### 근거

- 첫 실패 당시 k6 Pod의 phase는 `Succeeded`여서 `kubectl exec` 대상이 아니었다.
- 로컬 파서는 `raw_json_start`와 `raw_json_end`를 요구하지만 초기 원격 출력과 일치하지 않았다.
- 로컬 timeout 이후 SSM invocation은 `InProgress`였고, Job 완료 뒤에도 `kubectl logs | awk`가 실행 중이었다.

### 최종 원인

완료된 컨테이너에서 파일을 읽으려던 회수 방식과 원격·로컬 마커 계약 불일치가 처음 두 실패의 원인이었다. 900초 timeout으로 이어진 비정상적인 출력 증가의 선행 원인은 k6 내장 `K6_DURATION` 옵션 충돌이며, 자세한 증거는 [별도 문서](k6-duration-option-collision.md)에 기록했다. 로그 회수 구간의 내부 병목 지점은 확정하지 않았다.

---

## 6) 해결

### 해결 전략

- **유형:** `Script fix` + `Config change` + `Documentation`
- **접근:** 완료된 Pod의 로그로 결과를 회수하고, 원격·로컬 마커를 일치시키며, k6 내장 옵션과 사용자 변수의 충돌을 제거한다.

### 변경 사항

- 완료된 Pod에 대한 `kubectl exec`를 `kubectl logs` 기반 회수로 변경했다.
- 원격 출력과 로컬 파서가 `raw_json_start`·`raw_json_end` 계약을 공유하도록 수정했다.
- Job과 스크립트의 사용자 실행 시간 변수를 `BEACH_K6_DURATION`으로 변경했다. 상세한 수정·검증은 [옵션 충돌 문서](k6-duration-option-collision.md)를 참조한다.

### 주의/부작용

- 완료된 Job Pod는 TTL이 지나면 삭제되므로, 로그 회수를 지연시키면 원본을 잃을 수 있다.
- 로컬 timeout만으로 원격 명령이 취소되지 않는다. 재실행 전에 invocation 종료와 이미지 복구를 확인한다.

---

## 7) 검증

### 해결 확인

- 완료된 k6 Pod에 `kubectl exec`를 실행하면 실패한다.
- 로컬 파서가 기대하는 raw JSON 마커 문자열은 `raw_json_start`와 `raw_json_end`다.
- SSM 로컬 대기 제한은 기본 900초이며 timeout 오류만으로 원격 명령이 종료되지는 않는다.
- 마커 처리 코드의 로컬 회귀 테스트 및 셸 문법 검사는 통과했다.
- `pr4-smoke-fixed`에서 `rollout` 시나리오로 390건을 실행하고 원본 JSON을 로컬에 회수했다. 390건 모두 HTTP 200, 롤아웃 105초, 배포 이미지 `latest` 복구를 확인했다.
- 비정상적인 이전 실행의 큰 출력은 k6 내장 `K6_DURATION` 옵션과 사용자 입력의 충돌에서 시작됐다. 수정 후 raw JSON은 약 1.8MB였다.

### 실행한 커맨드/테스트

```bash
bash deploy/k8s/scripts/test-rollout-experiment.sh
bash deploy/k8s/scripts/run-rollout-experiment.sh ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest ghcr.io/geonusp/beach_complex-k8s-poc-backend:dd3bf27b380fc9550aeb5fc260c6b83da249c9f2 1 30 30 pr4-smoke-fixed
```

### 아직 확인되지 않은 것과 별도 실험

- 이전 실행에서 `kubectl logs`, `awk`, SSM Agent 중 어느 내부 단계가 가장 오래 걸렸는지. `ps`와 S3 출력 크기만으로 교착 상태를 증명할 수 없다.
- 기본·조정 설정의 동일 조건 비교는 현재 #3 범위에서 제외한다. readiness 실패 시 endpoint 제외·재포함은 이후 [별도 Redis 장애 회차](../experiments/issue-3/readiness-endpoint/README.md)에서 확인했으며 이번 smoke 결과와 구분한다.

성공한 단일 회차의 상세 수치와 원본 파일은 [이슈 #3 실험 결과](../experiments/issue-3/README.md)에 보존했다.

---

---

## 8) 재발 방지

### 방지 조치 체크리스트

- [x] **가드레일:** 완료된 Pod의 로그를 사용하고 raw JSON 구간 마커를 일치시킴
- [x] **테스트 추가:** 마커 계약과 `K6_DURATION` 이름 충돌에 대한 회귀 검증
- [x] **문서화:** SSM timeout 이후 원격 상태 확인과 안전한 재실행 기준 기록

### 남은 작업

- [x] 별도 Redis 장애 회차의 readiness endpoint 제외·재포함 근거 연결. 요청 실패율은 미측정
- [ ] 기본·조정 설정 비교는 현재 범위 제외이며, 다시 수행할 경우 별도 회차로 기록
- [ ] 정상 요청률에서도 결과 회수가 지연된다면 `kubectl logs`·SSM/S3 구간별 소요 시간 측정

---

## 9) 참고 자료

- [Kubernetes: Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/)
- [Kubernetes: kubectl logs](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_logs/)
- [AWS Systems Manager: Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/execute-remote-commands.html)
- [AWS CLI: get-command-invocation](https://docs.aws.amazon.com/cli/latest/reference/ssm/get-command-invocation.html)
- [Grafana k6: `K6_DURATION` 실행 옵션](https://grafana.com/docs/k6/latest/using-k6/k6-options/reference/)
