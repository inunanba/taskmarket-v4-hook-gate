#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Usage:
//   node src/cli.mjs authorize --task 0x.. --status completed --pool-id 0x.. --actor 0x.. --actions swap
//        --hook 0x.. [--chain-id 46630] [--rpc $RPC] [--submit] [--max-uses 1] [--ttl 300] [--raw-dir ./raw]
//        [--epoch N (offline only)] [--api https://api.taskmarket.dev]
//   node src/cli.mjs revoke-if-drifted --task 0x.. --status completed --pool-id 0x.. --actor 0x.. --hook 0x.. --rpc $RPC
//   node src/cli.mjs probe --task 0x.. [--raw-dir ./raw]        (read-only: fetch + preserve + validate, no signing)
// Secrets: ADAPTER_PRIVATE_KEY (testnet-only signer). It is never printed or logged.
import { privateKeyToAccount } from 'viem/accounts';
import { authorize, revokeIfDrifted } from './authorize.mjs';
import { fetchTaskSnapshot, parseTask, DEFAULT_API_BASE } from './taskmarket.mjs';
import { parseActions, ROBINHOOD_TESTNET_CHAIN_ID } from './binding.mjs';
import { makeChain } from './chain.mjs';
import { fail } from './errors.mjs';

function args(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const k = a.slice(2);
    const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : true;
    out[k] = v;
  }
  return out;
}

function account() {
  const pk = process.env.ADAPTER_PRIVATE_KEY;
  if (!pk || !/^0x[0-9a-fA-F]{64}$/.test(pk)) fail('CONFIG', 'ADAPTER_PRIVATE_KEY (0x + 64 hex, testnet only) is not set');
  return privateKeyToAccount(pk);
}

async function main() {
  const a = args(process.argv.slice(2));
  const cmd = a._[0];
  const common = {
    taskId: a.task,
    apiBase: a.api ?? process.env.TASKMARKET_API_URL ?? DEFAULT_API_BASE,
    rawDir: a['raw-dir'] ?? './raw',
    allowInsecureLocal: Boolean(a['allow-insecure-local']),
    maxClockSkewMs: a['max-skew-ms'] ? Number(a['max-skew-ms']) : undefined,
  };
  if (cmd === 'probe') {
    const snap = await fetchTaskSnapshot(common);
    const task = parseTask(snap, { expectedTaskId: a.task, maxClockSkewMs: common.maxClockSkewMs });
    return { ok: true, task: { ...task, expiry: new Date(task.expiryMs).toISOString() }, rawPath: snap.rawPath, sha256: snap.sha256, evidenceHash: snap.evidenceHash };
  }
  const chainId = Number(a['chain-id'] ?? ROBINHOOD_TESTNET_CHAIN_ID);
  const acct = account();
  const rpc = a.rpc ?? process.env.RPC_URL;
  const chain = rpc ? makeChain({ rpcUrl: rpc, hook: a.hook, chainId, account: acct }) : {};
  if (cmd === 'authorize') {
    if (a.submit && !rpc) fail('CONFIG', '--submit needs --rpc');
    return authorize({
      ...common,
      requiredStatus: a.status,
      poolId: a['pool-id'],
      actor: a.actor,
      actions: parseActions(a.actions ?? 'swap'),
      maxUses: Number(a['max-uses'] ?? 1),
      ttlSec: Number(a.ttl ?? 300),
      chainId,
      hook: a.hook,
      account: acct,
      epoch: a.epoch !== undefined ? BigInt(a.epoch) : undefined,
      nonce: a.nonce !== undefined ? BigInt(a.nonce) : undefined,
      reader: chain.reader,
      writer: a.submit ? chain.writer : undefined,
    });
  }
  if (cmd === 'revoke-if-drifted') {
    if (!rpc) fail('CONFIG', 'revoke-if-drifted needs --rpc');
    return revokeIfDrifted({ ...common, requiredStatus: a.status, poolId: a['pool-id'], actor: a.actor, writer: chain.writer });
  }
  fail('INVALID_INPUT', 'command must be authorize | revoke-if-drifted | probe');
}

main().then(
  (r) => { process.stdout.write(`${JSON.stringify(r, null, 2)}\n`); },
  (e) => {
    const out = { ok: false, code: e?.code ?? 'INTERNAL', message: String(e?.message ?? e) };
    if (e?.details) out.details = e.details;
    process.stdout.write(`${JSON.stringify(out, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2)}\n`);
    process.exitCode = 1;
  },
);
