#!/usr/bin/env bash
# End-to-end operational demo on a LOCAL anvil chain (31337) with a LOCAL Taskmarket test double.
# Uses only anvil's publicly known dev keys. Nothing touches a public network.
#   deploy v4 PoolManager + hook (CREATE2-mined) -> adapter reads task, re-fetches, signs, previews, re-fetches,
#   submits binding on-chain -> swap consumes grant -> replay is logged as BindingRejected(NONCE_USED) ->
#   task status drifts -> adapter revokes -> swap is rejected -> adapter refuses to sign.
set -euo pipefail
cd "$(dirname "$0")/.."
RPC_PORT=${RPC_PORT:-8546}; API_PORT=${API_PORT:-8788}
RPC=http://127.0.0.1:$RPC_PORT; API=http://127.0.0.1:$API_PORT
TASK=0x9ab3d5e1ca795d87364e8b46ee7cc2c67244d66eaf0a0c2eb3784b74c8447654
DEPLOYER_PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80   # anvil dev account #0 (public)
export ADAPTER_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d  # anvil dev account #1 (public)
ADAPTER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
RAW=$(mktemp -d)
cleanup() { kill ${ANVIL_PID:-} ${MOCK_PID:-} 2>/dev/null || true; }
trap cleanup EXIT

step() { printf '\n=== %s\n' "$*"; }
step "start anvil (31337) and local Taskmarket mock"
anvil --port "$RPC_PORT" --silent & ANVIL_PID=$!
node adapter/scripts/mock-taskmarket.mjs "$API_PORT" "$TASK" completed & MOCK_PID=$!
for i in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

step "deploy local stack (PoolManager, tokens, routers, hook, swap-gated pool)"
ADAPTER=$ADAPTER LOCAL_STACK_OK=1 forge script script/LocalStack.s.sol:LocalStack --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_PK" -q
HOOK=$(jq -r .hook deployments/local.json); POOL=$(jq -r .poolId deployments/local.json); ROUTER=$(jq -r .swapRouter deployments/local.json)
echo "hook=$HOOK pool=$POOL swapRouter=$ROUTER"

step "swap WITHOUT authorization -> must fail"
if LOCAL_STACK_OK=1 forge script script/LocalStack.s.sol:LocalSwap --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_PK" -q >/dev/null 2>&1; then echo "UNEXPECTED: swap succeeded"; exit 1; else echo "rejected as expected"; fi

A=(node adapter/src/cli.mjs)
COMMON=(--task "$TASK" --status completed --pool-id "$POOL" --actor "$ROUTER" --hook "$HOOK" --chain-id 31337 --rpc "$RPC" --api "$API" --allow-insecure-local --raw-dir "$RAW")
step "adapter: authorize --submit (read, re-read, sign, preview, re-read, write)"
"${A[@]}" authorize "${COMMON[@]}" --actions swap --max-uses 2 --ttl 600 --submit | tee "$RAW/authorize.json" | jq '{ok, submitted, txHash, preview, evidenceHash, observedAt: .binding.observedAt, expiry: .binding.expiry, nonce: .binding.nonce}'

step "swap #1 with EMPTY hookData consumes the installed grant"
LOCAL_STACK_OK=1 forge script script/LocalStack.s.sol:LocalSwap --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_PK" -q && echo "swap ok"

step "replaying the same signed binding is logged on-chain as BindingRejected(NONCE_USED)"
RELAYER_PRIVATE_KEY=$DEPLOYER_PK node adapter/scripts/replay-binding.mjs "$RAW/authorize.json" "$RPC" "$HOOK" 31337

step "task drifts to 'disputed' on Taskmarket -> revoke-if-drifted revokes the grant"
curl -s -X POST "$API/__set?status=disputed"
"${A[@]}" revoke-if-drifted --task "$TASK" --status completed --pool-id "$POOL" --actor "$ROUTER" --hook "$HOOK" --chain-id 31337 --rpc "$RPC" --api "$API" --allow-insecure-local --raw-dir "$RAW" | jq -c '{action, reason}'

step "swap #2 after revocation -> must fail (grant had 1 use left)"
if LOCAL_STACK_OK=1 forge script script/LocalStack.s.sol:LocalSwap --rpc-url "$RPC" --broadcast --private-key "$DEPLOYER_PK" -q >/dev/null 2>&1; then echo "UNEXPECTED: swap succeeded"; exit 1; else echo "rejected as expected"; fi

step "adapter refuses to sign while task is 'disputed'"
if "${A[@]}" authorize "${COMMON[@]}" --actions swap > "$RAW/refuse.json"; then echo "UNEXPECTED"; exit 1; else jq -c '{ok, code}' "$RAW/refuse.json"; fi

step "on-chain event trail"
for sig in 'BindingUpdated(bytes32,address,bytes32,address,uint256,uint8,uint32,uint64,bytes32)' 'BindingRejected(bytes32,address,bytes32,uint256,address,uint8)' 'AuthorizationGranted(bytes32,address,bytes32,uint8,address,uint256,bytes32,bool,uint32)' 'BindingRevoked(bytes32,address,address)'; do
  n=$(cast logs --rpc-url "$RPC" --address "$HOOK" --from-block 0 "$sig" --json | jq length); echo "  ${sig%%(*}: $n"
done
step "raw Taskmarket responses preserved: $(ls "$RAW" | grep -c '\.body$') bodies in $RAW"
echo "E2E OK"
