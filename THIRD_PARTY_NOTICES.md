# Third-party notices

Original code in `src/`, `script/`, `test/`, `adapter/src`, `adapter/scripts`, `adapter/test` and `scripts/` is MIT.

| Dependency | Pin | License | Used for |
|---|---|---|---|
| Uniswap/v4-core | tag `v4.0.0` @ `e50237c43811bd9b526eff40f26772152a42daba` | interfaces/libraries/types used by the hook are MIT; `PoolManager.sol` is BUSL-1.1 (see `lib/v4-core/licenses/`) | hook interfaces & libraries (MIT); `PoolManager` and v4 test routers only in tests/local scripts |
| OpenZeppelin Contracts (vendored by v4-core v4.0.0 as a submodule) | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` | MIT | `ECDSA.tryRecover` |
| solmate (vendored by v4-core v4.0.0) | `4b47a19038b798b4a33d9749d25e570443520647` | AGPL-3.0-only (`MockERC20` test utility) | test/local-only mock tokens; not part of the hook |
| foundry-rs/forge-std | tag `v1.9.7` @ `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | MIT / Apache-2.0 | tests & scripts |
| viem | `2.57.3` (exact, `adapter/package-lock.json`) | MIT | adapter EIP-712 signing and RPC |

The hook contract itself only links MIT code (v4-core interfaces/libraries + OpenZeppelin ECDSA).
