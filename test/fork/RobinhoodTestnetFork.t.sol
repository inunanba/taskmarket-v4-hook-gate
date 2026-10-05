// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TaskGateHook} from "../../src/TaskGateHook.sol";
import {TaskBindingLib} from "../../src/TaskBindingLib.sol";

/// @notice OPT-IN fork test against live Robinhood Chain testnet state (FOUNDRY_PROFILE=fork, see README).
///         Requires ROBINHOOD_TESTNET_RPC_URL and RH_TESTNET_POOL_MANAGER. The PoolManager address is NOT hardcoded:
///         the operator supplies it after verifying it (docs/RUNBOOK.md §2). Nothing is broadcast; the fork is local.
contract RobinhoodTestnetForkTest is Test {
    using PoolIdLibrary for PoolKey;

    IPoolManager internal pm;
    TaskGateHook internal hook;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    PoolKey internal key;
    uint256 internal adapterPk = 0xA11CE;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_TESTNET_RPC_URL"));
        pm = IPoolManager(vm.envAddress("RH_TESTNET_POOL_MANAGER"));
    }

    function test_fork_chainIdIsRobinhoodTestnet() public view {
        assertEq(block.chainid, 46630);
    }

    function test_fork_poolManagerHasCode() public view {
        assertGt(address(pm).code.length, 20_000, "expected a full v4 PoolManager runtime");
    }

    function test_fork_gatedLifecycleOnLivePoolManager() public {
        address hookAddr = address(
            uint160(0x7A5C) << 144 | Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        deployCodeTo("TaskGateHook.sol:TaskGateHook", abi.encode(pm, address(this)), hookAddr);
        hook = TaskGateHook(hookAddr);
        hook.setAdapter(vm.addr(adapterPk), true);

        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (a, b) = address(a) < address(b) ? (a, b) : (b, a);
        swapRouter = new PoolSwapTest(pm);
        lpRouter = new PoolModifyLiquidityTest(pm);
        a.mint(address(this), 1e24);
        b.mint(address(this), 1e24);
        a.approve(address(swapRouter), type(uint256).max);
        b.approve(address(swapRouter), type(uint256).max);
        a.approve(address(lpRouter), type(uint256).max);
        b.approve(address(lpRouter), type(uint256).max);

        key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, IHooks(hookAddr));

        // not allowlisted yet -> live PoolManager refuses to initialize through the hook
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(TaskGateHook.Rejected.selector, TaskGateHook.Reason.POOL_NOT_ALLOWED),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        hook.configurePool(key, true, 3, keccak256("completed"), bytes32(0), 600, 900);
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // add liquidity with an inline binding, then swap with an installed grant
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e21, salt: 0}),
            _inline(address(lpRouter), 2, 1)
        );
        TaskBindingLib.TaskBinding memory g = _binding(address(swapRouter), 1, 2);
        assertEq(uint8(hook.submitBinding(g, _sign(g))), uint8(TaskGateHook.Reason.OK));
        _swap("");

        // no grant left -> rejected by the live PoolManager path
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(TaskGateHook.Rejected.selector, TaskGateHook.Reason.NO_GRANT),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swap("");
    }

    function _swap(bytes memory hd) internal {
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hd
        );
    }

    function _binding(address actor, uint8 actions, uint256 nonce)
        internal
        view
        returns (TaskBindingLib.TaskBinding memory)
    {
        return TaskBindingLib.TaskBinding({
            taskId: keccak256("fork-task"),
            statusHash: keccak256("completed"),
            evidenceHash: keccak256("fork-evidence"),
            poolId: PoolId.unwrap(key.toId()),
            actor: actor,
            actions: actions,
            maxUses: 1,
            observedAt: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 300),
            epoch: hook.poolConfig(key.toId()).epoch,
            chainId: uint64(block.chainid),
            hook: address(hook),
            nonce: nonce
        });
    }

    function _sign(TaskBindingLib.TaskBinding memory b) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adapterPk, TaskBindingLib.digest(b, block.chainid, address(hook)));
        return abi.encodePacked(r, s, v);
    }

    function _inline(address actor, uint8 actions, uint256 nonce) internal view returns (bytes memory) {
        TaskBindingLib.TaskBinding memory b = _binding(actor, actions, nonce);
        return abi.encode(b, _sign(b));
    }
}
