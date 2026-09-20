# Kubernetes 노드 리소스는 후속 PR에서 k8s_node 모듈 호출로 추가한다.
# 이 PR은 루트 모듈의 구조와 검증 경로만 만든다.
#
# 관측 서버 IaC(deploy/observability)와 모듈을 공유하지 않고 별도 트리로 둔다.
# 판단 근거는 docs/adr/k8s-execution-environment.md를 따른다.
