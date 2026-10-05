// SPDX-License-Identifier: MIT
// Orchestration: read Taskmarket -> validate -> read hook config -> RE-FETCH -> compare -> sign -> preview on-chain
// -> (optional) RE-FETCH again immediately before the write -> submitBinding. Any failure throws; nothing is signed or
// sent after a failure (fail closed).
import { randomBytes } from 'node:crypto';
import { fetchTaskSnapshot, parseTask, assertTaskId, ACTIVE_STATUSES, TASK_STATUSES } from './taskmarket.mjs';
import { buildBinding, signBinding, hashBinding, encodeHookData, statusHash, poolIdFromKey, REASONS, toJson } from './binding.mjs';
import { fail } from './errors.mjs';

function sameTask(a, b) {
  return a.id === b.id && a.status === b.status && a.expiryMs === b.expiryMs;
}

async function readTask(opts) {
  const snap = await fetchTaskSnapshot(opts);
  const task = parseTask(snap, { expectedTaskId: opts.taskId, now: opts.now, maxClockSkewMs: opts.maxClockSkewMs, maxAgeSec: opts.maxAgeSec });
  return { snap, task };
}

function checkStatus(task, requiredStatus, nowMs) {
  if (task.status !== requiredStatus) fail('WRONG_STATUS', `task is "${task.status}", pool requires "${requiredStatus}"`);
  if (ACTIVE_STATUSES.includes(task.status) && task.expiryMs <= nowMs) fail('TASK_EXPIRED', 'task expiryTime has passed');
}

export async function authorize(input) {
  const o = { now: () => Date.now(), maxUses: 1, ttlSec: 300, ...input };
  assertTaskId(o.taskId);
  if (!TASK_STATUSES.includes(o.requiredStatus)) fail('INVALID_INPUT', `requiredStatus must be one of ${TASK_STATUSES.join(',')}`);
  if (!o.account) fail('CONFIG', 'adapter signing account is required (ADAPTER_PRIVATE_KEY, testnet only)');
  if (!Number.isInteger(o.ttlSec) || o.ttlSec <= 0) fail('INVALID_INPUT', 'ttlSec must be a positive integer');
  const poolId = o.poolId ?? (o.poolKey ? poolIdFromKey(o.poolKey) : fail('INVALID_INPUT', 'poolId or poolKey required'));
  const evidence = [];

  // 1. first read
  const first = await readTask(o);
  evidence.push(first.snap.rawPath);
  checkStatus(first.task, o.requiredStatus, o.now());

  // 2. on-chain configuration (source of truth for epoch / limits), when an RPC reader is available
  let epoch = o.epoch;
  let maxTtl = o.maxTtl ?? o.ttlSec;
  if (o.reader) {
    const cid = Number(await o.reader.chainId());
    if (cid !== Number(o.chainId)) fail('WRONG_CHAIN', `RPC chain id ${cid} != requested ${o.chainId}`);
    const cfg = await o.reader.poolConfig(poolId);
    if (!cfg.allowed) fail('HOOK_CONFIG_MISMATCH', 'pool is not allowlisted on the hook');
    if (cfg.requiredStatus.toLowerCase() !== statusHash(o.requiredStatus)) fail('HOOK_CONFIG_MISMATCH', 'hook requires a different status');
    if (cfg.requiredTaskId !== `0x${'0'.repeat(64)}` && cfg.requiredTaskId.toLowerCase() !== o.taskId.toLowerCase()) fail('HOOK_CONFIG_MISMATCH', 'hook pins a different task id');
    if (!(await o.reader.isAdapter(o.account.address))) fail('UNAUTHORIZED_ADAPTER', `${o.account.address} is not an authorized adapter`);
    epoch = cfg.epoch;
    maxTtl = Number(cfg.maxTtl);
  }
  if (epoch === undefined) fail('CONFIG', 'epoch unknown: provide an RPC reader or an explicit epoch');

  // 3. re-fetch immediately before signing; state must be unchanged
  const second = await readTask(o);
  evidence.push(second.snap.rawPath);
  if (!sameTask(first.task, second.task)) fail('STALE_STATE', 'task changed between reads', { first: first.task, second: second.task });
  checkStatus(second.task, o.requiredStatus, o.now());

  // observedAt never runs ahead of the server's Date, the local clock, or the chain head (otherwise the hook would
  // report NOT_YET_VALID); taking the minimum is conservative: the binding only gets older, never fresher.
  let observedAt = Math.min(Math.floor(second.snap.receivedAt / 1000), Math.floor(second.task.serverMs / 1000));
  if (o.reader?.blockTimestamp) observedAt = Math.min(observedAt, Number(await o.reader.blockTimestamp()));
  let expiry = observedAt + Math.min(o.ttlSec, maxTtl);
  if (ACTIVE_STATUSES.includes(second.task.status)) expiry = Math.min(expiry, Math.floor(second.task.expiryMs / 1000));
  const binding = buildBinding({
    taskId: o.taskId,
    status: second.task.status,
    evidenceHash: second.snap.evidenceHash,
    poolId,
    actor: o.actor,
    actions: o.actions,
    maxUses: o.maxUses,
    observedAt,
    expiry,
    epoch,
    chainId: o.chainId,
    hook: o.hook,
    nonce: o.nonce ?? BigInt(`0x${randomBytes(16).toString('hex')}`),
  });
  const signature = await signBinding(binding, o.account);
  const result = {
    ok: true,
    binding: toJson(binding),
    digest: hashBinding(binding),
    signature,
    hookData: encodeHookData(binding, signature),
    signer: o.account.address,
    evidence,
    evidenceHash: second.snap.evidenceHash,
  };

  // 4. on-chain dry run with the exact bytes
  if (o.reader) {
    const { reason } = await o.reader.previewBinding(binding, signature);
    if (Number(reason) !== 0) fail('HOOK_REJECTED', `previewBinding -> ${REASONS[Number(reason)] ?? reason}`);
    result.preview = 'OK';
  }

  // 5. optional write: re-fetch once more right before broadcasting
  if (o.writer) {
    const third = await readTask(o);
    evidence.push(third.snap.rawPath);
    if (!sameTask(second.task, third.task)) fail('STALE_STATE', 'task changed before write');
    checkStatus(third.task, o.requiredStatus, o.now());
    const sent = await o.writer.submitBinding(binding, signature);
    result.txHash = sent.txHash;
    if (sent.outcome !== 'updated') fail('HOOK_REJECTED', `submitBinding -> ${REASONS[Number(sent.reason)] ?? sent.reason}`, { txHash: sent.txHash });
    result.submitted = true;
  }
  return result;
}

/**
 * Keep-alive check for installed grants: if the task is no longer in the required status, OR its state cannot be
 * verified (any adapter error), revoke the grant. Fail closed: unverifiable == revoke.
 */
export async function revokeIfDrifted(input) {
  const o = { now: () => Date.now(), ...input };
  if (!o.writer) fail('CONFIG', 'writer required');
  const poolId = o.poolId ?? poolIdFromKey(o.poolKey);
  let why;
  try {
    const { task } = await readTask(o);
    checkStatus(task, o.requiredStatus, o.now());
  } catch (e) {
    if (e?.name !== 'AdapterError') throw e;
    why = e.code;
  }
  if (!why) return { ok: true, action: 'kept' };
  const sent = await o.writer.revokeGrant(poolId, o.actor);
  return { ok: true, action: 'revoked', reason: why, txHash: sent.txHash };
}
