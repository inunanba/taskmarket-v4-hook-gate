# TaskGateHook: a Taskmarket-gated Uniswap v4 hook (Robinhood Chain testnet prototype)

A small, auditable Uniswap v4 hook. It lets **selected pool actions** run on **allowlisted pools** only when an
**authorized off-chain adapter** has read a Taskmarket task in the required status and signed a compact EIP-712
**task binding** for that pool, actor and action. The binding expires, carries a nonce, and is bound to the chain and the hook.

Built for Taskmarket task `TSK-6BHK4EGT` (`0x9ab3d5e1ca795d87364e8b46ee7cc2c67244d66eaf0a0c2eb3784b74c8447654`).
MIT. **Testnet prototype, not audited.**

> **Settlement boundary.** Taskmarket's documented settlement network is **Base Mainnet**
> ([Network Reference](https://docs.taskmarket.dev/reference/network)). This project never moves, escrows or settles
> Taskmarket funds and does not assume a Taskmarket contract on Robinhood Chain. Task state reaches the chain only as a
> signed attestation from an adapter you operate. Any settlement flow is an explicit off-chain or future integration boundary.

## What makes this entry different

| | |
|---|---|
| **Rejections recorded on-chain** | `submitBinding` never reverts on a bad binding. It returns the `Reason` and emits `BindingRejected(reason)`, so rejected authorizations leave a log. (A reverted callback cannot emit a log. See "Observability" below.) |
| **Raw API evidence linked on-chain** | The adapter keeps the exact Taskmarket response bytes on disk before parsing. Their `keccak256` is signed into the binding as `evidenceHash` and emitted with each grant and use, so you can trace every on-chain authorization back to the raw file. |
| **Staleness checked on-chain, not just expiry** | `observedAt` is checked against a per-pool `maxStaleness`, and `expiry - observedAt` against `maxTtl`. Future observations are refused. Every reconfiguration bumps the pool `epoch`, which invalidates all older bindings and grants. |
| **Revocation when the task changes** | `revoke-if-drifted` re-reads the task. If the status left the allowed value, or the state can't be verified, it calls `revokeGrant`. De-authorizing an adapter immediately kills its outstanding grants. A newer grant can't be rolled back by replaying an older binding (`OUTDATED`). |
| **Tested against live Robinhood testnet state** | An opt-in fork suite runs the full gated lifecycle against the PoolManager bytecode at an observed 46630 address (see the probe evidence and its caveats in [RUNBOOK §2](docs/RUNBOOK.md#2-verify-the-v4-poolmanager-on-46630)). |
| **One-command end-to-end demo** | `scripts/e2e-local.sh` runs on anvil with a local Taskmarket test double: deploy, adapter read/re-read/sign/preview/re-read/write, swap, replay (logged as rejected), status drift, revoke, then the swap is blocked and the adapter refuses to sign. |
| **Explicit chain/domain reasons** | `WRONG_CHAIN` and `WRONG_HOOK` are checked on explicit fields, and the signature check also binds the same values through the EIP-712 domain (tested both ways). |

## Layout

| Path | What |
|---|---|
| `src/TaskGateHook.sol` | The hook. Single contract, no upgradeability, no external calls except the `ecrecover` precompile. |
| `src/TaskBindingLib.sol` | `TaskBinding` struct, EIP-712 typehash/domain/digest, action bits |
| `test/*.t.sol` | 78 Foundry tests (incl. 4 fuzz) against a **real v4 `PoolManager`** + v4 test routers |
| `test/fork/RobinhoodTestnetFork.t.sol` | 3 opt-in tests on a fork of live Robinhood Chain testnet |
| `adapter/` | Node reference adapter: `src/` (taskmarket, binding, authorize, chain, cli) and 60 `node:test` tests |
| `script/DeployTaskGateHook.s.sol`, `script/HookMiner.sol` | CREATE2 deployment at an address that carries the permission bits |
| `script/ConfigureTaskGateHook.s.sol` | Owner operations and rollback (allow/delist pool, pause, adapter on/off, revoke grant) |
| `script/LocalStack.s.sol`, `scripts/e2e-local.sh` | Local anvil end-to-end demo |
| `scripts/probe-robinhood-testnet.sh` | Read-only RPC probe (chain id, CREATE2 deployer, candidate PoolManager bytecode) |
| `artifacts/TaskGateHook.abi.json` | ABI |
| `config/robinhood-testnet.example.env`, `deployments/robinhood-testnet.json` | Config template. Every address is an explicit placeholder. |
| `docs/RUNBOOK.md`, `docs/THREAT_MODEL.md`, `docs/ACCEPTANCE.md` | Runbook, threat model, and the acceptance-to-test matrix |
| `evidence/` | Captured outputs: forge/adapter/fork/e2e logs, RPC probe, live read-only Taskmarket probe (raw bytes + meta) |

## Toolchain (pinned)

| Tool | Version |
|---|---|
| Foundry (forge / anvil / cast) | `1.8.4` (`foundryup -i v1.8.4`) |
| solc | `0.8.26`, `evm_version = cancun`, optimizer 200 runs, `via_ir = true`, `bytecode_hash = none` |
| Uniswap v4-core | tag `v4.0.0` @ `e50237c43811bd9b526eff40f26772152a42daba` (`foundry.lock`, git submodule) |
| forge-std | tag `v1.9.7` @ `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| OpenZeppelin (ECDSA only) | the copy vendored by v4-core v4.0.0 (`dbb6104c…`) |
| Node.js / npm | `>= 20` (tested 20.19.2 / 9.2.0) |
| viem | `2.57.3` (exact pin + `package-lock.json`) |

## Build and test from a clean checkout

```bash
# 1. toolchain
curl -L https://foundry.paradigm.xyz | bash && foundryup -i v1.8.4

# 2. source + pinned deps
git clone --recurse-submodules https://github.com/inunanba/taskmarket-v4-hook-gate.git
cd taskmarket-v4-hook-gate
# (from the zip instead: git init && forge install foundry-rs/forge-std@v1.9.7 Uniswap/v4-core@v4.0.0)

# 3. contracts
forge build
forge test                       # expect: 78 passed; 0 failed; 0 skipped

# 4. adapter
(cd adapter && npm ci && npm test)   # expect: tests 60, pass 60, fail 0

# 5. optional: local end-to-end on anvil (needs jq)
bash scripts/e2e-local.sh            # ends with "E2E OK"

# 6. optional: fork of live Robinhood Chain testnet (read-only, nothing broadcast)
ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com \
RH_TESTNET_POOL_MANAGER=<address you verified per RUNBOOK §2> \
FOUNDRY_PROFILE=fork forge test -vv  # expect: 3 passed
```

Each command exits non-zero on any failure. `.github/workflows/ci.yml` runs steps 3–5 on every push.

## Design

### Selected callbacks and why they are enough

Permission bits: **`beforeInitialize`, `beforeAddLiquidity`, `beforeSwap`** (`0x2880` in the low 14 bits). The
constructor calls `Hooks.validateHookPermissions` and reverts otherwise. No return-delta flags are set: the hook
never changes amounts and never holds funds.

| Callback | Gated? | Why |
|---|---|---|
| `beforeInitialize` | **yes** (allowlist only) | Only pools the owner allowlisted can be created with this hook. Nobody can spin up a lookalike pool on the same hook. |
| `beforeSwap` | **yes** (per-pool `gatedActions` bit 1) | Trading against the pool is the core gated action. |
| `beforeAddLiquidity` | **yes** (per-pool `gatedActions` bit 2) | Controls who can provision the gated pool. |
| `beforeRemoveLiquidity` | **no, deliberately** | LPs must always be able to exit, even while paused, delisted, or with the adapter down. Gating exits could trap funds. |
| `beforeDonate`, all `after*` | no | They are not value-entry paths that need a task signal. The bits are off, so the PoolManager never calls them. Direct calls revert `HookNotImplemented`. |

Tests show that passing a valid binding to remove-liquidity or donate neither reverts nor consumes it, and that a
pool without this hook never calls it. These are the two value-entry paths into a pool, so for a "who may trade or
provide liquidity" gate this subset is sufficient. It is **not** pool-wide access control. See the limitations below.

### Task binding (EIP-712)

Domain: `name="TaskGateHook"`, `version="1"`, `chainId=block.chainid`, `verifyingContract=<hook>`.

```
TaskBinding(bytes32 taskId,bytes32 statusHash,bytes32 evidenceHash,bytes32 poolId,address actor,uint8 actions,
            uint32 maxUses,uint64 observedAt,uint64 expiry,uint64 epoch,uint64 chainId,address hook,uint256 nonce)
```

| Field | Meaning |
|---|---|
| `taskId` | Taskmarket task id (32-byte `id` from `GET /api/tasks/{id}`). A pool may pin one with `requiredTaskId`. |
| `statusHash` | `keccak256(status)` as observed, e.g. `keccak256("completed")`. Must equal the pool's `requiredStatus`. |
| `evidenceHash` | `keccak256` of the exact raw HTTP body the adapter preserved (`adapter/raw/*.body`) |
| `poolId`, `actor`, `actions` | One pool, one actor (the `sender` the PoolManager passes, i.e. the router), and swap/add bits |
| `maxUses` | Number of callbacks an *installed* grant may authorize. An inline binding is always single-use. |
| `observedAt`, `expiry` | When the adapter re-read Taskmarket, and when the binding expires. Checked against `maxStaleness` and `maxTtl`. |
| `epoch` | Pool configuration epoch read by the adapter. A reconfiguration invalidates the binding. |
| `chainId`, `hook` | Explicit chain/domain separation (also inside the EIP-712 domain) |
| `nonce` | Single-use per adapter signer, consumed on success. An adapter can pre-burn one with `cancelNonce`. |

Delivery modes share one validator:

1. **Install:** anyone relays `submitBinding(binding, sig)`. On success a grant is stored (`BindingUpdated`). On failure nothing changes, the call returns the reason and emits `BindingRejected`. Gated callbacks with **empty** `hookData` then consume the grant.
2. **Inline:** `hookData = abi.encode(TaskBinding, bytes sig)` (exactly 576 bytes, canonical encoding enforced without an external call) is verified and consumed atomically for one callback.

### Decision order (deterministic `Reason`)

Callback pre-checks: key must point at this hook and its pool must be allowlisted (`POOL_NOT_ALLOWED`). If the action
is not gated on that pool, it passes untouched. Then `PAUSED`, then either the inline binding (non-canonical bytes give
`MALFORMED`) or the installed grant.

Binding validation (inline and `submitBinding`): `PAUSED → MALFORMED → WRONG_CHAIN → WRONG_HOOK → WRONG_POOL → POOL_NOT_ALLOWED → WRONG_ACTION → WRONG_ACTOR →
WRONG_TASK → WRONG_STATUS → WRONG_EPOCH → NOT_YET_VALID → STALE → EXPIRED → TTL_TOO_LONG → BAD_SIGNATURE →
UNAUTHORIZED_ADAPTER → NONCE_USED → OUTDATED (install only) → OK`. Installed grants are checked as
`NO_GRANT → WRONG_EPOCH → UNAUTHORIZED_ADAPTER → EXPIRED → WRONG_ACTION`.

A signature over another chain or another hook recovers a different address, so it rejects as `UNAUTHORIZED_ADAPTER`.
High-s or garbage signatures reject as `BAD_SIGNATURE`.

### Observability

| Record | When |
|---|---|
| `PoolConfigured`, `AdapterUpdated`, `PausedSet`, `OwnershipTransferStarted/Transferred` | every configuration change |
| `BindingUpdated` / `BindingRevoked` / `NonceCancelled` | binding updates |
| `AuthorizationGranted(poolId, actor, taskId, action, adapter, nonce, evidenceHash, inline, usesLeft)` | each authorized callback |
| `BindingRejected(poolId, actor, taskId, nonce, relayer, reason)` | rejected installation (tx succeeds, nothing stored) |
| revert `Rejected(reason)`, wrapped by v4 as `WrappedError(hook, selector, Rejected(reason), HookCallFailed())` | rejected callback (a reverted tx cannot log). The exact bytes are asserted in tests. |
| `previewCallback(...)`, `previewBinding(...)` | side-effect-free views returning the same `Reason`, for monitors and adapter pre-flight |

No secrets are emitted or stored. Events carry only public ids, addresses, hashes and the reason.

## Adapter

```bash
cd adapter && npm ci
export ADAPTER_PRIVATE_KEY=<testnet-only key; never commit>
# read-only check of a real task (no key needed):
node src/cli.mjs probe --task 0x<64-hex task id> --raw-dir ./raw
# produce + preview + submit an authorization:
node src/cli.mjs authorize --task 0x<id> --status completed --pool-id 0x<PoolId> --actor 0x<router> \
  --actions swap --max-uses 1 --ttl 300 --hook 0x<hook> --chain-id 46630 --rpc $ROBINHOOD_TESTNET_RPC_URL --submit
# keep-alive (cron): revoke the grant if the task drifted or cannot be verified
node src/cli.mjs revoke-if-drifted --task 0x<id> --status completed --pool-id 0x<PoolId> --actor 0x<router> \
  --hook 0x<hook> --chain-id 46630 --rpc $ROBINHOOD_TESTNET_RPC_URL
```

Pipeline (`src/authorize.mjs`):

1. Validate inputs and key before any network call.
2. `GET {api}/api/tasks/{id}`. HTTPS only, 10 s timeout, 1 MB cap, redirects refused. **The raw bytes and metadata (status, headers, sha256, keccak256) are written to `raw/` before parsing**, including for HTTP errors.
3. Treat the response as untrusted: JSON object, `application/json`, valid UTF-8, `id` must equal the request, `status` must be in the OpenAPI enum, `expiryTime` must be an ISO string, the HTTP `Date` must be present and within ±120 s of local time, and `Age` ≤ 60 s.
4. Require `status == requiredStatus` (and an unexpired task for active statuses).
5. Read the hook over RPC: the chain id must match, the pool must be allowlisted with the same required status and task pin, the signer must be an authorized adapter, then use the on-chain `epoch` and `maxTtl`.
6. **Re-fetch** and require id, status and expiry to be unchanged (`STALE_STATE`). `observedAt = min(local, server Date, chain head)`. Sign.
7. `previewBinding` must return `OK`. With `--submit`, **re-fetch again right before the write**, then `submitBinding`, and require a `BindingUpdated` log.

Any failure throws an `AdapterError` with a stable code (`API_ERROR, AUTH_REQUIRED, PAYMENT_REQUIRED, NOT_FOUND,
MALFORMED, MISSING_FIELD, MISMATCH, UNKNOWN_STATUS, WRONG_STATUS, TASK_EXPIRED, UNVERIFIABLE_TIME, STALE,
STALE_STATE, WRONG_CHAIN, HOOK_CONFIG_MISMATCH, UNAUTHORIZED_ADAPTER, HOOK_REJECTED, CONFIG, INVALID_INPUT`). The CLI then
prints `{ok:false, code}`, exits 1, and outputs no hookData.

**Credentials and payments:** the only read used is `GET /api/tasks/{id}`. It was public when checked (2026-10-05,
see `evidence/live-taskmarket-probe/`). The adapter performs **no** Taskmarket writes, payments or claims. HTTP 401/403
map to `AUTH_REQUIRED` and 402 (X402) maps to `PAYMENT_REQUIRED`, and both fail closed. Nothing is bypassed or
invented. If your deployment needs authenticated or X402-protected routes, add the flow documented by Taskmarket
([API Reference](https://docs.taskmarket.dev/api/reference), [Raw REST Fallback](https://docs.taskmarket.dev/reference/raw-api)).
You need exactly two secrets: the adapter signing key (testnet only) and, for deployment, an RPC URL plus a funded testnet deployer.

## Acceptance criteria → tests

Full matrix with every test: [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md).

| Acceptance criterion | Evidence (test names) |
|---|---|
| Builds from a clean checkout | README commands; CI workflow; `evidence/forge-test.log` |
| All tests pass, exit 0 | `forge test` 78/0, `npm test` 60/0, fork 3/0, `e2e-local.sh` "E2E OK" (`evidence/*.log`) |
| Valid binding permits the selected callback only on an allowlisted pool | `test_inline_validBinding_allowsSwap_andEmitsDecision`, `test_inline_validBinding_allowsAddLiquidity`, `test_install_emitsBindingUpdated_thenGrantAuthorizesExactlyMaxUses`, `test_unallowlistedPool_cannotInitialize`, `test_install_unallowlistedPool_rejected`, `test_delistedPool_rejectsEvenValidBinding_rollback`, fork `test_fork_gatedLifecycleOnLivePoolManager` |
| Invalid authorization | `test_unauthorizedSigner_rejected`, `test_tamperedBinding_rejected`, `test_garbageSignature_rejected`, `test_highSSignature_rejected`, `test_malformedHookData_*`, `test_revokedAdapter_*`, `test_directCallerNotPoolManager_rejected`, `test_wrongActor_rejected`, `testFuzz_randomSignerKey_neverAuthorizes`, `testFuzz_randomHookData_neverAuthorizes`, `testFuzz_tamperAnySignedWord_rejected` |
| Wrong task status | `test_wrongStatus_rejected`, `test_wrongTask_rejected`; adapter `wrong task status -> WRONG_STATUS…` |
| Expired binding | `test_expired_inline_rejected`, `test_expired_installedGrant_rejected`, `test_expiryBoundary_inclusive`, `test_staleObservation_rejected`, `test_futureObservation_rejected`, `test_ttlTooLong_rejected`, `testFuzz_expiryWindow` |
| Reused nonce | `test_replayedNonce_inline_rejected`, `test_replayedNonce_install_rejectedWithEvent`, `test_nonceSharedAcrossModes_inlineThenInstall_rejected`, `test_cancelledNonce_rejected`, `test_outdatedBinding_cannotOverwriteNewerGrant` |
| Wrong chain/domain | `test_wrongChainField_rejected`, `test_signedForOtherChainDomain_rejected`, `test_chainSwitchAfterSigning_rejected`, `test_wrongHookField_rejected`, `test_signedForOtherVerifyingContract_rejected`; deploy script `test_deployScript_refusesWrongChain`; adapter `RPC on the wrong chain -> WRONG_CHAIN` |
| Unauthorized configuration | `test_unauthorizedConfiguration_reverts`, `test_invalidConfiguration_reverts`, `test_twoStepOwnership` |
| Adapter/API errors, malformed, missing fields, stale/unverifiable state fail closed | `adapter/test/taskmarket.test.mjs` (HTTP 401/402/403/404/429/5xx, network, timeout, oversize, 12 malformed shapes, 3 missing fields, mismatch, unknown status, Date/skew/Age), `adapter/test/authorize.test.mjs` (STALE_STATE between reads and before the write, re-fetch failure, hook preview/submit rejection, nothing signed or sent) |
| Unrelated pools and out-of-scope callbacks are not treated as authorized | `test_poolIsolation_inlineBindingForA_rejectedOnB`, `test_poolIsolation_installedGrantOnA_doesNotAuthorizeB`, `test_unrelatedPoolWithoutHook_neverCallsHook`, `test_removeLiquidity_*`, `test_donate_isNotGated_andConsumesNothing`, `test_ungatedActionOnAllowlistedPool_passesWithoutConsuming`, `test_disabledCallbacks_revertHookNotImplemented`, `test_permissions_onlySelectedCallbackBits`, `test_foreignHookKey_neverAuthorized` |
| Events and observable records, no secrets | `test_configurationEvents_emitted`, `test_inline_validBinding_allowsSwap_andEmitsDecision`, `test_install_emitsBindingUpdated_…`, `test_bindingRejected_isLogged_andChangesNoState`, `test_revokeGrant_byAdapter_blocksFurtherUse`, `test_previewCallback_matchesOutcome`; adapter `no secret material in results`; e2e event trail |
| Setup/test/deploy/config/rollback docs, placeholders marked | this README, [docs/RUNBOOK.md](docs/RUNBOOK.md), `config/robinhood-testnet.example.env`, `deployments/robinhood-testnet.json` (all `TBD` / `<FILL_…>`) |
| No claim of native Taskmarket settlement on Robinhood Chain | settlement boundary note above; [THREAT_MODEL §8](docs/THREAT_MODEL.md); no code path references a settlement contract |
| JS ↔ Solidity encoding agreement | `test_vector_*` (PoolId, digest, signer, identical hookData bytes, submit) and adapter `committed Solidity fixture equals a fresh deterministic regeneration` |

## Threat model (summary)

Full version: [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

- **Oracle/relayer trust:** the adapter key **is** the oracle. A compromised adapter can authorize anything its pools allow until the owner calls `setAdapter(adapter,false)`, which kills its outstanding grants at once. Relayers are untrusted (they can't forge bindings and can only delay them).
- **Stale state:** expiry, `maxStaleness`, `maxTtl`, epoch, re-fetch before signing and before writing, HTTP Date/Age checks, and `revoke-if-drifted`. The residual window is at most `maxTtl` unless the adapter revokes.
- **Censorship:** sequencer, relayer or Taskmarket API downtime delays authorizations but never creates them (fail closed). LP exits are never gated.
- **Reentrancy:** the hook makes no external calls (only the `ecrecover` precompile). State is written after all checks. The v4 PoolManager lock covers callbacks.
- **Callback coverage:** only swap and add-liquidity are gated. Remove and donate are open by design. A shared public router as `actor` means anyone using that router shares the grant. Use a dedicated or access-controlled router per user (documented, tested as `WRONG_ACTOR`).
- **Config authority:** single owner (two-step transfer), no upgradeability. Pause and delist are the rollback levers.
- **Settlement:** Taskmarket settles on Base Mainnet, off-chain to this system.

## Limitations

- **Not audited. Testnet only.** A single adapter key is a single point of trust (no threshold signatures).
- No official Uniswap v4 deployment for **46630** is listed in Uniswap's docs (the listed Robinhood addresses are for mainnet **4663**). The fork suite takes the PoolManager from an env var you verify. Nothing was broadcast to any public network.
- `actor` is the PoolManager `sender` (router), not the end-user wallet.
- Inline hookData can be seen in the mempool. Anyone calling through the **same** router before the intended user could consume it. Prefer installed grants for a per-user router, or a router that checks `msg.sender`.
- The adapter binds only `id`, `status` and `expiryTime`, plus a hash of the whole raw body. It does not prove Taskmarket state cryptographically, because Taskmarket's API does not sign responses.
- Taskmarket statuses are taken from its OpenAPI schema as of 2026-10-05. A new status fails closed as `UNKNOWN_STATUS` until added.
