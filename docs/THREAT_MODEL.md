# Threat model and limitations

Scope: `src/TaskGateHook.sol`, `src/TaskBindingLib.sol`, the reference adapter (`adapter/src`), and their deployment on
Robinhood Chain testnet (46630). Assets protected: the right to swap or add liquidity on allowlisted pools. The hook
holds no funds and never moves value.

## Actors and trust

| Actor | Trust | Can | Cannot |
|---|---|---|---|
| Owner | trusted (config authority) | allowlist/delist pools, set adapters, pause, transfer ownership (2-step) | sign bindings (unless also an adapter), upgrade code (none) |
| Adapter signer | **trusted oracle** | attest task state for allowlisted pools within `maxTtl`, revoke grants, cancel own nonces | configure pools, authorize ungated pools/actions, exceed pool limits |
| Relayer (anyone) | untrusted | submit signed bindings, pay gas | forge or alter bindings, roll back newer grants (`OUTDATED`) |
| Router / actor | per pool | perform the bound action within `maxUses` / expiry | use another pool's or actor's grant |
| Taskmarket API | untrusted data source | report task state | have its response accepted without strict validation, preserved evidence and a re-read |
| Sequencer | semi-trusted | order/censor txs, skew `block.timestamp` within L2 rules | make an invalid binding valid |

## Threats

1. **Oracle/relayer trust.** The adapter key is the root of trust for task state. A compromised key can authorize
   any allowlisted pool/action until the owner runs `setAdapter(key,false)`, which invalidates its pending signatures
   and every grant it installed (checked at use). Mitigations: testnet-only keys, short `maxTtl`, `maxUses`, per-pool
   `requiredTaskId` pinning, monitoring of `BindingUpdated`/`AuthorizationGranted`. Future work: k-of-n adapters.
   Relayers are untrusted by construction.
2. **Stale state.** Taskmarket state can change after the read. Mitigations: re-fetch before signing and again
   before writing (`STALE_STATE`), on-chain `maxStaleness` and `maxTtl` from `observedAt`, `observedAt` clamped to the chain
   head, HTTP `Date` skew and `Age` checks, the `epoch` bump on reconfiguration, and `revoke-if-drifted` (which also
   revokes when state is unverifiable). Residual risk: up to `maxTtl` seconds of use after a status change if
   nobody revokes.
3. **Censorship and liveness.** Taskmarket API, adapter, relayer or sequencer downtime can delay authorizations but never
   create them (fail closed). Censoring `revokeGrant` extends a grant to at most its `expiry`. LP exits
   (`removeLiquidity`) are never gated, so funds can't be trapped. Pause is available.
4. **Replay.** Nonces are single-use per signer across both delivery modes. Signatures are domain-separated by chain id
   and hook address, explicit `chainId`/`hook` fields are checked first, the pool `epoch` is checked, and replaying an older
   binding over a newer grant is refused (`OUTDATED`). Signature malleability (high-s) is rejected by OZ `tryRecover`.
5. **Front-running inline hookData.** A pending tx's hookData is public. Because the binding is bound to `actor` (the
   router), only calls through that router can use it. With a **shared public router** a front-runner could consume
   it. Mitigation: per-user or access-controlled routers, or the install mode for a dedicated router. This is documented as a limitation.
6. **Reentrancy.** The hook makes no external calls (hookData decoding is done in place after a strict structural check, and
   signatures use the `ecrecover` precompile). State changes happen only after all checks. Callbacks run inside the PoolManager lock.
7. **Callback coverage.** Only `beforeInitialize`, `beforeSwap` and `beforeAddLiquidity` are enabled. Remove-liquidity and donate
   are intentionally ungated. All `after*` and return-delta flags are off, so the hook can't change amounts. This
   is not pool-wide access control: other pools (without this hook) are unaffected, and the hook can't stop actions
   it doesn't see. Tests assert that out-of-scope paths neither call nor consume authorizations.
8. **Settlement network.** Taskmarket's documented settlement network is **Base Mainnet**. Nothing here bridges,
   escrows or settles Taskmarket value, and no code references a Taskmarket contract on Robinhood Chain. Task state reaches
   46630 only as an adapter attestation. A future integration (e.g. cross-chain proofs of Base settlement events) would
   replace the trusted adapter and is out of scope.
9. **Configuration and upgrade authority.** A single owner with two-step transfer and no proxy or upgradeability. Every change
   emits an event and bumps the pool epoch. A compromised owner can allowlist pools or adapters. Use a multisig on testnet
   as practice. Rollback levers: pause, delist, adapter-off (see RUNBOOK §7).
10. **Untrusted API content.** Size cap, timeout, no redirects, JSON-object-only, strict field types, documented status enum,
    id match, and raw bytes preserved before parsing. 401/403/402 never trigger credential or payment flows.
11. **Secrets.** Only the adapter key, held in an env var. It is never printed (tested) or emitted. Events contain only public data.
12. **Time.** `block.timestamp` on an Arbitrum-based L2 follows the sequencer within protocol bounds. `maxStaleness`
    and `maxTtl` should be minutes, not seconds, to tolerate this.

## Known limitations

- Prototype, not audited. Single adapter, no threshold signatures.
- No official Uniswap v4 deployment listed for 46630. See RUNBOOK §2 for verification options.
- `actor` is the router, not the end user.
- No cryptographic proof of Taskmarket state (the API does not sign responses). The `evidenceHash` makes the attestation
  auditable, not trustless.
- Status set fixed to the OpenAPI enum observed on 2026-10-05. Unknown values fail closed.
