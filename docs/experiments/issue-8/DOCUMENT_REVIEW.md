# #8 문서 정합성 검토 기록

## 범위와 방법

기준 커밋 `8c3710d0` 이후의 문서 정정이다. 루트 README·docs·deploy/k8s의 Markdown 27개와 원래 체크아웃의 관련 tempdocs 33개를 목록화했다. 이 기록 자체는 추가 문서다.

검토는 현재 코드·매니페스트·Terraform·SSM/k6 스크립트 및 보존된 결과 문서와의 정적 대조다. 링크 대상, 문서의 명령 경로·입력값·기본 설정·완료/계획 구분을 확인했다. 과거 계획의 모든 AC를 다시 실행하거나 애플리케이션 전체 동작을 재검증한 것은 아니다.

## 저장소 문서별 결과

| 문서 | 확인·정정 결과 |
| --- | --- |
| `README.md` | 개인 수행 범위·표시 그림·실험 요약·실행 및 결과 링크 대조. 앞선 리뷰 반영본 유지 |
| `docs/adr/cilium-cni.md` | values.yaml의 Pod CIDR·kube-proxy 유지·Hubble 비활성 대조. 로컬 계획/로드맵의 접근성 표시 |
| `docs/adr/ephemeral-dependency-placement.md` | postgres/redis YAML과 대조. preferred anti-affinity는 배치 보장 아님을 명시 |
| `docs/adr/k8s-execution-environment.md` | Terraform 예시·역할·kind·CP 장애 영향 및 로컬 계획 접근성 정정. 초기 비용 수치는 과거 예산 전제 |
| `docs/adr/load-generator-placement.md` | k6 Job nodeSelector·SSM runner·#4 실측 대조. 별도 EC2 미구현과 obs-1 실측 범위 반영 |
| `docs/adr/node-access-ssm.md` | Terraform 공유 역할·SG·인라인 정책과 대조. Session Manager Plugin 필요 범위와 로컬 계획 접근성 정정 |
| `docs/adr/observability-stack-installation.md` | values·차트 버전·nodeSelector·retention·PodMonitor 대조. 로컬 구현 계획 접근성 정정 |
| `docs/adr/performance-test-orchestration.md` | 현재 SSM/Job 실행 및 로컬 원본 보관과 향후 CI·별도 EC2 계획 구분 |
| `docs/adr/readiness-dependency-policy.md` | 현재 readinessState,redis와 과거 제안 구분 유지. endpoint 관측과 요청 실패율 미측정 구분 |
| `docs/adr/README.md` | 10개 ADR의 링크·상태와 readiness 제안/현재 구현 구분 확인. 승인 상태 임의 변경 없음 |
| `docs/adr/resource-metrics-provider.md` | CSR 승인·serverTLSBootstrap·Metrics Server 설치 및 배치 대조. 오래된 리뷰 진행 상태 제거 |
| `docs/adr/ssm-run-command-output-storage.md` | S3 force_destroy·공유 IAM·ssm.sh S3 회수와 대조. 전체 원본의 로컬 접근 제약 명시 |
| `docs/experiments/issue-3/readiness-endpoint/README.md` | readiness 관측·요청 실패율 미측정을 결과 기록과 대조. 공개 SSM 출력 SHA-256 일치, 이번 재실행 없음 |
| `docs/experiments/issue-3/README.md` | smoke·Rolling Update 회차와 집계 범위·비교 범위 제외를 문서 간 대조. 공개 원본 5개 파일 SHA-256 일치, k6 재집계 없음 |
| `docs/experiments/issue-4/README.md` | 상세 문서 간 정적 대조, 전체 원본은 worktree에 미보유. 40 req/s 반복 미확장·120 req/s 별도 회차·HPA 판정 구분. 원본 대조·재집계 없음 |
| `docs/experiments/issue-5/README.md` | 지표·수집 조건·당시 CPU250m을 문서/설정과 대조. 공개 검증 출력·k6 요약·PNG 3개 파일 SHA-256 일치, k6 재집계 없음 |
| `docs/experiments/issue-6/README.md` | 상세 문서 간 정적 대조, 전체 원본은 worktree에 미보유. 장애 구간 472건과 전체 2,101건, 64.56초의 의미 구분. 원본 대조·재집계 없음 |
| `docs/experiments/issue-8/README.md` | 상세 문서의 인용값·원본 접근 제약·#8 완료 기준 대응을 정적 대조. 신규 측정·원본 재집계 없음 |
| `docs/kubernetes-ephemeral-cluster-cost-and-secrets.md` | kind 초기 계획 구분, EC2 중지와 destroy·결과 회수·공유 IAM·GHCR pull 권한 및 외부 파라미터 수명 정정 |
| `docs/README.md` | 원본 서비스 문서 진입점으로 유지. PoC 실행·결과는 루트 README에서 직접 연결 |
| `docs/TRACING_CONTRACT.md` | 애플리케이션 계약 문서. W3C propagator·MDC·application.yml의 설정 이름 대조. PoC OTLP 수집 실측으로 취급하지 않음 |
| `docs/troubleshooting/beach-deployment.md` | 과거 장애 이력 보존. 현재 결과 링크·당시 체크리스트 구분. Secret 값 대신 describe의 키/크기 확인으로 정정 |
| `docs/troubleshooting/k6-duration-option-collision.md` | BEACH_K6_DURATION·k6-job·rollout.js 및 #3 smoke 증거 대조. 과거 진단 명령은 역사적 예시로 유지 |
| `docs/troubleshooting/rollout-experiment.md` | raw_json 마커·logs 회수·timeout과 원격 복구 구분 대조. Redis 후속 실측 링크와 비교 범위 정정 |
| `deploy/k8s/app/README.md` | 기본 리소스·Secret·포트·Ingress 수동 절차 대조. 이미지 편집 cwd 및 선택적 Kustomize CLI 전제 명시 |
| `deploy/k8s/observability/README.md` | chart·resources·Grafana Secret·PodMonitor·PromQL 대조. HTTP 요청률 0일 때 NaN 예외와 측정 불가 의미 정정 |
| `deploy/k8s/README.md` | provision/bootstrap 단계·GHCR_USERNAME·JWT 재생성·이미지 편집 위치·삭제 cwd·3개 역할·버전 및 비용 표현 정정 |

