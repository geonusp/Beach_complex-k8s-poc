# k6 실행 시간 옵션 충돌로 롤아웃 실험 출력이 폭증한 문제

## 0) 메타 정보

- **Mode:** `OPS`
- **Status:** `Resolved`
- **작성자:** 박건우(@geonusp)
- **작성일:** 2026-10-12
- **해결 날짜:** 2026-10-12
- **컴포넌트:** k6, Kubernetes Job, kubectl logs, AWS SSM, S3
- **환경:** AWS EC2 kubeadm dev 클러스터, Windows Git Bash
- **관련 이슈/PR:** Issue #3, PR 4 롤아웃 결과 기록
- **키워드:** `K6_DURATION`, `constant-arrival-rate`, `scenario:default`, `SSM timeout`, `raw.json`
- **관련 문서:** [롤아웃 실험 실행·회수 문제](rollout-experiment.md), [성공한 smoke 실험 결과](../experiments/issue-3/README.md)

---

## 1) 요약

- **무슨 문제였나:** 초당 1회로 설정한 롤아웃 실험이 k6의 `default` 시나리오로 실행돼 요청과 원본 JSON 출력이 폭증했고, 로컬 SSM 대기 시간이 초과됐다.
- **원인:** 사용자 정의 실행 시간에 `K6_DURATION`을 사용해 k6 내장 duration 옵션과 충돌했다.
- **해결:** 환경변수를 `BEACH_K6_DURATION`으로 변경하고 실제 클러스터에서 smoke 실험을 재검증했다.

## 1-1) 학습 포인트

- **빠른 확인 포인트 (3):** (1) k6 로그의 시나리오 이름 (2) 요청 수와 설정한 요청률의 일치 여부 (3) 로컬 timeout 이후 원격 SSM invocation 상태
- **Rule of thumb:** k6 사용자 입력 환경변수는 내장 `K6_*` 옵션과 이름이 겹치지 않게 한다.
- **Anti-pattern:** 오래 실행된 `kubectl logs | awk` 프로세스만 보고 파이프 교착 상태를 확정하지 않는다.

---

## 2) 증상

### 관측된 현상

`run-rollout-experiment.sh`에 `1` req/s를 전달했지만, 첫 실행의 k6 결과에는 의도한 `rollout` 대신 `scenario:"default"`가 기록됐다. 3분 20초 시점에 완료된 반복은 약 5만 5천 회로, 초당 1회와 맞지 않았다.

원본 JSON을 포함한 한 SSM stdout 객체는 **302,221,224바이트**였다. 다른 실행에서는 로컬 스크립트가 900초 대기 제한에 도달했지만 원격 invocation은 `InProgress`였고, Control Plane에서 `kubectl logs ... | awk ...` 프로세스가 17분 이상 살아 있었다. k6 Job 자체는 이미 `Complete`였다.

이 관측은 **로그 회수 단계가 로컬 대기 제한 안에 끝나지 않았음**을 보여준다. 다만 `ps` 출력만으로 파이프 교착 상태, `awk` 처리 속도, SSM Agent 업로드 중 어느 지점이 정확한 병목이었는지는 판정할 수 없다. 앞선 302MB 출력의 SSM invocation은 최종적으로 `Success`가 됐고 종료 마커도 S3 객체에 남았다.

### 에러 메시지 / 로그

```text
[beach-k8s] ERROR: SSM command on i-0eabc9e2bea950630 did not finish within 900s
running (3m20.0s), 1/1 VUs, 55151 complete and 0 interrupted iterations
```

첫 줄은 로컬 대기 제한 오류이고, 둘째 줄은 의도한 1 req/s와 실제 반복 수가 달랐음을 보여주는 당시 k6 출력이다.

### 진단 과정과 사용한 명령

