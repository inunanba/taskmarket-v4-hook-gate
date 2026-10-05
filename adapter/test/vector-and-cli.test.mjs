import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { makeVector } from '../scripts/gen-vector.mjs';
import { poolIdFromKey } from '../src/binding.mjs';
import { TASK, tmp, task } from './helpers.mjs';

const run = promisify(execFile);
const CLI = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));

test('committed Solidity fixture equals a fresh deterministic regeneration', async () => {
  const committed = JSON.parse(readFileSync(new URL('../../test/fixtures/adapter-vector.json', import.meta.url), 'utf8'));
  assert.deepEqual(await makeVector(), committed);
});

test('poolIdFromKey matches the fixture PoolId (v4 keccak256(abi.encode(PoolKey)))', async () => {
  const v = await makeVector();
  assert.equal(poolIdFromKey(v.poolKey), v.poolId);
});

async function cli(args, env = {}) {
  try {
    const { stdout } = await run(process.execPath, [CLI, ...args], { env: { PATH: process.env.PATH, ...env } });
    return { code: 0, out: JSON.parse(stdout) };
  } catch (e) {
    return { code: e.code, out: JSON.parse(e.stdout) };
  }
}

test('CLI: missing ADAPTER_PRIVATE_KEY exits 1 with ok:false and no hookData', async () => {
  const r = await cli(['authorize', '--task', TASK, '--status', 'completed']);
  assert.equal(r.code, 1);
  assert.equal(r.out.ok, false);
  assert.equal(r.out.code, 'CONFIG');
  assert.equal(r.out.hookData, undefined);
});

test('CLI: probe against a local Taskmarket-shaped server preserves raw and validates', async () => {
  const srv = createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'application/json', date: new Date().toUTCString() });
    res.end(JSON.stringify(task({ status: 'open' })));
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const { port } = srv.address();
  try {
    const r = await cli(['probe', '--task', TASK, '--api', `http://127.0.0.1:${port}`, '--allow-insecure-local', '--raw-dir', tmp()]);
    assert.equal(r.code, 0);
    assert.equal(r.out.task.status, 'open');
    assert.match(r.out.evidenceHash, /^0x[0-9a-f]{64}$/);
  } finally {
    srv.close();
  }
});

test('CLI: probe against a server returning 402 fails closed (no payment attempted)', async () => {
  const srv = createServer((req, res) => {
    res.writeHead(402, { 'content-type': 'application/json', date: new Date().toUTCString(), 'payment-required': 'x402' });
    res.end('{}');
  });
  await new Promise((r) => srv.listen(0, '127.0.0.1', r));
  const { port } = srv.address();
  try {
    const r = await cli(['probe', '--task', TASK, '--api', `http://127.0.0.1:${port}`, '--allow-insecure-local', '--raw-dir', tmp()]);
    assert.equal(r.code, 1);
    assert.equal(r.out.code, 'PAYMENT_REQUIRED');
  } finally {
    srv.close();
  }
});
