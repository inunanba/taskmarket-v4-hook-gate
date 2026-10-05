#!/usr/bin/env bash
# Read-only probe of Robinhood Chain testnet. Verifies the chain id from the documented public RPC
# (https://docs.robinhood.com/chain/connecting/) and checks a CANDIDATE v4 PoolManager address that the operator passes
# in. It never sends a transaction. Usage:
#   scripts/probe-robinhood-testnet.sh [candidate_pool_manager] [reference_rpc_for_bytecode_comparison]
set -euo pipefail
RPC=${ROBINHOOD_TESTNET_RPC_URL:-https://rpc.testnet.chain.robinhood.com}
CAND=${1:-}
REF_RPC=${2:-}
echo "probe time (UTC): $(date -u +%FT%TZ)"
echo "rpc: $RPC"
CID=$(cast chain-id --rpc-url "$RPC"); echo "eth_chainId: $CID"
[ "$CID" = "46630" ] || { echo "FAIL: expected 46630"; exit 1; }
echo "latest block: $(cast block-number --rpc-url "$RPC")"
C2=0x4e59b44847b379578588920cA78FbF26c0B4956C
echo "CREATE2 deployer $C2 code bytes: $(( ($(cast code $C2 --rpc-url "$RPC" | wc -c) - 3) / 2 ))"
if [ -n "$CAND" ]; then
  CODE=$(cast code "$CAND" --rpc-url "$RPC")
  echo "candidate PoolManager $CAND code bytes: $(( (${#CODE} - 2) / 2 )) keccak: $(cast keccak "$CODE")"
  if [ -n "$REF_RPC" ]; then
    REF=$(cast code "$CAND" --rpc-url "$REF_RPC")
    echo "same address on reference rpc $REF_RPC: keccak $(cast keccak "$REF") (chain $(cast chain-id --rpc-url "$REF_RPC"))"
    [ "$(cast keccak "$CODE")" = "$(cast keccak "$REF")" ] && echo "runtime bytecode IDENTICAL to reference" || echo "runtime bytecode DIFFERS from reference"
  fi
  echo "candidate owner(): $(cast call "$CAND" 'owner()(address)' --rpc-url "$RPC" 2>/dev/null || echo n/a)"
fi