아래는 당시의 조사 순서다. EC2 instance ID·SSM command ID·S3 key는 해당 실험의 값으로 바꿔야 하며, 이미 종료된 실행의 ID를 새 실험에 재사용하지 않는다. Control Plane 명령은 **SSM 대화형 셸**에서 실행했다. `ssm-user`는 `/root/.kube/config`를 읽지 못하므로 `sudo kubectl`을 사용했다.

#### 2-1) 로컬 timeout과 원격 실행 상태를 분리

로컬 Git Bash에서 최근 SSM invocation을 조회했다.

```bash
aws ssm list-command-invocations --instance-id i-0eabc9e2bea950630 --max-results 5 --query "CommandInvocations[].[CommandId,Status,RequestedDateTime]" --output table
```

당시 `208fe15c-8a25-4106-bcac-84fb6d4c180f`는 로컬 900초 timeout 이후에도 `InProgress`였다. 같은 ID의 상세 상태를 확인했다.

```bash
aws ssm get-command-invocation --instance-id i-0eabc9e2bea950630 --command-id 208fe15c-8a25-4106-bcac-84fb6d4c180f --query "[Status,StatusDetails,StandardOutputUrl]" --output json
```

`Status`와 `StatusDetails`가 `InProgress`였고, 완료 전이라 `StandardOutputUrl`은 비어 있었다. **로컬 대기 종료와 원격 명령 종료는 별개**임을 확인했다.

별도 재현에서는 로컬 스크립트를 `bash -x`로 실행해 `ssm_run`이 같은 invocation의 `InProgress`를 5초마다 조회하다가 900초 제한에 이르는 흐름도 확인했다.

```bash
bash -x deploy/k8s/scripts/run-rollout-experiment.sh ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest ghcr.io/geonusp/beach_complex-k8s-poc-backend:dd3bf27b380fc9550aeb5fc260c6b83da249c9f2 1 30 30 pr4-rerun-20261012
```

`bash -x`는 인코딩된 원격 스크립트와 변수값까지 출력할 수 있으므로 상시 실행 명령이 아닌 당시의 조사 기록이다.

#### 2-2) 롤아웃·Job·로그 회수 중 어디에 머무는지 확인

Control Plane에서 배포와 Job을 각각 확인했다.

