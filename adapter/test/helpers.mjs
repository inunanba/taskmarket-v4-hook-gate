import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { privateKeyToAccount } from 'viem/accounts';

export const TASK = '0x9ab3d5e1ca795d87364e8b46ee7cc2c67244d66eaf0a0c2eb3784b74c8447654';
export const HOOK = '0x4444000000000000000000000000000000002880';
export const POOL = '0x96653a16b0b546944be19fe449083aec5fc57dde8a2d90da14702edeea4d94db';
export const ACTOR = '0x000000000000000000000000000000000000a11c';
export const NOW = Date.parse('2026-10-05T08:00:00.000Z');
export const PK = '0x00000000000000000000000000000000000000000000000000000000000a11ce';

export const tmp = () => mkdtempSync(join(tmpdir(), 'taskgate-raw-'));

export function task(overrides = {}) {
  return { id: TASK, status: 'completed', expiryTime: '2026-10-08T06:41:32.275Z', reward: '5000000', ...overrides };
}

/** Build a fake fetch from a queue of response specs; records calls. */
export function fakeFetch(...specs) {
  const calls = [];
  const fn = async (url, init) => {
    calls.push({ url, init });
    const s = specs.length > 1 ? specs.shift() : specs[0];
    if (typeof s === 'function') return s(url, init);
    if (s instanceof Error) throw s;
    const headers = { 'content-type': 'application/json', date: new Date(NOW).toUTCString(), ...(s.headers ?? {}) };
    for (const [k, v] of Object.entries(headers)) if (v === undefined) delete headers[k];
    const body = s.raw !== undefined ? s.raw : JSON.stringify(s.body ?? task());
    return new Response(body, { status: s.status ?? 200, headers });
  };
  fn.calls = calls;
  return fn;
}

export function spyAccount() {
  const acct = privateKeyToAccount(PK);
  let signs = 0;
  return {
    address: acct.address,
    signTypedData: async (x) => { signs++; return acct.signTypedData(x); },
    get signs() { return signs; },
  };
}

export function fakeReader(over = {}) {
  return {
    chainId: async () => 46630,
    poolConfig: async () => ({
      allowed: true, gatedActions: 3, maxStaleness: 600, maxTtl: 900, epoch: 7n,
      requiredStatus: '0x6216ba39af4188a6d7c765710d7e6075007c3444b59a22a973d1b958c43e60bb', // keccak("completed")
      requiredTaskId: `0x${'0'.repeat(64)}`,
    }),
    isAdapter: async () => true,
    previewBinding: async () => ({ reason: 0 }),
    ...over,
  };
}

export async function rejectsCode(promiseOrFn, code) {
  try {
    await (typeof promiseOrFn === 'function' ? promiseOrFn() : promiseOrFn);
  } catch (e) {
    if (e?.code !== code) throw new Error(`expected ${code}, got ${e?.code ?? e}`);
    return e;
  }
  throw new Error(`expected ${code}, but it resolved`);
}