## 로컬 계획 문서별 분류

위치는 원래 체크아웃의 `tempdocs/`이며 현재 worktree·Git에는 포함돼 있지 않다. 파일은 읽기·분류만 했고 원래 체크아웃을 수정하거나 계획을 현재 worktree로 복사하지 않았다. 표의 상대 경로는 다운로드 링크가 아니다. #1~#6·#8 외의 발표·지원서·분석 데모 계획과 Buzz 관련 파일은 이번 PoC 문서 정합성 검토 범위에서 제외한다.

| 로컬 경로 | 현재 문서와의 관계 |
| --- | --- |
| `issue-1/node-autoscaling.md` | 노드 자동확장 후속 계획(#13). 현재 구현·실측 성과로 취급하지 않음 |
| `issue-1/pr-1-iac-scaffold.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-1/pr-2-node-infrastructure.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-1/pr-3-node-bootstrap.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-1/pr-4-kubeadm-cilium.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-1/pr-5-recreate-and-docs.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-1/README.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-2/pr-1-image-ghcr.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-2/pr-2-workload.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-2/pr-3-service-ingress.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-2/pr-4-deploy-verify.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-2/README.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-3/pr-1-rollout-harness.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-3/pr-2-probe-shutdown-strategy.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-3/pr-3-ssm-s3-result-storage.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-3/pr-4-experiment-results.md` | 기본·조정 비교를 계획했으나 현재 #3 비교 범위는 제외. 기존 smoke를 비교 완료로 취급하지 않음 |
| `issue-3/pr-5-rollout-experiment.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-3/readiness-endpoint-validation.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-3/README.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-4/HPA_IMPLEMENTATION.md` | 실측 전·CPU250m 기록. 현재 CPU100m·baseline/load/stress/extreme 결과는 issue-4 결과 문서 참조 |
| `issue-4/pr-1-hpa-load-test.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-4/README.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-5/pr-1-kubelet-serving-cert.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-5/pr-2-metrics-server.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-5/pr-3-app-prometheus-metrics.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-5/pr-4-prometheus-grafana.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-5/pr-5-observability-evidence.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-5/README.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-6/pr-1-pod-failure-experiment.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-6/pr-2-node-failure-recovery.md` | 과거 설계·구현 계획. 현재 실행 명령/완료 상태는 이 저장소의 코드와 결과 문서를 우선 |
| `issue-6/README.md` | 필수 anti-affinity 설명은 현재 preferred와 다름. Node 실험은 후속, Pod 실측은 issue-6 결과 문서 참조 |
| `issue-8/pr-1-final-experiment-results.md` | 종합 문서 작성 전 계획. 최신 범위와 AC 대응은 issue-8 결과 문서 참조 |
| `issue-8/README.md` | 종합 문서 작성 전 계획. 최신 범위와 AC 대응은 issue-8 결과 문서 참조 |

## 확인한 근거와 검증의 경계

- Terraform: `deploy/k8s/terraform/environments/dev/main.tf`, `terraform.tfvars.example`, `modules/k8s_node/main.tf`. 실제 apply/plan/destroy는 실행하지 않았다.
- 배포·실험: `deploy/k8s/scripts/`의 provision, bootstrap, GHCR Secret, 앱/관측 설치, observability 검증, SSM 출력 회수 및 k6 실행 정의를 대조했다. 코드·셸·매니페스트는 수정하지 않았다.
- Markdown 파일의 상대 링크를 검사했다. 로컬 계획·cost·plan·roadmap의 끊어진 링크 14개는 Git 미포함 참고 경로임을 표시했다. 외부 URL 내용 전수 검증이나 모든 anchor 렌더링 검사는 아니다.
- #3·#5 공개 증거 8개 SHA-256이 문서와 일치했다. #4·#6 수치는 기존 상세 결과를 인용했고 전체 원본 재집계는 하지 않았다.
- 다이어그램의 SVG·PNG·PDF는 앞선 리뷰 반영본이다. PNG 육안 확인을 했으며 PDF 페이지·GitHub 화면 렌더링은 미확인이다.
- 새 환경 재현·실제 클러스터 실행·Node 장애·NetworkPolicy/Hubble·노드 자동확장은 검증하지 않았다. 문서 정적 검토 완료와 #8 전체 완료를 구분한다.

## 참고

- [#8 결과와 완료 기준 대응](README.md)
- [GitHub Container registry 인증·토큰 범위](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry)
- [Kubernetes 구성요소와 역할](https://kubernetes.io/docs/concepts/overview/components/)
- [EBS 볼륨의 인스턴스 종료 시 보존 여부](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/preserving-volumes-on-termination.html)