```bash
sudo kubectl -n beach rollout status deployment/beach
sudo kubectl -n beach get job beach-k6-rollout -o wide
sudo kubectl -n beach get pods -l job-name=beach-k6-rollout -o wide
sudo kubectl -n beach get deployment beach -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

배포는 성공했고 k6 Job도 `Complete`(6분 48초)였지만, Deployment 이미지는 아직 image B였다. 즉 원격 스크립트가 마지막의 image A 복구 단계까지 도달하지 않았다. 같은 시점에 남은 프로세스를 조회했다.

```bash
sudo ps -C kubectl -C awk -o pid,ppid,etime,stat,args
```

`kubectl -n beach logs <k6-pod> -c k6`와 뒤따르는 `awk`가 17분 이상 실행 중이었다. 이것은 **로그 회수 단계에 머무른 증거**이지 파이프 교착 상태의 증거는 아니다.

#### 2-3) 예상 시나리오와 실제 실행을 대조

Job과 Pod가 같은 실행에 속하는지, 실행 중인 Pod에 어떤 환경변수가 주입됐는지 확인했다. `kubectl exec`는 Pod가 `Running`일 때만 가능하다.

```bash
sudo kubectl -n beach get pods -l job-name=beach-k6-rollout -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,CREATED:.metadata.creationTimestamp,OWNER:.metadata.ownerReferences[0].uid
sudo kubectl -n beach exec beach-k6-rollout-bv9xd -c k6 -- sh -c 'printf "K6_RATE=%s K6_DURATION=%s\n" "$K6_RATE" "$K6_DURATION"; grep -n -E "rollout:|constant-arrival-rate|rate:|duration," /scripts/rollout.js'
```

당시 Pod에는 `K6_RATE=1`, `K6_DURATION=390s`가 들어 있었고 스크립트에는 `rollout`의 `constant-arrival-rate` 설정이 있었다. ConfigMap도 별도로 조회해 원본 시나리오가 잘못 배포된 것은 아닌지 확인했다.

```bash
sudo kubectl -n beach get configmap beach-k6-rollout -o jsonpath='{.data.rollout\.js}' | grep -n -A 8 -E 'scenarios|executor|rate|duration'
```

그런데 실제 k6 로그는 `scenario:"default"`와 3분 20초에 약 5만 5천 번의 완료된 반복을 보였다. 따라서 **스크립트에 적힌 시나리오와 k6가 채택한 실행 옵션이 달랐다.** 당시 전체 로그를 `kubectl logs -f`로 따라갔지만 원시 JSON이 계속 출력되어 진단에는 비효율적이었다. 재진단 때는 시나리오 헤더와 요약만 확인한다.

#### 2-4) S3 전체 출력으로 크기와 완료 여부 확인

`GetCommandInvocation.StandardOutputContent`는 앞부분만 보여주므로 S3의 전체 stdout 객체를 확인했다. 이전 실행 `62020262-d85d-484f-bc80-3d11bfe551ac`의 최종 상태와 출력 URL을 먼저 조회했다.

```bash
aws ssm get-command-invocation --instance-id i-0eabc9e2bea950630 --command-id 62020262-d85d-484f-bc80-3d11bfe551ac --query "[Status,StatusDetails,StandardErrorContent,StandardOutputUrl]" --output json
```

`Success`와 stdout의 S3 URL을 확인한 뒤 객체 크기를 조회했다.

```bash
aws s3api head-object --bucket beach-complex-dev-k8s-results-489636f04c39ff69ee3a6ed990 --key rollout/pr4-rerun-20261012/62020262-d85d-484f-bc80-3d11bfe551ac/i-0eabc9e2bea950630/awsrunShellScript/0.awsrunShellScript/stdout --query ContentLength --output text
```

결과는 `302221224`바이트였다. 당시 객체의 끝부분은 아래 명령으로 확인했다.

```bash
aws s3 cp s3://beach-complex-dev-k8s-results-489636f04c39ff69ee3a6ed990/rollout/pr4-rerun-20261012/62020262-d85d-484f-bc80-3d11bfe551ac/i-0eabc9e2bea950630/awsrunShellScript/0.awsrunShellScript/stdout - | tail -c 1000
```

끝부분에 `raw_json_end`와 `endpoint_samples_end`가 있었다. 이는 302MB stdout 경로가 **느렸지만 완료된 사례**라는 의미다. 이 명령은 객체 전체를 내려받으므로 큰 결과에서는 반복하지 않는다.

---

## 3) 영향 범위

- **영향받는 기능:** Issue #3 롤아웃 성능 실험의 요청률 제어와 결과 회수
- **영향받는 사용자/데이터:** dev 클러스터의 실험 트래픽과 해당 회차의 k6 결과; 사용자 데이터 손상은 확인되지 않았다.
- **심각도(개발 단계):** `High` — 의도한 부하 조건을 지키지 못해 이전 결과를 비교 실험에 사용할 수 없다.
- **결과 보존:** 약 302MB의 SSM stdout은 S3에 저장됐으나, 해당 회차는 정상적인 1 req/s 측정값이 아니다.

---

## 4) 재현 방법

### 전제 조건

- **브랜치/커밋:** 수정 전 `K6_DURATION`을 사용하는 Job 매니페스트와 `rollout.js`
- **의존성/버전:** Kubernetes Job, Grafana k6 2.3.0, AWS SSM Run Command
- **환경:** AWS EC2 kubeadm dev 클러스터

### 재현 절차

1. Job에 `K6_RATE=1`과 `K6_DURATION=390s`를 주입한다.
2. `rollout.js`에는 `constant-arrival-rate`와 `rate: 1`인 `rollout` 시나리오를 둔다.
3. Job 로그에서 실행된 시나리오 이름과 3분 20초 시점의 완료 반복 수를 확인한다.

### 기대 결과

- `rollout` 시나리오가 실행되고 초당 약 1회의 요청이 발생한다.

### 기존 실제 결과

- `default` 시나리오가 실행돼 3분 20초에 약 5만 5천 회가 완료됐다.
- 한 회차의 SSM stdout이 302,221,224바이트로 늘었고, 다른 회차는 로컬 900초 대기 제한을 넘었다.

---

## 5) 원인 분석

### 근거

- 실행 중인 Pod에 `K6_RATE=1`, `K6_DURATION=390s`가 주입돼 있었다.
- ConfigMap의 `rollout.js`에는 `constant-arrival-rate` 시나리오가 있었지만 실제 로그에는 `scenario:"default"`가 기록됐다.
- k6 공식 옵션 문서는 `K6_DURATION`을 내장 실행 시간 옵션으로 정의한다.

### 최종 원인

당시 Job은 아래 값을 컨테이너 환경변수로 주입했고, `rollout.js`도 같은 이름을 사용자 입력으로 읽었다.

```yaml
- name: K6_DURATION
  value: "390s"
