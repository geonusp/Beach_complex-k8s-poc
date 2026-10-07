import http from 'k6/http';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const beachUrl = (__ENV.BEACH_URL || 'http://beach.beach.svc.cluster.local').replace(/\/$/, '');
const requestRate = Number(__ENV.K6_RATE || 1);
const duration = __ENV.K6_DURATION || '2m';

export const status5xx = new Counter('beach_status_5xx');
export const connectionFailures = new Counter('beach_connection_failures');

export const options = {
  scenarios: {
    rollout: {
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
  const response = http.get(`${beachUrl}/api/beaches`, {
    tags: { experiment: 'rollout', endpoint: 'beaches' },
  });

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
