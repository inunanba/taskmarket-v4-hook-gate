# Runbook: Robinhood Chain testnet (46630)

Everything below is **testnet only**. Values in `<ANGLE_BRACKETS>` or marked `TBD` are placeholders. This project
does not ship any real deployment address, credential or signature.

## 1. Network facts (verify before use)

From [Connecting to Robinhood Chain](https://docs.robinhood.com/chain/connecting/) (re-read on 2026-10-05):

| | Robinhood Chain testnet |
|---|---|
| Chain ID | `46630` |
| Public RPC (rate-limited) | `https://rpc.testnet.chain.robinhood.com` |
| Alchemy RPC | `https://robinhood-testnet.g.alchemy.com/v2/{API_KEY}` |
| Explorer | `explorer.testnet.chain.robinhood.com` |
| Gas token | ETH (Arbitrum L2; see [About Robinhood Chain](https://docs.robinhood.com/chain/)) |

Check it live (read-only):

```bash
scripts/probe-robinhood-testnet.sh            # asserts eth_chainId == 46630, CREATE2 deployer present
```

`evidence/robinhood-testnet-probe.txt` holds our run. It returned `eth_chainId 46630`, and the deterministic CREATE2
deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` has code.

## 2. Verify the v4 PoolManager on 46630

**Uniswap's deployment docs list v4 for Robinhood Chain *mainnet* (4663) only.** We found no official listing for
testnet 46630. Never paste an address you have not verified yourself. Pick one of these options:

**Option A: use an existing PoolManager on 46630 after verifying it.** Observation, not an endorsement: on
2026-10-05 the address Uniswap lists as the 4663 PoolManager (`0x8366a39cc670b4001a1121b8f6a443a643e40951`, from
[Uniswap v4 deployments](https://developers.uniswap.org/docs/protocols/v4/deployments)) also has code on 46630. Its
runtime bytecode keccak (`0xbd38…5626`) is **identical** to the mainnet one. On 46630 its `owner()` is
`0x9701…3A52`, which differs from mainnet. Reproduce with:

```bash
scripts/probe-robinhood-testnet.sh 0x8366a39cc670b4001a1121b8f6a443a643e40951 https://rpc.mainnet.chain.robinhood.com
```

Before relying on it, confirm with Robinhood or Uniswap sources that it is a sanctioned testnet deployment. The
opt-in fork suite runs the full lifecycle against whatever address you pass in `RH_TESTNET_POOL_MANAGER`
(`evidence/fork-robinhood-testnet.log`: 3/3 passed against the address above).

**Option B: deploy your own PoolManager** from the pinned `lib/v4-core` (BUSL-1.1, testnet use) and record it as
self-deployed in `deployments/robinhood-testnet.json`.

## 3. Local rehearsal

```bash
# a) unit + integration (real PoolManager in-process)
forge test
# b) full operational loop on anvil with a local Taskmarket test double
bash scripts/e2e-local.sh
# c) fork rehearsal against live 46630 state (no broadcast)
ROBINHOOD_TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com RH_TESTNET_POOL_MANAGER=<verified> \
  FOUNDRY_PROFILE=fork forge test -vv
# d) dry-run the real deploy script against a fork (simulation only, no --broadcast)
POOL_MANAGER=<verified> HOOK_OWNER=<owner> EXPECTED_CHAIN_ID=46630 \
  forge script script/DeployTaskGateHook.s.sol --fork-url $ROBINHOOD_TESTNET_RPC_URL
```

## 4. Deploy to 46630

Prerequisites (not provided): a funded **testnet** deployer key in a cast keystore, `POOL_MANAGER` from §2, and a `HOOK_OWNER`.

```bash
cp config/robinhood-testnet.example.env .env && $EDITOR .env && source .env
cast wallet import rh-deployer --interactive        # testnet key only
forge script script/DeployTaskGateHook.s.sol --rpc-url robinhood_testnet --account rh-deployer --broadcast
# prints the hook address (low 14 bits must be 0x2880) and salt; record them in deployments/robinhood-testnet.json
cast call $HOOK 'owner()(address)' --rpc-url $ROBINHOOD_TESTNET_RPC_URL
```

The script refuses to run if `block.chainid != EXPECTED_CHAIN_ID`, if `POOL_MANAGER` has no code, or if the CREATE2
deployer is missing. It never defaults an address.

## 5. Configure

All owner operations go through `script/ConfigureTaskGateHook.s.sol`, and each one emits an event.

```bash
# authorize the adapter signer (its ADDRESS only)
ACTION=adapter-on ADAPTER=$ADAPTER forge script script/ConfigureTaskGateHook.s.sol --rpc-url robinhood_testnet --account rh-owner --broadcast
# allowlist a pool (before initializing it: beforeInitialize refuses unlisted pools)
ACTION=allow-pool forge script script/ConfigureTaskGateHook.s.sol --rpc-url robinhood_testnet --account rh-owner --broadcast
# initialize the pool on the PoolManager (sqrtPriceX96 of your choice; 2**96 = price 1)
cast send $POOL_MANAGER 'initialize((address,address,uint24,int24,address),uint160)' \
  "($CURRENCY0,$CURRENCY1,$FEE,$TICK_SPACING,$HOOK)" 79228162514264337593543950336 --account rh-owner --rpc-url $ROBINHOOD_TESTNET_RPC_URL
# inspect
ACTION=show forge script script/ConfigureTaskGateHook.s.sol --rpc-url robinhood_testnet
```

## 6. Operate

```bash
cd adapter
export ADAPTER_PRIVATE_KEY=<testnet-only>   # never commit; never printed by the CLI
# per authorization (actor = the router contract that calls the PoolManager)
node src/cli.mjs authorize --task <TASK_ID> --status completed --pool-id <POOL_ID> --actor <ROUTER> --actions swap \
  --max-uses 1 --ttl 300 --hook $HOOK --chain-id 46630 --rpc $ROBINHOOD_TESTNET_RPC_URL --submit
# keep-alive, e.g. every minute from cron: revoke if the task drifted or cannot be verified
node src/cli.mjs revoke-if-drifted --task <TASK_ID> --status completed --pool-id <POOL_ID> --actor <ROUTER> \
  --hook $HOOK --chain-id 46630 --rpc $ROBINHOOD_TESTNET_RPC_URL
```

Keep the `raw/` directory. Each on-chain `evidenceHash` is the keccak256 of one `raw/*.body` file.

Monitoring: index `BindingUpdated`, `BindingRejected`, `AuthorizationGranted`, `BindingRevoked`, `PoolConfigured`,
`AdapterUpdated` and `PausedSet` from the hook address. For a reverted swap or add, decode the revert data
`WrappedError(hook, selector, Rejected(reason), HookCallFailed())` or call `previewCallback`.

## 7. Rollback / incident response

| Situation | Action (owner) | Effect |
|---|---|---|
| Any doubt, stop everything | `ACTION=pause` | All gated actions and installations fail closed (`PAUSED`). LP exits still work. |
| Adapter key suspected compromised | `ACTION=adapter-off ADAPTER=<addr>` | Its signatures and **all outstanding grants** stop working at once |
| One pool misconfigured | `ACTION=delist-pool` (pool env vars) | Swaps and adds on that pool rejected (`POOL_NOT_ALLOWED`), epoch bumped |
| One actor's grant must go | `ACTION=revoke-grant ACTOR=<router>` (owner or adapter) | `BindingRevoked`, grant deleted |
| Undo | `ACTION=unpause` / `adapter-on` / `allow-pool` | Epoch is bumped again, so old bindings stay dead and new ones must be signed |
| Hook logic bug | Deploy a new hook (no upgradeability by design). Pools are bound to their hook address, so create new pools and let LPs exit the old ones (never gated). | |

## 8. Taskmarket boundary

Taskmarket settles on **Base Mainnet** ([Network Reference](https://docs.taskmarket.dev/reference/network)). Nothing
in this runbook creates, funds, claims or settles a Taskmarket task. The adapter only performs the public read
`GET /api/tasks/{id}`. Authenticated or X402 routes are out of scope and fail closed (`AUTH_REQUIRED` / `PAYMENT_REQUIRED`).