```

```javascript
const duration = __ENV.K6_DURATION || '2m';
```

그러나 `K6_DURATION`은 k6가 자체 실행 시간 옵션으로 해석하는 환경변수다. 실행 옵션이 스크립트의 `options.scenarios.rollout`을 대체하면서 `constant-arrival-rate`의 `rate: 1`이 적용되지 않았다. 로그의 `scenario:"default"`와 1 VU가 가능한 만큼 반복한 요청 수가 이를 뒷받침한다. [Grafana k6 옵션 문서](https://grafana.com/docs/k6/latest/using-k6/k6-options/reference/)도 `K6_DURATION`과 `--duration`을 같은 실행 옵션으로 설명하고, duration shortcut이 스크립트 시나리오를 대체할 수 있다고 명시한다.

원인과 결과의 순서는 다음과 같다.

```text
K6_DURATION 주입 → k6 내장 duration 옵션 적용 → rollout 시나리오 대신 default 시나리오 실행
→ 요청·raw JSON 급증 → kubectl logs 및 SSM 출력 회수가 길어짐 → 로컬 900초 대기 제한 초과
```

마지막 화살표는 **관측된 실행 순서와 출력 크기에 근거한 설명**이다. `awk` 또는 SSM Agent 내부에서 교착 상태가 발생했다는 뜻은 아니다. 로컬 timeout은 원격 Run Command를 자동 취소하지 않는다.

---

## 6) 해결

### 해결 전략

- **유형:** `Config change` + `Regression test`
- **접근:** k6 내장 옵션과 충돌하는 사용자 변수의 이름만 바꾸고 기존 원본 결과 회수 경로는 유지한다.

### 변경 사항

Job의 사용자 입력 이름을 `BEACH_K6_DURATION`으로 바꾸고, `rollout.js`도 `__ENV.BEACH_K6_DURATION`을 읽도록 맞췄다. 이 이름은 k6 내장 duration 옵션이 아니므로 실행 시간은 스크립트의 `rollout.duration`에만 전달된다. 동일 충돌이 재발하지 않도록 `test-rollout-experiment.sh`에 회귀 검증을 추가했다. 수정 커밋은 `4093d1dd`다.

원본 데이터 보존 요구사항은 그대로 유지했다. `k6 run --out json=/results/raw.json`으로 파일을 만들고, Job 종료 시 `cat /results/raw.json`으로 Pod 로그에 출력해 SSM/S3로 회수한다. 원본 출력 경로를 제거한 것이 아니라 **비정상적인 요청량을 만든 설정 충돌을 제거한 것**이다.

### 주의/부작용

`cat /results/raw.json`을 제거하면 현재 구조에서는 원본 JSON을 회수할 수 없다. 로컬 timeout을 늘리는 것만으로 잘못된 요청률 설정은 해결되지 않는다.

---

## 7) 검증

### 해결 확인

수정 후 `pr4-smoke-fixed` 실행에서 다음을 확인했다.

| 항목 | 결과 |
| --- | --- |
| k6 시나리오 | `rollout: 1.00 iterations/s for 6m30s` |
| HTTP 요청 | 390건, 모두 200 |
| 5xx / 요청 실패 | 0건 / 0건 |
| 누락된 반복 | 1건 |
| 롤아웃 | 성공, 105초 |
| 회수된 raw JSON | 1,790,767바이트 |
| 이미지 원복 | Deployment 이미지가 `latest`인 것을 확인 |

상세 수치와 원본 파일은 [실험 결과 문서](../experiments/issue-3/README.md)에 보존했다. 이번 회차는 단일 smoke 실험이며 기본 설정과 조정 설정의 비교 결과는 아니다.

### 실행한 커맨드/테스트

다음 명령으로 로컬 회귀 테스트와 수정 후 실제 실험을 검증했다.

```bash
bash deploy/k8s/scripts/test-rollout-experiment.sh
bash deploy/k8s/scripts/run-rollout-experiment.sh ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest ghcr.io/geonusp/beach_complex-k8s-poc-backend:dd3bf27b380fc9550aeb5fc260c6b83da249c9f2 1 30 30 pr4-smoke-fixed
rg -c '"metric":"http_reqs"' deploy/k8s/loadtest/results/pr4-smoke-fixed/raw.json
rg '"metric":"http_reqs"' deploy/k8s/loadtest/results/pr4-smoke-fixed/raw.json | rg -o '"status":"[^"]+"' | sort | uniq -c
wc -c deploy/k8s/loadtest/results/pr4-smoke-fixed/raw.json
```

회귀 테스트는 `PASS`, 실험 스크립트는 완료, 원본에는 `http_reqs` 390개와 HTTP 200 390개가 있었다. 마지막으로 Control Plane에서 복구 이미지를 확인했다.

```bash
sudo kubectl -n beach get deployment beach -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

