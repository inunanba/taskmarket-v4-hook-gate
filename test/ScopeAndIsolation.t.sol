// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaskGateFixture} from "./utils/TaskGateFixture.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {TaskBindingLib} from "../src/TaskBindingLib.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/// @notice Pool isolation and callback coverage: only the documented callbacks on allowlisted pools are gated, and
///         nothing outside that scope is accidentally treated as authorized (or consumes authorizations).
contract ScopeAndIsolationTest is TaskGateFixture {
    using PoolIdLibrary for PoolKey;

    function test_permissions_onlySelectedCallbackBits() public view {
        uint160 bits = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(bits, HOOK_FLAGS, "exactly beforeInitialize|beforeAddLiquidity|beforeSwap");
        assertTrue(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_DONATE_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_SWAP_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));
    }

    function test_constructor_rejectsAddressWithWrongPermissionBits() public {
        address wrong = address(uint160(0x5555) << 144 | Hooks.BEFORE_SWAP_FLAG); // missing two required bits
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, wrong));
        deployCodeTo("TaskGateHook.sol:TaskGateHook", abi.encode(manager, owner), wrong);
    }

    function test_unallowlistedPool_cannotInitialize() public {
        PoolKey memory unlisted = PoolKey(currency0, currency1, 100, 1, IHooks(address(hook)));
        vm.expectRevert(_wrapped(IHooks.beforeInitialize.selector, TaskGateHook.Reason.POOL_NOT_ALLOWED));
        manager.initialize(unlisted, SQRT_PRICE_1_1);
    }

    function test_delistedPool_rejectsEvenValidBinding_rollback() public {
        bytes memory hd = _hookData(_binding(idA, address(swapRouter), SWAP));
        vm.prank(owner);
        hook.configurePool(keyA, false, 0, bytes32(0), bytes32(0), 0, 0); // rollback: delist
        _expectSwapReject(TaskGateHook.Reason.POOL_NOT_ALLOWED);
        _swap(keyA, hd);
    }

    function test_poolIsolation_inlineBindingForA_rejectedOnB() public {
        bytes memory hd = _hookData(_binding(idA, address(swapRouter), SWAP));
        _expectSwapReject(TaskGateHook.Reason.WRONG_POOL);
        _swap(keyB, hd);
    }

    function test_poolIsolation_installedGrantOnA_doesNotAuthorizeB() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        b.maxUses = 3;
        _submit(b, adapterPk);
        _expectSwapReject(TaskGateHook.Reason.NO_GRANT);
        _swap(keyB, ZERO_BYTES);
        assertEq(hook.grantOf(idA, address(swapRouter)).usesLeft, 3, "grant on A untouched");
        _swap(keyA, ZERO_BYTES);
    }

    function test_unrelatedPoolWithoutHook_neverCallsHook() public {
        vm.expectCall(address(hook), bytes(""), 0);
        _swap(keyC, ZERO_BYTES);
        _add(keyC, ZERO_BYTES);
    }

    function test_removeLiquidity_isNotGated_andConsumesNothing() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(modifyLiquidityRouter), ADD);
        _submit(b, adapterPk);
        vm.prank(owner);
        hook.setPaused(true); // even while paused LPs can exit
        vm.expectCall(address(hook), abi.encodePacked(IHooks.beforeRemoveLiquidity.selector), 0);
        vm.expectCall(address(hook), abi.encodePacked(IHooks.beforeAddLiquidity.selector), 0);
        modifyLiquidityRouter.modifyLiquidity(keyA, REMOVE_LIQUIDITY_PARAMS, ZERO_BYTES);
        assertEq(hook.grantOf(idA, address(modifyLiquidityRouter)).usesLeft, 1, "grant not consumed");
    }

    function test_removeLiquidity_withBindingAttached_isNotTreatedAsAuthorization() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(modifyLiquidityRouter), ADD);
        modifyLiquidityRouter.modifyLiquidity(keyA, REMOVE_LIQUIDITY_PARAMS, _hookData(b));
        assertFalse(hook.nonceUsed(adapter, b.nonce), "binding passed to an ungated callback is not consumed");
    }

    function test_donate_isNotGated_andConsumesNothing() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(donateRouter), SWAP);
        bytes memory hd = _hookData(b);
        vm.expectCall(address(hook), abi.encodePacked(IHooks.beforeDonate.selector), 0);
        vm.expectCall(address(hook), abi.encodePacked(IHooks.beforeSwap.selector), 0);
        donateRouter.donate(keyA, 100, 100, hd);
        assertFalse(hook.nonceUsed(adapter, b.nonce));
    }

    function test_ungatedActionOnAllowlistedPool_passesWithoutConsuming() public {
        vm.prank(owner);
        hook.configurePool(keyA, true, SWAP, COMPLETED, bytes32(0), MAX_STALENESS, MAX_TTL); // gate swaps only
        _add(keyA, ZERO_BYTES); // add-liquidity no longer gated on A
        _expectSwapReject(TaskGateHook.Reason.NO_GRANT);
        _swap(keyA, ZERO_BYTES);
    }

    function test_disabledCallbacks_revertHookNotImplemented() public {
        vm.startPrank(address(manager));
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.afterInitialize(address(0), keyA, SQRT_PRICE_1_1, 0);
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(0), keyA, LIQUIDITY_PARAMS, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(0), keyA, REMOVE_LIQUIDITY_PARAMS, "");
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(
            address(0), keyA, REMOVE_LIQUIDITY_PARAMS, BalanceDelta.wrap(0), BalanceDelta.wrap(0), ""
        );
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.afterSwap(address(0), keyA, SWAP_PARAMS, BalanceDelta.wrap(0), "");
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.beforeDonate(address(0), keyA, 1, 1, "");
        vm.expectRevert(TaskGateHook.HookNotImplemented.selector);
        hook.afterDonate(address(0), keyA, 1, 1, "");
        vm.stopPrank();
    }

    function test_foreignHookKey_neverAuthorized() public view {
        // previewCallback on a key that points at another hook is POOL_NOT_ALLOWED even if its id were configured.
        PoolKey memory foreign = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0xBEEF)));
        assertEq(
            uint8(hook.previewCallback(foreign, address(swapRouter), SWAP, "")),
            uint8(TaskGateHook.Reason.POOL_NOT_ALLOWED)
        );
    }
}
