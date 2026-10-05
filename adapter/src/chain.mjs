// SPDX-License-Identifier: MIT
// viem-backed reader/writer for TaskGateHook. Kept separate so tests can inject fakes.
import { readFileSync } from 'node:fs';
import { createPublicClient, createWalletClient, http, decodeEventLog, getAddress } from 'viem';

const ABI = JSON.parse(readFileSync(new URL('../../artifacts/TaskGateHook.abi.json', import.meta.url), 'utf8'));

export function makeChain({ rpcUrl, hook, chainId, account }) {
  const chain = {
    id: Number(chainId),
    name: `chain-${chainId}`,
    nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  };
  const pub = createPublicClient({ chain, transport: http(rpcUrl, { timeout: 15_000, retryCount: 0 }) });
  const address = getAddress(hook);
  const read = (functionName, args) => pub.readContract({ address, abi: ABI, functionName, args });

  const reader = {
    chainId: () => pub.getChainId(),
    blockTimestamp: async () => (await pub.getBlock({ blockTag: 'latest' })).timestamp,
    poolConfig: (poolId) => read('poolConfig', [poolId]),
    isAdapter: (a) => read('isAdapter', [a]),
    previewBinding: async (b, sig) => {
      const [reason, signer] = await read('previewBinding', [b, sig]);
      return { reason: Number(reason), signer };
    },
  };

  let writer;
  if (account) {
    const wallet = createWalletClient({ chain, account, transport: http(rpcUrl, { timeout: 30_000, retryCount: 0 }) });
    const send = async (functionName, args) => {
      const { request } = await pub.simulateContract({ address, abi: ABI, functionName, args, account });
      const txHash = await wallet.writeContract(request);
      const receipt = await pub.waitForTransactionReceipt({ hash: txHash, timeout: 120_000 });
      if (receipt.status !== 'success') throw new Error(`tx ${txHash} reverted`);
      const events = receipt.logs
        .filter((l) => l.address.toLowerCase() === address.toLowerCase())
        .map((l) => { try { return decodeEventLog({ abi: ABI, data: l.data, topics: l.topics }); } catch { return null; } })
        .filter(Boolean);
      return { txHash, events };
    };
    writer = {
      submitBinding: async (b, sig) => {
        const { txHash, events } = await send('submitBinding', [b, sig]);
        const up = events.find((e) => e.eventName === 'BindingUpdated');
        const rej = events.find((e) => e.eventName === 'BindingRejected');
        return up ? { txHash, outcome: 'updated' } : { txHash, outcome: 'rejected', reason: rej ? Number(rej.args.reason) : -1 };
      },
      revokeGrant: async (poolId, actor) => send('revokeGrant', [poolId, actor]),
    };
  }
  return { reader, writer };
}
