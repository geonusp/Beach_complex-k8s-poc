import http from 'k6/http';
import { check } from 'k6';

const profile = __ENV.HPA_PROFILE;
const rate = Number(__ENV.K6_RATE);
const duration = profile === 'smoke' ? '60s' : profile === 'baseline' ? '300s' : '600s';
if (!['smoke', 'baseline', 'load', 'stress'].includes(profile) || !Number.isInteger(rate) || rate < 1 || rate > 200) {
  throw new Error('Expected smoke/baseline/load/stress and an integer K6_RATE in 1..200');
}
http.setResponseCallback(http.expectedStatuses(200));

export const options = {
  summaryTrendStats: ['med', 'p(95)', 'p(99)', 'max'],
  scenarios: {
    hpa: {
      executor: 'constant-arrival-rate',
      rate,
      timeUnit: '1s',
      duration,
      preAllocatedVUs: 10,
      maxVUs: 50,
      gracefulStop: '10s',
    },
  },
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '30s' }],
    http_req_duration: [{ threshold: 'p(95)<2000', abortOnFail: true, delayAbortEval: '30s' }],
    dropped_iterations: ['count==0'],
  },
};

export default function () {
  const response = http.get('http://beach.beach.svc.cluster.local/api/beaches', {
    timeout: '5s',
    tags: { experiment: 'hpa', profile },
  });
  check(response, { 'Beach API returned 200': (r) => r.status === 200 });
}

export function handleSummary(data) {
  return { stdout: `${JSON.stringify({ experiment: 'hpa', profile, rate, duration, metrics: data.metrics })}\n` };
}
