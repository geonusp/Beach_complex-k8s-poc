# readiness 그룹의 외부 의존성 포함 정책과 실패 재현 방법

## 상태

Proposed — 논의 중. 이슈 #3 PR 2 착수 전에 확정한다.

## 컨텍스트

이슈 #3의 작업 중 하나는 "readiness 실패 Pod가 Service endpoint에서 제외되는지 확인"이다.
확인하려면 실행 중인 Beach Pod의 readiness를 의도적으로 실패시켜야 한다.

현재 구성의 제약은 다음과 같다.

- readiness probe는 `/actuator/health/readiness`(management 포트 8081)를 본다.
  Spring Boot 기본 readiness 그룹은 `readinessState`만 포함하므로, 외부 의존성이 죽어도 readiness는 실패하지 않는다.
- 실행 중인 Pod의 probe 설정은 바꿀 수 없다. 바꾸면 Pod가 새로 만들어진다.
- 애플리케이션 상태(`AvailabilityState`)를 외부에서 바꾸는 엔드포인트가 없다.
- `/api/beaches`의 캐시는 Redis가 아니라 Caffeine(프로세스 내부)이다(`spring.cache.type: caffeine`).
  즉 Redis가 없어도 이 API는 응답할 수 있다.
- PostgreSQL·Redis는 영속 볼륨 없는 임시 Deployment다([Ephemeral 의존성 배치](./ephemeral-dependency-placement.md)).
  PostgreSQL을 내리면 데이터가 사라진다.

여기서 결정할 것은 두 가지다. 이 둘은 이슈 #3의 실험 방법이면서 동시에 **운영 시 장애 동작**을 정한다.
readiness에 외부 의존성을 넣으면, 그 의존성의 장애가 모든 Pod의 endpoint 제외, 즉 전체 서비스 중단으로 이어진다.
이슈 #6(장애 복구 실험)도 이 동작을 전제로 설계되므로 여러 이슈에 걸친다.

1. 기본(상시) readiness 그룹에 외부 의존성을 포함할지
2. 이슈 #3에서 readiness 실패를 어떻게 재현할지

## 결정

**제안: 기본 readiness 그룹은 지금처럼 `readinessState`만 유지한다. 실험할 때만 환경변수로 Redis를 readiness 그룹에 넣고, Redis를 잠시 0으로 줄여 재현한다.**

- `application.yml`의 readiness 그룹은 바꾸지 않는다.
- 실험 시에만 Deployment에 다음 환경변수를 넣는다. Spring Boot의 relaxed binding으로 `management.endpoint.health.group.readiness.include`에 대응한다.

  ```text
  MANAGEMENT_ENDPOINT_HEALTH_GROUP_READINESS_INCLUDE=readinessState,redis
  ```

- 재현 순서: 환경변수 적용 → Ready 2 확인 → Redis `replicas: 0` → endpoint 제외 기록 → Redis 복구 → endpoint 복귀 기록 → 환경변수 제거.
- liveness 그룹에는 어떤 외부 의존성도 넣지 않는다. 의존성 장애가 컨테이너 재시작 연쇄로 번지지 않게 한다.

### 범위 제외

- 애플리케이션 코드에 상태 변경 엔드포인트 추가
- PostgreSQL을 내려서 재현하는 방식(데이터 유실)
- 특정 Pod 하나만 endpoint에서 빠지는 재현(아래 선택지 3 참고)

## 근거

- Redis가 없어도 `/api/beaches`는 응답할 수 있다. 상시 readiness에 Redis를 넣으면, 처리할 수 있는 요청까지 Redis 장애 때문에 전부 막는다.
  Spring Boot 문서도 readiness에 외부 시스템을 넣을 때 그 장애가 모든 인스턴스를 동시에 빼낼 수 있다고 경고한다.
- 환경변수 방식은 코드 변경이 없고, 실험이 끝나면 원래 정책으로 돌아간다.
- Redis는 캐시 용도의 임시 의존성이라 내려도 잃는 데이터가 없다. PostgreSQL은 그렇지 않다.

## 결과

### 긍정적 영향

- 상시 장애 동작은 지금과 같다. Redis 장애가 전체 서비스 중단으로 번지지 않는다.
- 애플리케이션 코드와 보안 범위가 늘지 않는다.
- 이슈 #6에서 "의존성 장애 시 readiness가 어떻게 동작해야 하는가"를 같은 방식으로 다시 실험할 수 있다.

### 부정적 영향

