// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaskGateFixture} from "./utils/TaskGateFixture.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {TaskBindingLib} from "../src/TaskBindingLib.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @notice Allowed paths through a real v4 PoolManager: inline (hookData) and installed (submitBinding) bindings.
contract AuthorizationTest is TaskGateFixture {
    function test_inline_validBinding_allowsSwap_andEmitsDecision() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.AuthorizationGranted(
            idA, address(swapRouter), TASK_ID, SWAP, adapter, b.nonce, EVIDENCE, true, 0
        );
        _swap(keyA, _hookData(b));
        assertTrue(hook.nonceUsed(adapter, b.nonce), "nonce consumed");
    }

    function test_inline_validBinding_allowsAddLiquidity() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(modifyLiquidityRouter), ADD);
        _add(keyA, _hookData(b));
        assertTrue(hook.nonceUsed(adapter, b.nonce));
    }

    function test_install_emitsBindingUpdated_thenGrantAuthorizesExactlyMaxUses() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        b.maxUses = 2;
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.BindingUpdated(
            idA, address(swapRouter), TASK_ID, adapter, b.nonce, SWAP, 2, b.expiry, EVIDENCE
        );
        vm.prank(stranger); // relaying is permissionless; the adapter signature is what authorizes
        assertEq(uint8(_submit(b, adapterPk)), uint8(TaskGateHook.Reason.OK));

        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.AuthorizationGranted(
            idA, address(swapRouter), TASK_ID, SWAP, adapter, b.nonce, EVIDENCE, false, 1
        );
        _swap(keyA, ZERO_BYTES);
        _swap(keyA, ZERO_BYTES);
        assertEq(hook.grantOf(idA, address(swapRouter)).usesLeft, 0);

        _expectSwapReject(TaskGateHook.Reason.NO_GRANT);
        _swap(keyA, ZERO_BYTES);
    }

    function test_install_bothActions_singleGrantCoversSwapAndAdd() public {
        // A router that is both swap and LP actor does not exist in v4 test utils, so bind each router separately and
        // show that a BOTH binding authorizes the action the callback actually asks for.
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(modifyLiquidityRouter), BOTH);
        assertEq(uint8(_submit(b, adapterPk)), uint8(TaskGateHook.Reason.OK));
        _add(keyA, ZERO_BYTES);
    }

    function test_install_grantPersistsStoredEvidence() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        _submit(b, adapterPk);
        TaskGateHook.Grant memory g = hook.grantOf(idA, address(swapRouter));
        assertEq(g.taskId, TASK_ID);
        assertEq(g.evidenceHash, EVIDENCE);
        assertEq(g.adapter, adapter);
        assertEq(g.nonce, b.nonce);
        assertEq(g.expiry, b.expiry);
    }

    function test_newerBinding_replacesGrant() public {
        TaskBindingLib.TaskBinding memory b1 = _binding(idA, address(swapRouter), SWAP);
        _submit(b1, adapterPk);
        vm.warp(block.timestamp + 10);
        TaskBindingLib.TaskBinding memory b2 = _binding(idA, address(swapRouter), SWAP);
        b2.maxUses = 5;
        assertEq(uint8(_submit(b2, adapterPk)), uint8(TaskGateHook.Reason.OK));
        assertEq(hook.grantOf(idA, address(swapRouter)).usesLeft, 5);
        assertEq(hook.grantOf(idA, address(swapRouter)).nonce, b2.nonce);
    }

    function test_pinnedTaskId_acceptsMatchingTask() public {
        vm.prank(owner);
        hook.configurePool(keyA, true, BOTH, COMPLETED, TASK_ID, MAX_STALENESS, MAX_TTL);
        _swap(keyA, _hookData(_binding(idA, address(swapRouter), SWAP)));
    }

    function test_previewCallback_matchesOutcome() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        bytes memory hd = _hookData(b);
        assertEq(uint8(hook.previewCallback(keyA, address(swapRouter), SWAP, hd)), uint8(TaskGateHook.Reason.OK));
        assertEq(
            uint8(hook.previewCallback(keyB, address(swapRouter), SWAP, hd)), uint8(TaskGateHook.Reason.WRONG_POOL)
        );
        assertEq(uint8(hook.previewCallback(keyA, stranger, SWAP, hd)), uint8(TaskGateHook.Reason.WRONG_ACTOR));
        assertEq(
            uint8(hook.previewCallback(keyA, address(swapRouter), SWAP, ZERO_BYTES)),
            uint8(TaskGateHook.Reason.NO_GRANT)
        );
        _swap(keyA, hd);
        assertEq(
            uint8(hook.previewCallback(keyA, address(swapRouter), SWAP, hd)), uint8(TaskGateHook.Reason.NONCE_USED)
        );
    }

    function test_previewBinding_returnsSignerAndReason() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        (TaskGateHook.Reason r, address signer) = hook.previewBinding(b, _sign(b, adapterPk));
        assertEq(uint8(r), uint8(TaskGateHook.Reason.OK));
        assertEq(signer, adapter);
        // preview has no side effects
        assertFalse(hook.nonceUsed(adapter, b.nonce));
        assertEq(hook.grantOf(idA, address(swapRouter)).usesLeft, 0);
    }

    function test_hashBinding_matchesLibraryDigest() public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        assertEq(hook.hashBinding(b), TaskBindingLib.digest(b, 46630, address(hook)));
        assertEq(hook.domainSeparator(), TaskBindingLib.domainSeparator(46630, address(hook)));
    }
}
