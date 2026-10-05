import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { decodeAbiParameters, keccak256, recoverTypedDataAddress } from 'viem';
import { authorize, revokeIfDrifted } from '../src/authorize.mjs';
import { BINDING_TYPES, domain } from '../src/binding.mjs';
import { TASK, HOOK, POOL, ACTOR, NOW, tmp, task, fakeFetch, spyAccount, fakeReader, rejectsCode } from './helpers.mjs';

const base = (over = {}) => ({
  taskId: TASK,
  requiredStatus: 'completed',
  poolId: POOL,
  actor: ACTOR,
  actions: 1,
  chainId: 46630,
  hook: HOOK,
  rawDir: tmp(),
  now: () => NOW,
  fetchImpl: fakeFetch({}),
  account: spyAccount(),
  ...over,
});

test('offline happy path: signed binding, canonical hookData, evidence = keccak(raw bytes of the re-fetch)', async () => {
  const o = base({ epoch: 3n, nonce: 9n });
  const r = await authorize(o);
  assert.equal(r.ok, true);
  assert.equal(o.fetchImpl.calls.length, 2, 'fetch + re-fetch before signing');
  assert.equal(r.evidence.length, 2);
  assert.equal(r.binding.epoch, '3');
  assert.equal(r.binding.observedAt, String(Math.floor(NOW / 1000)));
  assert.equal(r.binding.expiry, String(Math.floor(NOW / 1000) + 300));
  assert.equal(r.evidenceHash, keccak256(readFileSync(r.evidence[1])));
  assert.equal((r.hookData.length - 2) / 2, 576, 'matches TaskGateHook.HOOKDATA_LENGTH');
  const [b, sig] = decodeAbiParameters([{ type: 'tuple', components: BINDING_TYPES.TaskBinding }, { type: 'bytes' }], r.hookData);
  const signer = await recoverTypedDataAddress({ domain: domain(46630, HOOK), types: BINDING_TYPES, primaryType: 'TaskBinding', message: b, signature: sig });
  assert.equal(signer, o.account.address);
  assert.equal(readdirSync(o.rawDir).length, 4, 'two bodies + two meta files preserved');
});

test('online: reads epoch/maxTtl from hook, previews on-chain, writes after a THIRD fetch', async () => {
  let submitted = 0;
  const o = base({
    ttlSec: 5000,
    reader: fakeReader(),
    writer: { submitBinding: async () => { submitted++; return { txHash: '0xabc', outcome: 'updated' }; } },
  });
  const r = await authorize(o);
  assert.equal(r.binding.epoch, '7');
  assert.equal(Number(r.binding.expiry) - Number(r.binding.observedAt), 900, 'capped by hook maxTtl');
  assert.equal(r.preview, 'OK');
  assert.equal(o.fetchImpl.calls.length, 3);
  assert.equal(submitted, 1);
  assert.equal(r.txHash, '0xabc');
});

test('observedAt is clamped to the chain head so the hook never sees a future observation', async () => {
  const head = Math.floor(NOW / 1000) - 7;
  const r = await authorize(base({ reader: fakeReader({ blockTimestamp: async () => BigInt(head) }) }));
  assert.equal(r.binding.observedAt, String(head));
});

test('open task: binding expiry is capped by the task expiryTime', async () => {
  const exp = new Date(NOW + 60_000).toISOString();
  const r = await authorize(base({ requiredStatus: 'open', epoch: 1n, fetchImpl: fakeFetch({ body: task({ status: 'open', expiryTime: exp }) }) }));
  assert.equal(r.binding.expiry, String(Math.floor(Date.parse(exp) / 1000)));
});

test('wrong task status -> WRONG_STATUS and nothing is signed', async () => {
  const o = base({ epoch: 1n, fetchImpl: fakeFetch({ body: task({ status: 'review' }) }) });
  await rejectsCode(authorize(o), 'WRONG_STATUS');
  assert.equal(o.account.signs, 0);
});

test('expired active task -> TASK_EXPIRED', async () => {
  const o = base({ requiredStatus: 'open', epoch: 1n, fetchImpl: fakeFetch({ body: task({ status: 'open', expiryTime: new Date(NOW - 1000).toISOString() }) }) });
  await rejectsCode(authorize(o), 'TASK_EXPIRED');
  assert.equal(o.account.signs, 0);
});

test('state changes between the read and the re-fetch -> STALE_STATE, nothing signed', async () => {
  const o = base({ epoch: 1n, fetchImpl: fakeFetch({}, { body: task({ status: 'disputed' }) }) });
  await rejectsCode(authorize(o), 'STALE_STATE');
  assert.equal(o.account.signs, 0);
});

test('re-fetch failure (API down) -> API_ERROR, nothing signed', async () => {
  const o = base({ epoch: 1n, fetchImpl: fakeFetch({}, { status: 502, raw: 'bad gateway' }) });
  await rejectsCode(authorize(o), 'API_ERROR');
  assert.equal(o.account.signs, 0);
});

