// SPDX-License-Identifier: MIT
// Read-only Taskmarket client. Every response is UNTRUSTED: bytes are preserved on disk before any parsing, then
// validated strictly. References: https://docs.taskmarket.dev/api/reference , https://docs.taskmarket.dev/reference/raw-api
import { createHash, randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { keccak256 } from 'viem';
import { fail } from './errors.mjs';

export const DEFAULT_API_BASE = 'https://api.taskmarket.dev';

/** Task statuses documented in the Taskmarket OpenAPI schema. Anything else is UNKNOWN_STATUS. */
export const TASK_STATUSES = Object.freeze([
  'open', 'claimed', 'worker_selected', 'pending_approval', 'review',
  'appealing', 'disputed', 'completed', 'expired', 'cancelled',
]);
/** Statuses during which the task's own expiryTime still matters (binding expiry is capped by it). */
export const ACTIVE_STATUSES = Object.freeze(['open', 'claimed', 'worker_selected', 'pending_approval', 'review']);

const TASK_ID_RE = /^0x[0-9a-fA-F]{64}$/;

export function assertTaskId(taskId) {
  if (typeof taskId !== 'string' || !TASK_ID_RE.test(taskId)) fail('INVALID_INPUT', 'taskId must be 0x + 64 hex chars');
  return taskId.toLowerCase();
}

/**
 * GET /api/tasks/{taskId}. Writes `<rawDir>/<stamp>.body` (exact bytes) and `<stamp>.meta.json` BEFORE parsing,
 * including for error statuses, so every decision can be audited against what the API actually returned.
 */
export async function fetchTaskSnapshot({
  taskId,
  apiBase = DEFAULT_API_BASE,
  rawDir,
  fetchImpl = globalThis.fetch,
  timeoutMs = 10_000,
  maxBytes = 1_000_000,
  now = () => Date.now(),
  allowInsecureLocal = false,
}) {
  const id = assertTaskId(taskId);
  if (!rawDir) fail('CONFIG', 'rawDir is required (raw responses must be preserved)');
  let url;
  try {
    url = new URL(`/api/tasks/${id}`, apiBase);
  } catch {
    fail('INVALID_INPUT', `bad apiBase ${apiBase}`);
  }
  const local = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(allowInsecureLocal && local)) fail('CONFIG', 'apiBase must be https');

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  let res;
  let bytes;
  try {
    res = await fetchImpl(url.toString(), { method: 'GET', headers: { accept: 'application/json' }, signal: ctrl.signal, redirect: 'error' });
    const declared = Number(res.headers.get('content-length') ?? '0');
    if (declared > maxBytes) fail('API_ERROR', `response too large (${declared} bytes)`);
    bytes = new Uint8Array(await res.arrayBuffer());
  } catch (e) {
    if (e?.name === 'AdapterError') throw e;
    fail('API_ERROR', `request failed: ${e?.name === 'AbortError' ? 'timeout' : e?.message ?? e}`);
  } finally {
    clearTimeout(timer);
  }
  const receivedAt = now();
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const evidenceHash = keccak256(bytes);
  const stamp = `${new Date(receivedAt).toISOString().replace(/[:.]/g, '-')}-${id.slice(2, 10)}-${randomBytes(3).toString('hex')}`;
  await mkdir(rawDir, { recursive: true });
  const bodyPath = join(rawDir, `${stamp}.body`);
  const meta = {
    url: url.toString(),
    httpStatus: res.status,
    receivedAt: new Date(receivedAt).toISOString(),
    headers: pickHeaders(res.headers),
    sizeBytes: bytes.length,
    sha256,
    keccak256: evidenceHash,
    note: 'Untrusted Taskmarket response, preserved byte-for-byte before parsing.',
  };
  await writeFile(bodyPath, bytes, { flag: 'wx' });
  await writeFile(join(rawDir, `${stamp}.meta.json`), JSON.stringify(meta, null, 2), { flag: 'wx' });
  if (bytes.length > maxBytes) fail('API_ERROR', `response too large (${bytes.length} bytes)`, { rawPath: bodyPath });
  return { url: url.toString(), httpStatus: res.status, headers: meta.headers, bytes, receivedAt, sha256, evidenceHash, rawPath: bodyPath };
}