출력은 image A인 `ghcr.io/geonusp/beach_complex-k8s-poc-backend:latest`였다.

---

## 8) 재발 방지

### 방지 조치 체크리스트

- [x] **가드레일:** `K6_DURATION` 대신 `BEACH_K6_DURATION` 사용
- [x] **테스트 추가:** 이전 변수명이 다시 들어오지 않도록 회귀 검증 추가
- [x] **문서화:** 시나리오 불일치와 SSM 출력 증가의 진단 명령 기록

### 남은 작업과 재발 시 확인 순서

1. k6 출력의 시나리오 이름이 `rollout`인지 확인한다. `default`면 실행 옵션 환경변수가 스크립트 시나리오를 대체했는지 조사한다.
2. `http_reqs`와 `iterations`가 설정한 요청률·시간에 맞는지 확인한다. 단순히 Job `Complete`만 보지 않는다.
3. 로컬 timeout이 나면 기존 SSM invocation 상태와 실제 Deployment 이미지를 확인한 뒤 재실행한다. 진행 중인 명령과 새 실험을 겹치지 않는다.
4. 정상 요청률에서도 결과 회수가 지연된다면 그때 출력 크기와 `kubectl logs`·SSM/S3 구간을 별도로 측정한다. `cat`을 삭제하면 현재 구조에서는 원본 JSON도 회수되지 않는다.

---

## 9) 참고 자료

- [Grafana k6: 실행 옵션과 `K6_DURATION`](https://grafana.com/docs/k6/latest/using-k6/k6-options/reference/)
- [Grafana k6: 환경변수와 옵션 우선순위](https://grafana.com/docs/k6/latest/using-k6/environment-variables/)
- [AWS CLI: GetCommandInvocation 출력 제한과 S3 전체 출력 URL](https://docs.aws.amazon.com/cli/latest/reference/ssm/get-command-invocation.html)