test('state changes right before the write -> STALE_STATE, writer never called', async () => {
  let called = 0;
  const o = base({
    reader: fakeReader(),
    writer: { submitBinding: async () => { called++; return { outcome: 'updated' }; } },
    fetchImpl: fakeFetch({}, {}, { body: task({ status: 'cancelled' }) }),
  });
  await rejectsCode(authorize(o), 'STALE_STATE');
  assert.equal(called, 0);
});

test('RPC on the wrong chain -> WRONG_CHAIN', async () => {
  await rejectsCode(authorize(base({ reader: fakeReader({ chainId: async () => 4663 }) })), 'WRONG_CHAIN');
});

test('pool not allowlisted or status mismatch on the hook -> HOOK_CONFIG_MISMATCH', async () => {
  const cfg = await fakeReader().poolConfig();
  await rejectsCode(authorize(base({ reader: fakeReader({ poolConfig: async () => ({ ...cfg, allowed: false }) }) })), 'HOOK_CONFIG_MISMATCH');
  await rejectsCode(authorize(base({ reader: fakeReader({ poolConfig: async () => ({ ...cfg, requiredStatus: keccak256('0x01') }) }) })), 'HOOK_CONFIG_MISMATCH');
  await rejectsCode(authorize(base({ reader: fakeReader({ poolConfig: async () => ({ ...cfg, requiredTaskId: keccak256('0x02') }) }) })), 'HOOK_CONFIG_MISMATCH');
});

test('signer not authorized on the hook -> UNAUTHORIZED_ADAPTER', async () => {
  await rejectsCode(authorize(base({ reader: fakeReader({ isAdapter: async () => false }) })), 'UNAUTHORIZED_ADAPTER');
});

test('hook preview returns a non-OK reason -> HOOK_REJECTED (no write)', async () => {
  let called = 0;
  const o = base({ reader: fakeReader({ previewBinding: async () => ({ reason: 18 }) }), writer: { submitBinding: async () => { called++; } } });
  const e = await rejectsCode(authorize(o), 'HOOK_REJECTED');
  assert.match(e.message, /NONCE_USED/);
  assert.equal(called, 0);
});

test('on-chain BindingRejected outcome -> HOOK_REJECTED', async () => {
  const o = base({ reader: fakeReader(), writer: { submitBinding: async () => ({ txHash: '0x1', outcome: 'rejected', reason: 13 }) } });
  const e = await rejectsCode(authorize(o), 'HOOK_REJECTED');
  assert.match(e.message, /STALE/);
});

test('configuration errors fail before any network call', async () => {
  const f = fakeFetch({});
  await rejectsCode(authorize(base({ account: undefined, fetchImpl: f })), 'CONFIG');
  await rejectsCode(authorize(base({ requiredStatus: 'done', fetchImpl: f })), 'INVALID_INPUT');
  await rejectsCode(authorize(base({ poolId: undefined, fetchImpl: f })), 'INVALID_INPUT');
  assert.equal(f.calls.length, 0);
  await rejectsCode(authorize(base({})), 'CONFIG'); // offline without epoch
});

test('invalid binding inputs are refused (actor zero)', async () => {
  await rejectsCode(authorize(base({ epoch: 1n, actor: '0x0000000000000000000000000000000000000000' })), 'INVALID_INPUT');
});

test('revokeIfDrifted keeps the grant while state is valid', async () => {
  let revoked = 0;
  const r = await revokeIfDrifted(base({ writer: { revokeGrant: async () => { revoked++; return {}; } } }));
  assert.equal(r.action, 'kept');
  assert.equal(revoked, 0);
});

test('revokeIfDrifted revokes when the task leaves the required status', async () => {
  const r = await revokeIfDrifted(base({ fetchImpl: fakeFetch({ body: task({ status: 'disputed' }) }), writer: { revokeGrant: async () => ({ txHash: '0x2' }) } }));
  assert.deepEqual([r.action, r.reason, r.txHash], ['revoked', 'WRONG_STATUS', '0x2']);
});

test('revokeIfDrifted revokes when state is unverifiable (fail closed)', async () => {
  const r = await revokeIfDrifted(base({ fetchImpl: fakeFetch({ status: 503, raw: '' }), writer: { revokeGrant: async () => ({ txHash: '0x3' }) } }));
  assert.deepEqual([r.action, r.reason], ['revoked', 'API_ERROR']);
});

test('no secret material in results', async () => {
  const r = await authorize(base({ epoch: 1n }));
  assert.doesNotMatch(JSON.stringify(r), /a11ce$/i);
  assert.equal(JSON.stringify(r).includes('00000000000000000000000000000000000000000000000000000000000a11ce'), false);
});
