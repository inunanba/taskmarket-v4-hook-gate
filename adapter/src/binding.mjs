// SPDX-License-Identifier: MIT
// EIP-712 binding encoding. Must match src/TaskBindingLib.sol exactly (cross-checked by test/AdapterVector.t.sol).
import { encodeAbiParameters, hashTypedData, keccak256, toBytes, getAddress, isAddress, isHex } from 'viem';
import { fail } from './errors.mjs';

export const ACTIONS = Object.freeze({ swap: 1, add: 2 });
export const ROBINHOOD_TESTNET_CHAIN_ID = 46630;

export const BINDING_TYPES = Object.freeze({
  TaskBinding: [
    { name: 'taskId', type: 'bytes32' },
    { name: 'statusHash', type: 'bytes32' },
    { name: 'evidenceHash', type: 'bytes32' },
    { name: 'poolId', type: 'bytes32' },
    { name: 'actor', type: 'address' },
    { name: 'actions', type: 'uint8' },
    { name: 'maxUses', type: 'uint32' },
    { name: 'observedAt', type: 'uint64' },
    { name: 'expiry', type: 'uint64' },
    { name: 'epoch', type: 'uint64' },
    { name: 'chainId', type: 'uint64' },
    { name: 'hook', type: 'address' },
    { name: 'nonce', type: 'uint256' },
  ],
});

const BINDING_TUPLE = {
  type: 'tuple',
  components: BINDING_TYPES.TaskBinding,
};

/** Hook's own `Reason` enum, index-aligned with TaskGateHook.Reason. */
export const REASONS = Object.freeze([
  'OK', 'PAUSED', 'POOL_NOT_ALLOWED', 'MALFORMED', 'WRONG_CHAIN', 'WRONG_HOOK', 'WRONG_POOL', 'WRONG_ACTION',
  'WRONG_ACTOR', 'WRONG_TASK', 'WRONG_STATUS', 'WRONG_EPOCH', 'NOT_YET_VALID', 'STALE', 'EXPIRED', 'TTL_TOO_LONG',
  'BAD_SIGNATURE', 'UNAUTHORIZED_ADAPTER', 'NONCE_USED', 'OUTDATED', 'NO_GRANT',
]);

export function domain(chainId, hook) {
  return { name: 'TaskGateHook', version: '1', chainId: Number(chainId), verifyingContract: getAddress(hook) };
}

export function statusHash(status) {
  return keccak256(toBytes(status));
}

/** v4 PoolId = keccak256(abi.encode(PoolKey)). */
export function poolIdFromKey({ currency0, currency1, fee, tickSpacing, hooks }) {
  return keccak256(
    encodeAbiParameters(
      [{ type: 'address' }, { type: 'address' }, { type: 'uint24' }, { type: 'int24' }, { type: 'address' }],
      [getAddress(currency0), getAddress(currency1), Number(fee), Number(tickSpacing), getAddress(hooks)],
    ),
  );
}

export function parseActions(list) {
  const arr = Array.isArray(list) ? list : String(list).split(',');
  let bits = 0;
  for (const a of arr) {
    const v = ACTIONS[String(a).trim().toLowerCase()];
    if (!v) fail('INVALID_INPUT', `unknown action ${a} (use swap,add)`);
    bits |= v;
  }
  if (bits === 0) fail('INVALID_INPUT', 'no actions');
  return bits;
}

export function buildBinding(f) {
  const need = (cond, what) => { if (!cond) fail('INVALID_INPUT', what); };
  need(isHex(f.taskId, { strict: true }) && f.taskId.length === 66, 'taskId');
  need(isHex(f.poolId, { strict: true }) && f.poolId.length === 66, 'poolId');
  need(isHex(f.evidenceHash, { strict: true }) && f.evidenceHash.length === 66, 'evidenceHash');
  need(isAddress(f.actor) && BigInt(f.actor) !== 0n, 'actor');
  need(isAddress(f.hook), 'hook');
  need(Number.isInteger(f.actions) && f.actions >= 1 && f.actions <= 3, 'actions');
  need(Number.isInteger(f.maxUses) && f.maxUses >= 1 && f.maxUses <= 0xffffffff, 'maxUses');
  return {
    taskId: f.taskId.toLowerCase(),
    statusHash: statusHash(f.status),
    evidenceHash: f.evidenceHash,
    poolId: f.poolId.toLowerCase(),
    actor: getAddress(f.actor),
    actions: f.actions,
    maxUses: f.maxUses,
    observedAt: BigInt(f.observedAt),
    expiry: BigInt(f.expiry),
    epoch: BigInt(f.epoch),
    chainId: BigInt(f.chainId),
    hook: getAddress(f.hook),
    nonce: BigInt(f.nonce),
  };
}

export function hashBinding(binding) {
  return hashTypedData({ domain: domain(binding.chainId, binding.hook), types: BINDING_TYPES, primaryType: 'TaskBinding', message: binding });
}

export async function signBinding(binding, account) {
  return account.signTypedData({ domain: domain(binding.chainId, binding.hook), types: BINDING_TYPES, primaryType: 'TaskBinding', message: binding });
}

/** hookData for the inline path: abi.encode(TaskBinding, bytes signature). */
export function encodeHookData(binding, signature) {
  return encodeAbiParameters([BINDING_TUPLE, { type: 'bytes' }], [binding, signature]);
}

export function toJson(binding) {
  return Object.fromEntries(Object.entries(binding).map(([k, v]) => [k, typeof v === 'bigint' ? v.toString() : v]));
}
