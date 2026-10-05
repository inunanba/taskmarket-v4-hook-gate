import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { keccak256 } from 'viem';
import { fetchTaskSnapshot, parseTask } from '../src/taskmarket.mjs';
import { TASK, NOW, tmp, task, fakeFetch, rejectsCode } from './helpers.mjs';

const read = async (spec, extra = {}) => {
  const rawDir = tmp();
  const snap = await fetchTaskSnapshot({ taskId: TASK, rawDir, fetchImpl: fakeFetch(spec), now: () => NOW, ...extra });
  return { snap, rawDir };
};
const parse = (snap) => parseTask(snap, { expectedTaskId: TASK, now: () => NOW });

test('valid response parses to a minimal normalized view', async () => {
  const { snap } = await read({});
  assert.deepEqual(parse(snap), { id: TASK, status: 'completed', expiryMs: Date.parse('2026-10-08T06:41:32.275Z'), serverMs: Math.floor(NOW / 1000) * 1000 });
});

test('raw bytes and metadata are preserved BEFORE parsing, even for garbage', async () => {
  const raw = 'not json \u0000 at all';
  const { snap, rawDir } = await read({ raw });
  const files = readdirSync(rawDir).sort();
  assert.equal(files.length, 2);
  assert.equal(readFileSync(join(rawDir, files[0]), 'utf8'), raw);
  const meta = JSON.parse(readFileSync(join(rawDir, files[1]), 'utf8'));
  assert.equal(meta.keccak256, keccak256(new TextEncoder().encode(raw)));
  assert.equal(meta.httpStatus, 200);
  assert.equal(snap.evidenceHash, meta.keccak256);
  await rejectsCode(() => parse(snap), 'MALFORMED');
});

test('raw response is preserved for HTTP error statuses too', async () => {
  const { snap, rawDir } = await read({ status: 500, raw: 'upstream exploded' });
  assert.equal(readdirSync(rawDir).length, 2);
  await rejectsCode(() => parse(snap), 'API_ERROR');
});

for (const [status, code] of [[401, 'AUTH_REQUIRED'], [403, 'AUTH_REQUIRED'], [402, 'PAYMENT_REQUIRED'], [404, 'NOT_FOUND'], [429, 'API_ERROR'], [503, 'API_ERROR'], [301, 'API_ERROR']]) {
  test(`HTTP ${status} fails closed with ${code}`, async () => {
    const { snap } = await read({ status, raw: '{}' });
    await rejectsCode(() => parse(snap), code);
  });
}

test('network failure fails closed (API_ERROR)', async () => {
  await rejectsCode(read(new TypeError('fetch failed')), 'API_ERROR');
});

test('timeout fails closed (API_ERROR)', async () => {
  const hang = (_u, init) => new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(Object.assign(new Error('aborted'), { name: 'AbortError' }))));
  await rejectsCode(read(hang, { timeoutMs: 20 }), 'API_ERROR');
});

test('oversized body fails closed (API_ERROR)', async () => {
  await rejectsCode(read({ raw: 'x'.repeat(2048) }, { maxBytes: 1024 }), 'API_ERROR');
});

const malformed = {
  'non-JSON body': { raw: '<html>' },
  'invalid UTF-8': { raw: new Uint8Array([0x7b, 0xff, 0xfe, 0x7d]) },
  'JSON array': { raw: '[]' },
  'JSON null': { raw: 'null' },
  'JSON string': { raw: '"open"' },
  'wrong content-type': { headers: { 'content-type': 'text/html' } },
  'missing content-type': { headers: { 'content-type': undefined } },
  'non-string status': { body: task({ status: 3 }) },
  'id not hex32': { body: task({ id: 'TSK-6BHK4EGT' }) },
  'expiryTime not a date': { body: task({ expiryTime: 'tomorrow' }) },
  'numeric expiryTime': { body: task({ expiryTime: 1790000000 }) },
  'negative Age header': { headers: { age: '-1' } },
};
for (const [name, spec] of Object.entries(malformed)) {
  test(`malformed: ${name} -> MALFORMED`, async () => {
    const { snap } = await read(spec);
    await rejectsCode(() => parse(snap), 'MALFORMED');
  });
}

for (const field of ['id', 'status', 'expiryTime']) {
  test(`missing required field ${field} -> MISSING_FIELD`, async () => {
    const body = task();
    delete body[field];
    const { snap } = await read({ body });
    await rejectsCode(() => parse(snap), 'MISSING_FIELD');
  });
}

test('response for a different task -> MISMATCH', async () => {
  const { snap } = await read({ body: task({ id: `0x${'1'.repeat(64)}` }) });
  await rejectsCode(() => parse(snap), 'MISMATCH');
});

test('status outside the documented enum -> UNKNOWN_STATUS', async () => {
  const { snap } = await read({ body: task({ status: 'COMPLETED' }) });
  await rejectsCode(() => parse(snap), 'UNKNOWN_STATUS');
});

test('missing HTTP Date header -> UNVERIFIABLE_TIME', async () => {
  const { snap } = await read({ headers: { date: undefined } });
  await rejectsCode(() => parse(snap), 'UNVERIFIABLE_TIME');
});

test('server/local clock skew beyond limit -> STALE', async () => {
  const { snap } = await read({ headers: { date: new Date(NOW - 10 * 60_000).toUTCString() } });
  await rejectsCode(() => parse(snap), 'STALE');
});

test('cached response with large Age -> STALE', async () => {
  const { snap } = await read({ headers: { age: '3600' } });
  await rejectsCode(() => parse(snap), 'STALE');
});

test('input validation: bad task id, non-https API, missing rawDir', async () => {
  await rejectsCode(fetchTaskSnapshot({ taskId: 'TSK-6BHK4EGT', rawDir: tmp(), fetchImpl: fakeFetch({}) }), 'INVALID_INPUT');
  await rejectsCode(fetchTaskSnapshot({ taskId: TASK, rawDir: tmp(), apiBase: 'http://api.taskmarket.dev', fetchImpl: fakeFetch({}) }), 'CONFIG');
  await rejectsCode(fetchTaskSnapshot({ taskId: TASK, fetchImpl: fakeFetch({}) }), 'CONFIG');
});

test('request is a plain GET to /api/tasks/{id} with redirects refused', async () => {
  const f = fakeFetch({});
  await fetchTaskSnapshot({ taskId: TASK, rawDir: tmp(), fetchImpl: f, now: () => NOW });
  assert.equal(f.calls[0].url, `https://api.taskmarket.dev/api/tasks/${TASK}`);
  assert.equal(f.calls[0].init.method, 'GET');
  assert.equal(f.calls[0].init.redirect, 'error');
});
