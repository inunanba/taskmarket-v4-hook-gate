// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TaskGateHook} from "../../src/TaskGateHook.sol";
import {TaskBindingLib} from "../../src/TaskBindingLib.sol";

/// @dev Shared fixture: a REAL v4 PoolManager + v4 test routers, the hook deployed at an address whose low bits carry
///      exactly beforeInitialize | beforeAddLiquidity | beforeSwap, two allowlisted pools (A, B) on the hook, and one
///      unrelated pool (C) without any hook. Tests run as Robinhood Chain testnet (chain id 46630).
abstract contract TaskGateFixture is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint64 internal constant RH_TESTNET = 46630;
    uint160 internal constant HOOK_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;
    address internal constant HOOK_ADDR = address(uint160(0x4444) << 144 | HOOK_FLAGS);

    bytes32 internal constant COMPLETED = keccak256("completed");
    bytes32 internal constant TASK_ID = 0x9ab3d5e1ca795d87364e8b46ee7cc2c67244d66eaf0a0c2eb3784b74c8447654;
    bytes32 internal constant EVIDENCE = keccak256("raw taskmarket response bytes");
    uint32 internal constant MAX_STALENESS = 600;
    uint32 internal constant MAX_TTL = 900;
    uint8 internal constant BOTH = TaskBindingLib.ACTION_SWAP | TaskBindingLib.ACTION_ADD_LIQUIDITY;
    uint8 internal constant SWAP = TaskBindingLib.ACTION_SWAP;
    uint8 internal constant ADD = TaskBindingLib.ACTION_ADD_LIQUIDITY;

    TaskGateHook internal hook;
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");
    uint256 internal adapterPk = 0xA11CE;
    address internal adapter;
    uint256 internal otherPk = 0xB0B;

    PoolKey internal keyA;
    PoolKey internal keyB;
    PoolKey internal keyC; // no hook: unrelated pool
    PoolId internal idA;
    PoolId internal idB;
    uint256 internal nonceCounter = 1;

    function setUp() public virtual {
        vm.chainId(RH_TESTNET);
        vm.warp(1_790_000_000);
        adapter = vm.addr(adapterPk);

        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployCodeTo("TaskGateHook.sol:TaskGateHook", abi.encode(manager, owner), HOOK_ADDR);
        hook = TaskGateHook(HOOK_ADDR);

        keyA = PoolKey(currency0, currency1, 3000, 60, IHooks(HOOK_ADDR));
        keyB = PoolKey(currency0, currency1, 500, 10, IHooks(HOOK_ADDR));
        keyC = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        idA = keyA.toId();
        idB = keyB.toId();

        vm.startPrank(owner);
        hook.setAdapter(adapter, true);
        hook.configurePool(keyA, true, BOTH, COMPLETED, bytes32(0), MAX_STALENESS, MAX_TTL);
        hook.configurePool(keyB, true, BOTH, COMPLETED, bytes32(0), MAX_STALENESS, MAX_TTL);
        vm.stopPrank();

        manager.initialize(keyA, SQRT_PRICE_1_1);
        manager.initialize(keyB, SQRT_PRICE_1_1);
        manager.initialize(keyC, SQRT_PRICE_1_1);

        // Seed liquidity on A and B through the gate itself (inline bindings), and on C freely.
        modifyLiquidityRouter.modifyLiquidity(
            keyA, LIQUIDITY_PARAMS, _hookData(_binding(idA, address(modifyLiquidityRouter), ADD))
        );
        modifyLiquidityRouter.modifyLiquidity(
            keyB, LIQUIDITY_PARAMS, _hookData(_binding(idB, address(modifyLiquidityRouter), ADD))
        );
        modifyLiquidityRouter.modifyLiquidity(keyC, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // ---------------------------------------------------------------- helpers

    function _binding(PoolId id, address actor, uint8 actions) internal returns (TaskBindingLib.TaskBinding memory b) {
        b = TaskBindingLib.TaskBinding({
            taskId: TASK_ID,
            statusHash: COMPLETED,
            evidenceHash: EVIDENCE,
            poolId: PoolId.unwrap(id),
            actor: actor,
            actions: actions,
            maxUses: 1,
            observedAt: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 300),
            epoch: hook.poolConfig(id).epoch,
            chainId: uint64(block.chainid),
            hook: address(hook),
            nonce: nonceCounter++
        });
    }

    function _sign(TaskBindingLib.TaskBinding memory b, uint256 pk) internal pure returns (bytes memory) {
        return _signDomain(b, pk, b.chainId, b.hook);
    }

    function _signDomain(TaskBindingLib.TaskBinding memory b, uint256 pk, uint256 chainId, address verifying)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, TaskBindingLib.digest(b, chainId, verifying));
        return abi.encodePacked(r, s, v);
    }

    function _hookData(TaskBindingLib.TaskBinding memory b) internal view returns (bytes memory) {
        return abi.encode(b, _sign(b, adapterPk));
    }

    function _hookDataWith(TaskBindingLib.TaskBinding memory b, bytes memory sig) internal pure returns (bytes memory) {
        return abi.encode(b, sig);
    }

    function _swap(PoolKey memory k, bytes memory hookData) internal {
        swap(k, true, -100, hookData);
    }

    function _add(PoolKey memory k, bytes memory hookData) internal {
        modifyLiquidityRouter.modifyLiquidity(k, LIQUIDITY_PARAMS, hookData);
    }

    function _wrapped(bytes4 callbackSelector, TaskGateHook.Reason reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callbackSelector,
            abi.encodeWithSelector(TaskGateHook.Rejected.selector, reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _expectSwapReject(TaskGateHook.Reason reason) internal {
        vm.expectRevert(_wrapped(IHooks.beforeSwap.selector, reason));
    }

    function _expectAddReject(TaskGateHook.Reason reason) internal {
        vm.expectRevert(_wrapped(IHooks.beforeAddLiquidity.selector, reason));
    }

    function _submit(TaskBindingLib.TaskBinding memory b, uint256 pk) internal returns (TaskGateHook.Reason) {
        return hook.submitBinding(b, _sign(b, pk));
    }
}
