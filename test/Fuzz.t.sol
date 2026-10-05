// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaskGateFixture} from "./utils/TaskGateFixture.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {TaskBindingLib} from "../src/TaskBindingLib.sol";

/// @notice Property tests: nothing but a correctly signed, in-scope, fresh, unused binding authorizes.
contract FuzzTest is TaskGateFixture {
    function testFuzz_randomHookData_neverAuthorizes(bytes calldata junk) public view {
        TaskGateHook.Reason r = hook.previewCallback(keyA, address(swapRouter), SWAP, junk);
        assertTrue(r != TaskGateHook.Reason.OK);
    }

    function testFuzz_randomSignerKey_neverAuthorizes(uint256 pk) public {
        pk = bound(pk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140);
        vm.assume(pk != adapterPk);
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        bytes memory hd = _hookDataWith(b, _sign(b, pk));
        assertEq(
            uint8(hook.previewCallback(keyA, address(swapRouter), SWAP, hd)),
            uint8(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER)
        );
    }

    /// Flip any one signed word after signing: the result is never OK.
    function testFuzz_tamperAnySignedWord_rejected(uint8 word, uint256 noise) public {
        word = uint8(bound(word, 0, 12));
        vm.assume(noise != 0);
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        bytes memory hd = _hookData(b);
        // xor only the low 8 bits so narrow-typed fields stay canonical and reach the signature check
        uint256 offset = uint256(word) * 32 + 31;
        hd[offset] = bytes1(uint8(hd[offset]) ^ uint8(noise | 1));
        assertTrue(hook.previewCallback(keyA, address(swapRouter), SWAP, hd) != TaskGateHook.Reason.OK);
    }

    function testFuzz_expiryWindow(uint32 dt) public {
        TaskBindingLib.TaskBinding memory b = _binding(idA, address(swapRouter), SWAP);
        bytes memory hd = _hookData(b);
        vm.warp(block.timestamp + dt);
        TaskGateHook.Reason r = hook.previewCallback(keyA, address(swapRouter), SWAP, hd);
        if (dt <= 300) assertEq(uint8(r), uint8(TaskGateHook.Reason.OK));
        else assertTrue(r == TaskGateHook.Reason.EXPIRED || r == TaskGateHook.Reason.STALE);
    }
}
