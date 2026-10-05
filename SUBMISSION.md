# Submission: TSK-6BHK4EGT, Taskmarket-gated Uniswap v4 hook prototype (Robinhood Chain testnet)

**Repo:** https://github.com/inunanba/taskmarket-v4-hook-gate (MIT). The same tree is in the attached zip. Start with `README.md`.

## Results (2026-10-05, Foundry 1.8.4, solc 0.8.26, Node 20.19.2)

| Suite | Result | Log |
|---|---|---|
| `forge build && forge test` (real v4-core `PoolManager`, v4.0.0 pinned) | **78 passed, 0 failed, 0 skipped** (incl. 4 fuzz × 512 runs) | `evidence/forge-test.log` |
| `cd adapter && npm ci && npm test` | **60 passed, 0 failed** | `evidence/adapter-test.log` |
| `FOUNDRY_PROFILE=fork forge test` on **live Robinhood Chain testnet (46630)** state | **3 passed, 0 failed** | `evidence/fork-robinhood-testnet.log` |
| `scripts/e2e-local.sh` (anvil + local Taskmarket test double + adapter writes) | **E2E OK** | `evidence/e2e-local.log` |
| Deploy script dry-run on a 46630 fork (simulation only) | success | `evidence/deploy-dryrun-robinhood-testnet-fork.txt` |
| Live read-only Taskmarket probe of this task | `status=open`, raw bytes + sha256/keccak preserved | `evidence/live-taskmarket-probe/` |

## Deliverables → files

1. Hook: `src/TaskGateHook.sol` + `src/TaskBindingLib.sol`. Owner-gated config, pool allowlist (`beforeInitialize` refuses unlisted pools), EIP-712 task binding (task id, status hash, raw-evidence hash, pool, actor, actions, uses, observedAt, expiry, epoch, chain id, hook, nonce), per-signer nonces, expiry, staleness, TTL and epoch checks, fail-closed `Rejected(reason)`.
2. Tests: `test/*.t.sol`, `test/fork/*`, `adapter/test/*`. The matrix is in `docs/ACCEPTANCE.md` and the README.
3. Adapter: `adapter/src/*`. Reads `GET /api/tasks/{id}`, preserves raw bytes before parsing, validates strictly, re-fetches before signing and again before the write, previews on-chain, submits, and runs `revoke-if-drifted`. No credentials, payments or Taskmarket writes are invented or bypassed (401/403 → `AUTH_REQUIRED`, 402 → `PAYMENT_REQUIRED`).
4. Runbook: `docs/RUNBOOK.md` (RPC and chain id verified from https://docs.robinhood.com/chain/connecting/ and live `eth_chainId`), `config/robinhood-testnet.example.env`, `deployments/robinhood-testnet.json` (all `TBD`), and `artifacts/TaskGateHook.abi.json`.
5. Threat model: `docs/THREAT_MODEL.md` (oracle/relayer trust, stale state, censorship, reentrancy, callback coverage, config authority, front-running on a shared router, Base Mainnet settlement boundary).

## Where this goes beyond the brief

- Rejections recorded on-chain: `submitBinding` returns the reason and emits `BindingRejected(reason)` instead of reverting.
- `evidenceHash` (keccak256 of the preserved raw API body) is signed into the binding and emitted on every authorization.
- On-chain `maxStaleness`, `maxTtl` and config `epoch`, plus `OUTDATED` protection against rolling a grant back. De-authorizing an adapter kills its live grants.
- Fork-tested against the PoolManager bytecode observed on 46630. That address is officially listed only for mainnet 4663, so it is documented as an observation and never hardcoded.
- Selected callbacks: `beforeInitialize`, `beforeSwap`, `beforeAddLiquidity`. Remove-liquidity and donate are never gated, so LPs can always exit (rationale in the README).

Taskmarket settles on Base Mainnet. Nothing here claims or uses a Taskmarket settlement contract on Robinhood Chain.
No addresses, credentials or signatures were invented, and nothing was broadcast to a public network.
