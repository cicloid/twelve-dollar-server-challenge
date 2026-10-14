/**
 * bench/load.js plus bad requests. Same users, think times and pass thresholds, but on each
 * iteration a user also sends one bad request with probability ERR_PROB (default 0.3), picked
 * from the error cases in test/test.sh.
 *
 * A bad request passes only if it gets exactly the status and body the spec defines for it.
 * Any other status counts in http_req_failed, and any other body counts in error_contract_ok,
 * so a wrong 4xx, a 5xx, a 200 or a timeout all fail.
 *
 *   k6 run -e BASE_URL=http://10.0.0.5 -e VUS=8000 -e ERR_PROB=0.3 bench/load-errors.js
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Rate } from 'k6/metrics';
import crypto from 'k6/crypto';
import encoding from 'k6/encoding';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:3000';
const VUS = Number(__ENV.VUS || 100);
const LIKE_PROB = 0.15;
const POST_PROB = 0.02;
const ERR_PROB = Number(__ENV.ERR_PROB || 0.3);
const SECRET = __ENV.JWT_SECRET || 'twelve-dollar-challenge';
const tokens = new SharedArray('tokens', () => JSON.parse(open(__ENV.TOKENS || '../seed/tokens.json')));
const errorContractOk = new Rate('error_contract_ok');

export const options = {
  scenarios: {
    users: {
      executor: 'ramping-vus',
      stages: [
        { duration: __ENV.RAMP_UP || '60s', target: VUS },
        { duration: __ENV.DURATION || '5m', target: VUS },
        { duration: '30s', target: 0 },
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_duration: ['p(95)<500', 'p(99)<1000'],
    http_req_failed: ['rate<0.01'],
    error_contract_ok: ['rate>0.99'],
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

const between = (lo, hi) => lo + Math.random() * (hi - lo);
const pick = (a) => a[Math.floor(Math.random() * a.length)];

const NOT_FOUND = '{"error":"not found"}';
const INVALID_ID = '{"error":"invalid post id"}';
const POST_NOT_FOUND = '{"error":"post not found"}';
const MISSING_TOKEN = '{"error":"missing bearer token"}';
const INVALID_TOKEN = '{"error":"invalid or expired token"}';
const INVALID_PAYLOAD = '{"error":"invalid token payload"}';
const MALFORMED = '{"error":"malformed JSON body"}';
const BODY_REQUIRED = '{"error":"body is required"}';
const BODY_TOO_LONG = '{"error":"body must be at most 500 characters"}';

const b64 = (s) => encoding.b64encode(s, 'rawurl');
const HEADER = b64('{"alg":"HS256","typ":"JWT"}');
const sign = (claims) => {
  const head = `${HEADER}.${b64(JSON.stringify(claims))}`;
  return `${head}.${crypto.hmac('sha256', SECRET, head, 'base64rawurl')}`;
};

// One set of bad tokens per VU, built from its own user.
let bad;
function badTokens(user) {
  const now = Math.floor(Date.now() / 1000);
  const good = user.token;
  return {
    badSignature: `${good.slice(0, good.lastIndexOf('.'))}.c2lnbmF0dXJlLWlzLW5vdC12YWxpZC1hdC1hbGwtYXQtYWxsLTEyMzQ`,
    algNone: `${b64('{"alg":"none","typ":"JWT"}')}.${good.split('.')[1]}.`,
    expired: sign({ sub: String(user.id), username: user.username, iat: now - 7200, exp: now - 3600 }),
    badSub: sign({ sub: 'abc', username: user.username, iat: now, exp: now + 86400 }),
    noName: sign({ sub: String(user.id), iat: now, exp: now + 86400 }),
  };
}

// [name, method, path, Authorization header or null, raw body or null, status, exact body]
function errorCases(user) {
  const A = `Bearer ${user.token}`;
  return [
    ['unknown route', 'GET', '/nope', null, null, 404, NOT_FOUND],
    ['bad post id', 'GET', `/posts/${pick(['0', '-1', 'abc', '1.5'])}`, null, null, 400, INVALID_ID],
    ['missing post', 'GET', '/posts/999999999', null, null, 404, POST_NOT_FOUND],
    ['no token', 'POST', '/posts', null, '{"body":"x"}', 401, MISSING_TOKEN],
    ['basic auth', 'POST', '/posts', 'Basic abc', '{"body":"x"}', 401, MISSING_TOKEN],
    ['garbage token', 'POST', '/posts', 'Bearer abc', '{"body":"x"}', 401, INVALID_TOKEN],
    ['bad signature', 'POST', '/posts', `Bearer ${bad.badSignature}`, '{"body":"x"}', 401, INVALID_TOKEN],
    ['alg none', 'POST', '/posts', `Bearer ${bad.algNone}`, '{"body":"x"}', 401, INVALID_TOKEN],
    ['expired token', 'POST', '/posts', `Bearer ${bad.expired}`, '{"body":"x"}', 401, INVALID_TOKEN],
    ['sub not integer', 'POST', '/posts', `Bearer ${bad.badSub}`, '{"body":"x"}', 401, INVALID_PAYLOAD],
    ['no username', 'POST', '/posts', `Bearer ${bad.noName}`, '{"body":"x"}', 401, INVALID_PAYLOAD],
    ['like, no token', 'POST', '/posts/abc/like', null, null, 401, MISSING_TOKEN],
    ['empty body', 'POST', '/posts', A, pick(['{"body":""}', '{"body":"   "}', '{"body":123}', '{}']), 400, BODY_REQUIRED],
    ['malformed JSON', 'POST', '/posts', A, '{bad json', 400, MALFORMED],
    ['501-char body', 'POST', '/posts', A, `{"body":"${'a'.repeat(501)}"}`, 400, BODY_TOO_LONG],
    ['like missing post', 'POST', '/posts/999999999/like', A, null, 404, POST_NOT_FOUND],
    ['like bad id', 'POST', '/posts/abc/like', A, null, 400, INVALID_ID],
  ];
}

function sendBadRequest(user) {
  const [name, method, path, authz, body, status, want] = pick(errorCases(user));
  const headers = {};
  if (authz) headers.Authorization = authz;
  if (body !== null) headers['Content-Type'] = 'application/json';
  const r = http.request(method, `${BASE_URL}${path}`, body, {
    headers,
    tags: { name: `ERR ${name}` },
    responseCallback: http.expectedStatuses(status),
  });
  const ok = r.status === status && r.body === want;
  errorContractOk.add(ok, { case: name });
  check(r, { [`ERR ${name}: ${status} ${want}`]: () => ok });
}

export default function () {
  const user = tokens[(__VU - 1) % tokens.length];
  if (!bad) bad = badTokens(user);
  const auth = { headers: { Authorization: `Bearer ${user.token}`, 'Content-Type': 'application/json' } };
  if (__ITER === 0) sleep(between(0, 5)); // spread out VUs that start in the same tick

  const feed = http.get(`${BASE_URL}/feed`, { tags: { name: 'GET /feed' } });
  if (!check(feed, { 'feed 200': (r) => r.status === 200 })) { sleep(between(3, 7)); return; }
  const posts = feed.json('posts');
  const post = posts[Math.floor(Math.random() * posts.length)];
  sleep(between(3, 7));

  check(http.get(`${BASE_URL}/posts/${post.id}`, { tags: { name: 'GET /posts/:id' } }), { 'post 200': (r) => r.status === 200 });
  sleep(between(3, 8));

  if (Math.random() < LIKE_PROB) {
    const r = http.post(`${BASE_URL}/posts/${post.id}/like`, null, { ...auth, tags: { name: 'POST /posts/:id/like' } });
    check(r, { 'like 200/201': (r) => r.status === 200 || r.status === 201 });
  }
  if (Math.random() < POST_PROB) {
    const body = JSON.stringify({ body: `${user.username} says hi at ${new Date().toISOString()} (VU ${__VU}, iter ${__ITER})` });
    check(http.post(`${BASE_URL}/posts`, body, { ...auth, tags: { name: 'POST /posts' } }), { 'create 201': (r) => r.status === 201 });
  }
  if (Math.random() < ERR_PROB) sendBadRequest(user);
  sleep(between(5, 15));
}
