// SPDX-License-Identifier: MIT
// LOCAL E2E helper: re-submit an already-used signed binding and expect an on-chain BindingRejected(NONCE_USED).
// usage: node replay-binding.mjs <authorize.json> <rpc> <hook> <chainId> (relayer key from RELAYER_PRIVATE_KEY)
import { readFileSync } from 'node:fs';
import { privateKeyToAccount } from 'viem/accounts';
import { makeChain } from '../src/chain.mjs';
import { REASONS } from '../src/binding.mjs';

const [file, rpcUrl, hook, chainId] = process.argv.slice(2);
const r = JSON.parse(readFileSync(file, 'utf8'));
const big = ['observedAt', 'expiry', 'epoch', 'chainId', 'nonce'];
const b = Object.fromEntries(Object.entries(r.binding).map(([k, v]) => [k, big.includes(k) ? BigInt(v) : v]));
const { writer } = makeChain({ rpcUrl, hook, chainId: Number(chainId), account: privateKeyToAccount(process.env.RELAYER_PRIVATE_KEY) });
const out = await writer.submitBinding(b, r.signature);
console.log(JSON.stringify({ ...out, reasonName: REASONS[out.reason] }));
if (out.outcome !== 'rejected' || REASONS[out.reason] !== 'NONCE_USED') process.exit(1);
