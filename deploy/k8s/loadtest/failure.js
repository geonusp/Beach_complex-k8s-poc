import http from 'k6/http';
import { Counter } from 'k6/metrics';

const status5xx = new Counter('beach_status_5xx');
const connectionFailures = new Counter('beach_connection_failures');
export const options = {
  summaryTrendStats: ['avg', 'p(95)', 'p(99)'],
  scenarios: {
    failure: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.K6_RATE || 5),
      timeUnit: '1s',
      duration: __ENV.BEACH_K6_DURATION || '420s',
      preAllocatedVUs: 30,
      maxVUs: 30,
    },
  },
};

export default function () {
  const response = http.get('http://beach.beach.svc.cluster.local/api/beaches', {
    timeout: '5s', tags: { experiment: 'failure', endpoint: 'beaches' },
  });
  status5xx.add(response.status >= 500 ? 1 : 0);
  connectionFailures.add(response.status === 0 ? 1 : 0);
}