function pickHeaders(h) {
  const out = {};
  for (const k of ['content-type', 'date', 'age', 'cache-control', 'etag', 'last-modified', 'payment-required']) {
    const v = h.get(k);
    if (v !== null) out[k] = v;
  }
  return out;
}

/** Strictly validate a snapshot. Returns a minimal normalized view or throws AdapterError. */
export function parseTask(snapshot, { expectedTaskId, now = () => Date.now(), maxClockSkewMs = 120_000, maxAgeSec = 60 } = {}) {
  const want = assertTaskId(expectedTaskId);
  const s = snapshot.httpStatus;
  const ctx = { rawPath: snapshot.rawPath };
  if (s === 401 || s === 403) fail('AUTH_REQUIRED', `HTTP ${s}: credentials required; none are configured or invented`, ctx);
  if (s === 402) fail('PAYMENT_REQUIRED', 'HTTP 402: X402-protected route; the adapter never pays or bypasses', ctx);
  if (s === 404) fail('NOT_FOUND', 'task not found', ctx);
  if (s < 200 || s > 299) fail('API_ERROR', `HTTP ${s}`, ctx);

  const ct = snapshot.headers['content-type'] ?? '';
  if (!/^application\/json(\s*;|$)/i.test(ct)) fail('MALFORMED', `content-type ${ct || '(none)'}`, ctx);

  const dateHdr = snapshot.headers.date;
  const serverMs = dateHdr ? Date.parse(dateHdr) : NaN;
  if (!Number.isFinite(serverMs)) fail('UNVERIFIABLE_TIME', 'missing or invalid HTTP Date header', ctx);
  if (Math.abs(now() - serverMs) > maxClockSkewMs) fail('STALE', `server Date differs from local clock by ${Math.round((now() - serverMs) / 1000)}s`, ctx);
  if (snapshot.headers.age !== undefined) {
    const age = Number(snapshot.headers.age);
    if (!Number.isInteger(age) || age < 0) fail('MALFORMED', 'invalid Age header', ctx);
    if (age > maxAgeSec) fail('STALE', `cached response Age ${age}s > ${maxAgeSec}s`, ctx);
  }

  let body;
  try {
    body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(snapshot.bytes));
  } catch {
    fail('MALFORMED', 'body is not valid UTF-8 JSON', ctx);
  }
  if (body === null || typeof body !== 'object' || Array.isArray(body)) fail('MALFORMED', 'body is not a JSON object', ctx);

  if (!('id' in body)) fail('MISSING_FIELD', 'id', ctx);
  if (typeof body.id !== 'string' || !TASK_ID_RE.test(body.id)) fail('MALFORMED', 'id is not a 32-byte hex string', ctx);
  if (body.id.toLowerCase() !== want) fail('MISMATCH', `response id ${body.id} != requested ${want}`, ctx);

  if (!('status' in body)) fail('MISSING_FIELD', 'status', ctx);
  if (typeof body.status !== 'string') fail('MALFORMED', 'status is not a string', ctx);
  if (!TASK_STATUSES.includes(body.status)) fail('UNKNOWN_STATUS', JSON.stringify(body.status).slice(0, 64), ctx);

  if (!('expiryTime' in body)) fail('MISSING_FIELD', 'expiryTime', ctx);
  if (typeof body.expiryTime !== 'string' || !Number.isFinite(Date.parse(body.expiryTime))) fail('MALFORMED', 'expiryTime is not an ISO date string', ctx);

  return { id: want, status: body.status, expiryMs: Date.parse(body.expiryTime), serverMs };
}