- 환경변수를 넣고 빼는 과정에서 Rolling Update가 두 번 일어난다. 이 동안의 측정은 Rolling Update 실험 결과와 섞지 않는다.
- Pod 2개가 **동시에** endpoint에서 빠진다. "일부 Pod만 빠지고 나머지가 요청을 받는다"는 시나리오는 확인하지 못한다.
- 실험 중에는 Service endpoint가 0개가 되어 모든 요청이 실패한다. 이 구간은 Rolling Update 측정과 겹치지 않게 분리한다.

## 대안

### 선택지 1: 상시 readiness 그룹에 Redis 포함 (`application.yml` 수정)

- 장점: 설정 1줄. 실험 때 환경변수를 바꿀 필요가 없다.
- 단점: Redis가 필요 없는 요청까지 Redis 장애 때문에 막힌다. 실험 편의를 위해 운영 장애 동작을 바꾸는 셈이다.
- 결론: 기각. 처음 제안했던 안이지만, `/api/beaches` 캐시가 Caffeine이라는 점을 확인하고 기각했다.

### 선택지 2: 디버그용 상태 변경 엔드포인트 추가

- 장점: 특정 Pod 하나만 readiness를 실패시킬 수 있다. 의존성을 건드리지 않는다.
- 단점: 애플리케이션 코드, 인증·노출 범위 검토가 필요하다. management 포트에만 노출하더라도 운영 이미지에 장애 주입 기능이 들어간다.
- 결론: 보류. 단일 Pod 제외 확인이 꼭 필요해지면 다시 검토한다.

### 선택지 3: 실험용 환경변수 + 특정 Pod의 Redis 통신만 NetworkPolicy로 차단

- 장점: 코드 변경 없이 Pod 하나만 endpoint에서 빠지는 상황을 만든다.
- 단점: Cilium의 NetworkPolicy 적용을 전제로 한다. NetworkPolicy는 이슈 #7의 범위이고, 정책 설계 전에 쓰면 원인 후보가 늘어난다.
- 결론: 이슈 #7 이후 추가 실험으로 둔다.

### 선택지 4: readiness 파일을 쓰는 별도 테스트 워크로드

- 장점: `exec` probe와 `kubectl exec`로 Pod별 readiness를 자유롭게 바꿀 수 있다.
- 단점: Beach가 아닌 워크로드로 Kubernetes의 일반 동작만 보여준다. 이슈의 대상이 Beach 애플리케이션이다.
- 결론: 기각.

## 검증 계획

1. 환경변수 적용 후 `/actuator/health/readiness` 응답에 `redis` 구성요소가 포함되는지 확인한다.
2. Redis를 0으로 줄인 뒤 Beach Pod가 `Ready=False`가 되고 `EndpointSlice`의 ready 주소가 0이 되는지 기록한다.
3. 같은 구간에 Beach Pod의 재시작 횟수가 늘지 않는지 확인한다(liveness는 영향 없어야 함).
4. Redis 복구 후 ready 주소가 2로 돌아오는 데 걸린 시간을 기록한다.
5. 환경변수 제거 후 readiness 응답에서 `redis`가 빠졌는지 확인한다.

## 롤백 / 재검토 기준

- Redis가 캐시 이외의 필수 기능(예: 세션, 토큰 저장)에 쓰이고 있음이 확인되면, 상시 readiness 포함 여부를 다시 판단한다.
- 단일 Pod 제외 확인이 이슈 #6의 완료 기준이 되면 선택지 2 또는 3을 다시 검토한다.

## 참고

### 공식 문서 링크

- [Spring Boot Kubernetes probes](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html#actuator.endpoints.kubernetes-probes)
- [Spring Boot — probes와 외부 상태](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html#actuator.endpoints.kubernetes-probes.external-state)
- [Spring Boot health groups](https://docs.spring.io/spring-boot/reference/actuator/endpoints.html#actuator.endpoints.health.groups)
- [Kubernetes liveness, readiness, startup probe](https://kubernetes.io/docs/concepts/configuration/liveness-readiness-startup-probes/)
- [Kubernetes EndpointSlice](https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/)

### 관련 이슈 / PR

- 이슈 #3 Probe 및 Rolling Update 사용자 영향 검증 — 작업 10
- 이슈 #6 Pod 및 App Worker Node 장애 복구 실험
- 이슈 #7 Cilium 및 Hubble 기반 NetworkPolicy 장애 분석

### 관련 문서

- [Ephemeral 의존성 배치](./ephemeral-dependency-placement.md)
- [이슈 #3 구현 문서](../../tempdocs/issue-3/README.md)

## 작성일자

2026-10-07
