import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const beachUrl = (__ENV.BEACH_URL || 'http://beach.beach.svc.cluster.local').replace(/\/$/, '');
const requestRate = Number(__ENV.K6_RATE || 1);
const duration = __ENV.K6_DURATION || '2m';

// Rolling update 중에도 일정한 도착률로 Beach API를 호출해 배포 중 요청 실패를 관찰한다.
export const status5xx = new Counter('beach_status_5xx');
export const connectionFailures = new Counter('beach_connection_failures');

export const options = {
  scenarios: {
    rollout: {
      // VU 수가 아니라 초당 요청 수를 유지한다. 응답이 느려지면 k6가 VU를 늘려 요청률을 맞춘다.
      executor: 'constant-arrival-rate',
      rate: requestRate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: Number(__ENV.K6_PRE_ALLOCATED_VUS || 2),
      maxVUs: Number(__ENV.K6_MAX_VUS || 10),
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    beach_status_5xx: ['count==0'],
  },
};

export default function () {
  // 기본 대상은 클러스터 내부 Beach Service이며, 필요하면 BEACH_URL로 재정의한다.
  const response = http.get(`${beachUrl}/api/beaches`, {
    tags: { experiment: 'rollout', endpoint: 'beaches' },
  });

  // status 0은 HTTP 응답을 받지 못한 연결 실패, 500 이상은 서버 오류로 따로 센다.
  if (response.status === 0) {
    connectionFailures.add(1);
  } else if (response.status >= 500) {
    status5xx.add(1);
  }

  check(response, {
    'Beach API returned a response': (result) => result.status > 0,
    'Beach API did not return 5xx': (result) => result.status < 500,
  });
}

// SSM 실행 로그에서 요청률·기간·k6 지표를 한 덩어리 JSON으로 수집한다.
export function handleSummary(data) {
  return {
    stdout: `${JSON.stringify({
      experiment: 'rollout',
      beachUrl,
      requestRate,
      duration,
      metrics: data.metrics,
    })}\n`,
  };
}
