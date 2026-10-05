// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaskGateFixture} from "./utils/TaskGateFixture.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Access-controlled configuration: only the owner can change config, every change is observable, invalid
///         configs are refused, and ownership moves in two steps.
contract ConfigurationTest is TaskGateFixture {
    function test_unauthorizedConfiguration_reverts() public {
        vm.startPrank(stranger);
        vm.expectRevert(TaskGateHook.NotOwner.selector);
        hook.configurePool(keyA, true, BOTH, COMPLETED, bytes32(0), 1, 1);
        vm.expectRevert(TaskGateHook.NotOwner.selector);
        hook.setAdapter(stranger, true);
        vm.expectRevert(TaskGateHook.NotOwner.selector);
        hook.setPaused(true);
        vm.expectRevert(TaskGateHook.NotOwner.selector);
        hook.transferOwnership(stranger);
        vm.expectRevert(TaskGateHook.NotAdapterOrOwner.selector);
        hook.revokeGrant(idA, address(swapRouter));
        vm.stopPrank();
        // the adapter can sign/revoke but cannot configure
        vm.prank(adapter);
        vm.expectRevert(TaskGateHook.NotOwner.selector);
        hook.configurePool(keyA, true, BOTH, COMPLETED, bytes32(0), 1, 1);
    }

    function test_invalidConfiguration_reverts() public {
        vm.startPrank(owner);
        PoolKey memory foreign = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0xBEEF)));
        vm.expectRevert(TaskGateHook.InvalidConfig.selector);
        hook.configurePool(foreign, true, BOTH, COMPLETED, bytes32(0), 60, 60);
        vm.expectRevert(TaskGateHook.InvalidConfig.selector);
        hook.configurePool(keyA, true, 4, COMPLETED, bytes32(0), 60, 60); // unknown action bit
        vm.expectRevert(TaskGateHook.InvalidConfig.selector);
        hook.configurePool(keyA, true, BOTH, bytes32(0), bytes32(0), 60, 60); // no required status
        vm.expectRevert(TaskGateHook.InvalidConfig.selector);
        hook.configurePool(keyA, true, BOTH, COMPLETED, bytes32(0), 60, 0); // zero TTL
        vm.expectRevert(TaskGateHook.InvalidConfig.selector);
        hook.setAdapter(address(0), true);
        vm.stopPrank();
        vm.expectRevert(TaskGateHook.InvalidConfig.selector);
        new TaskGateHook(manager, address(0));
    }

    function test_configurationEvents_emitted() public {
        uint64 nextEpoch = hook.poolConfig(idA).epoch + 1;
        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.PoolConfigured(idA, true, SWAP, COMPLETED, TASK_ID, 30, 60, nextEpoch);
        hook.configurePool(keyA, true, SWAP, COMPLETED, TASK_ID, 30, 60);

        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.AdapterUpdated(stranger, true);
        hook.setAdapter(stranger, true);

        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.PausedSet(true);
        hook.setPaused(true);

        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.OwnershipTransferStarted(owner, stranger);
        hook.transferOwnership(stranger);
        vm.stopPrank();

        vm.prank(adapter);
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.NonceCancelled(adapter, 77);
        hook.cancelNonce(77);

        TaskGateHook.PoolConfig memory c = hook.poolConfig(idA);
        assertEq(c.gatedActions, SWAP);
        assertEq(c.requiredTaskId, TASK_ID);
        assertEq(c.epoch, nextEpoch);
    }

    function test_twoStepOwnership() public {
        vm.prank(owner);
        hook.transferOwnership(stranger);
        assertEq(hook.owner(), owner, "not transferred until accepted");
        vm.prank(adapter);
        vm.expectRevert(TaskGateHook.NotPendingOwner.selector);
        hook.acceptOwnership();
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.OwnershipTransferred(owner, stranger);
        vm.prank(stranger);
        hook.acceptOwnership();
        assertEq(hook.owner(), stranger);
        assertEq(hook.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(TaskGateHook.NotOwner.selector);
        hook.setPaused(true);
    }

    function test_epochIsMonotonic_acrossDelistAndRelist() public {
        uint64 e0 = hook.poolConfig(idA).epoch;
        vm.startPrank(owner);
        hook.configurePool(keyA, false, 0, bytes32(0), bytes32(0), 0, 0);
        hook.configurePool(keyA, true, BOTH, COMPLETED, bytes32(0), MAX_STALENESS, MAX_TTL);
        vm.stopPrank();
        assertEq(hook.poolConfig(idA).epoch, e0 + 2);
    }
}
