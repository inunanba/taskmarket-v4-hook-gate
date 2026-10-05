// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TaskGateFixture} from "./utils/TaskGateFixture.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {TaskBindingLib} from "../src/TaskBindingLib.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/// @notice Every rejection is deterministic: an exact `Rejected(reason)` wrapped by the PoolManager for callbacks, and
///         a non-reverting `BindingRejected(reason)` log for installations.
contract RejectionsTest is TaskGateFixture {
    using PoolIdLibrary for PoolKey;

    TaskBindingLib.TaskBinding internal b;

    function setUp() public override {
        super.setUp();
        b = _binding(idA, address(swapRouter), SWAP);
    }

    // ---- invalid authorization / caller

    function test_missingBinding_noGrant_rejected() public {
        _expectSwapReject(TaskGateHook.Reason.NO_GRANT);
        _swap(keyA, ZERO_BYTES);
    }

    function test_malformedHookData_rejected() public {
        _expectSwapReject(TaskGateHook.Reason.MALFORMED);
        _swap(keyA, hex"deadbeef");
    }

    function test_malformedHookData_dirtyHighBits_rejected() public {
        bytes memory hd = _hookData(b);
        hd[32 * 5] = 0x01; // actions word must be < 256: set a high byte
        _expectSwapReject(TaskGateHook.Reason.MALFORMED);
        _swap(keyA, hd);
    }

    function test_malformedHookData_shortSignature_rejected() public {
        bytes memory hd = _hookDataWith(b, new bytes(64)); // EIP-2098 compact sigs are not accepted
        _expectSwapReject(TaskGateHook.Reason.MALFORMED);
        _swap(keyA, hd);
    }

    function test_malformedBinding_zeroActionsOrUses_rejected() public {
        b.actions = 0;
        _expectSwapReject(TaskGateHook.Reason.MALFORMED);
        _swap(keyA, _hookData(b));
        b.actions = SWAP;
        b.maxUses = 0;
        _expectSwapReject(TaskGateHook.Reason.MALFORMED);
        _swap(keyA, _hookData(b));
    }

    function test_garbageSignature_rejected() public {
        bytes memory sig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(30));
        _expectSwapReject(TaskGateHook.Reason.BAD_SIGNATURE);
        _swap(keyA, _hookDataWith(b, sig));
    }

    function test_highSSignature_rejected() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adapterPk, TaskBindingLib.digest(b, block.chainid, address(hook)));
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory malleable = abi.encodePacked(r, bytes32(n - uint256(s)), v == 27 ? uint8(28) : uint8(27));
        _expectSwapReject(TaskGateHook.Reason.BAD_SIGNATURE);
        _swap(keyA, _hookDataWith(b, malleable));
    }

    function test_unauthorizedSigner_rejected() public {
        _expectSwapReject(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER);
        _swap(keyA, _hookDataWith(b, _sign(b, otherPk)));
    }

    function test_tamperedBinding_rejected() public {
        bytes memory sig = _sign(b, adapterPk);
        b.maxUses = 100; // any field change after signing recovers a different address
        _expectSwapReject(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER);
        _swap(keyA, _hookDataWith(b, sig));
    }

    function test_revokedAdapter_inline_rejected() public {
        vm.prank(owner);
        hook.setAdapter(adapter, false);
        _expectSwapReject(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER);
        _swap(keyA, _hookData(b));
    }

    function test_revokedAdapter_killsInstalledGrant() public {
        _submit(b, adapterPk);
        vm.prank(owner);
        hook.setAdapter(adapter, false);
        _expectSwapReject(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER);
        _swap(keyA, ZERO_BYTES);
    }

    function test_directCallerNotPoolManager_rejected() public {
        bytes memory hd = _hookData(b);
        vm.expectRevert(TaskGateHook.NotPoolManager.selector);
        hook.beforeSwap(address(swapRouter), keyA, SWAP_PARAMS, hd);
        vm.expectRevert(TaskGateHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(modifyLiquidityRouter), keyA, LIQUIDITY_PARAMS, hd);
        vm.expectRevert(TaskGateHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), keyA, SQRT_PRICE_1_1);
    }

    function test_wrongActor_rejected() public {
        b.actor = stranger; // binding for a different router/caller
        _expectSwapReject(TaskGateHook.Reason.WRONG_ACTOR);
        _swap(keyA, _hookData(b));
    }

    function test_wrongAction_rejected() public {
        TaskBindingLib.TaskBinding memory addOnly = _binding(idA, address(swapRouter), ADD);
        _expectSwapReject(TaskGateHook.Reason.WRONG_ACTION);
        _swap(keyA, _hookData(addOnly));
    }

    function test_installedGrant_wrongAction_rejected() public {
        TaskBindingLib.TaskBinding memory swapOnly = _binding(idA, address(modifyLiquidityRouter), SWAP);
        _submit(swapOnly, adapterPk);
        _expectAddReject(TaskGateHook.Reason.WRONG_ACTION);
        _add(keyA, ZERO_BYTES);
    }

    // ---- wrong task state

    function test_wrongStatus_rejected() public {
        b.statusHash = keccak256("open");
        _expectSwapReject(TaskGateHook.Reason.WRONG_STATUS);
        _swap(keyA, _hookData(b));
    }

    function test_wrongTask_rejected() public {
        vm.prank(owner);
        hook.configurePool(keyA, true, BOTH, COMPLETED, keccak256("another task"), MAX_STALENESS, MAX_TTL);
        b.epoch = hook.poolConfig(idA).epoch;
        _expectSwapReject(TaskGateHook.Reason.WRONG_TASK);
        _swap(keyA, _hookData(b));
    }

    // ---- time

    function test_expired_inline_rejected() public {
        bytes memory hd = _hookData(b);
        vm.warp(b.expiry + 1);
        _expectSwapReject(TaskGateHook.Reason.EXPIRED);
        _swap(keyA, hd);
    }

    function test_expired_installedGrant_rejected() public {
        _submit(b, adapterPk);
        vm.warp(b.expiry + 1);
        _expectSwapReject(TaskGateHook.Reason.EXPIRED);
        _swap(keyA, ZERO_BYTES);
    }

    function test_expiryBoundary_inclusive() public {
        bytes memory hd = _hookData(b);
        vm.warp(b.expiry); // still valid at exactly `expiry`
        _swap(keyA, hd);
    }

    function test_staleObservation_rejected() public {
        b.observedAt = uint64(block.timestamp - MAX_STALENESS - 1);
        _expectSwapReject(TaskGateHook.Reason.STALE);
        _swap(keyA, _hookData(b));
    }

    function test_futureObservation_rejected() public {
        b.observedAt = uint64(block.timestamp + 1);
        _expectSwapReject(TaskGateHook.Reason.NOT_YET_VALID);
        _swap(keyA, _hookData(b));
    }

    function test_ttlTooLong_rejected() public {
        b.expiry = b.observedAt + MAX_TTL + 1;
        _expectSwapReject(TaskGateHook.Reason.TTL_TOO_LONG);
        _swap(keyA, _hookData(b));
    }

    // ---- replay

    function test_replayedNonce_inline_rejected() public {
        bytes memory hd = _hookData(b);
        _swap(keyA, hd);
        _expectSwapReject(TaskGateHook.Reason.NONCE_USED);
        _swap(keyA, hd);
    }

    function test_replayedNonce_install_rejectedWithEvent() public {
        bytes memory sig = _sign(b, adapterPk);
        assertEq(uint8(hook.submitBinding(b, sig)), uint8(TaskGateHook.Reason.OK));
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.BindingRejected(
            idA, address(swapRouter), TASK_ID, b.nonce, address(this), TaskGateHook.Reason.NONCE_USED
        );
        assertEq(uint8(hook.submitBinding(b, sig)), uint8(TaskGateHook.Reason.NONCE_USED));
    }

    function test_nonceSharedAcrossModes_inlineThenInstall_rejected() public {
        _swap(keyA, _hookData(b));
        assertEq(uint8(_submit(b, adapterPk)), uint8(TaskGateHook.Reason.NONCE_USED));
    }

    function test_cancelledNonce_rejected() public {
        vm.prank(adapter);
        hook.cancelNonce(b.nonce);
        _expectSwapReject(TaskGateHook.Reason.NONCE_USED);
        _swap(keyA, _hookData(b));
    }

    function test_outdatedBinding_cannotOverwriteNewerGrant() public {
        TaskBindingLib.TaskBinding memory older = _binding(idA, address(swapRouter), SWAP);
        bytes memory olderSig = _sign(older, adapterPk);
        vm.warp(block.timestamp + 30);
        TaskBindingLib.TaskBinding memory newer = _binding(idA, address(swapRouter), SWAP);
        assertEq(uint8(_submit(newer, adapterPk)), uint8(TaskGateHook.Reason.OK));
        // A relayer (or griefer) replaying the older, still-unexpired binding must not roll the grant back.
        assertEq(uint8(hook.submitBinding(older, olderSig)), uint8(TaskGateHook.Reason.OUTDATED));
        assertEq(hook.grantOf(idA, address(swapRouter)).nonce, newer.nonce);
    }

    // ---- chain / domain separation

    function test_wrongChainField_rejected() public {
        b.chainId = 4663; // Robinhood Chain mainnet id
        _expectSwapReject(TaskGateHook.Reason.WRONG_CHAIN);
        _swap(keyA, _hookData(b));
    }

    function test_signedForOtherChainDomain_rejected() public {
        // Field says 46630 but the signature was produced over a domain for chain 8453 (Base, Taskmarket settlement).
        bytes memory sig = _signDomain(b, adapterPk, 8453, address(hook));
        _expectSwapReject(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER);
        _swap(keyA, _hookDataWith(b, sig));
    }

    function test_chainSwitchAfterSigning_rejected() public {
        bytes memory hd = _hookData(b);
        vm.chainId(4663);
        _expectSwapReject(TaskGateHook.Reason.WRONG_CHAIN);
        _swap(keyA, hd);
    }

    function test_wrongHookField_rejected() public {
        b.hook = address(0xBEEF);
        _expectSwapReject(TaskGateHook.Reason.WRONG_HOOK);
        _swap(keyA, _hookData(b));
    }

    function test_signedForOtherVerifyingContract_rejected() public {
        bytes memory sig = _signDomain(b, adapterPk, block.chainid, address(0xBEEF));
        _expectSwapReject(TaskGateHook.Reason.UNAUTHORIZED_ADAPTER);
        _swap(keyA, _hookDataWith(b, sig));
    }

    // ---- configuration-driven fail-closed behaviour

    function test_reconfigure_bumpsEpoch_invalidatesBindingAndGrant() public {
        TaskBindingLib.TaskBinding memory installed = _binding(idA, address(swapRouter), SWAP);
        _submit(installed, adapterPk);
        vm.prank(owner);
        hook.configurePool(keyA, true, BOTH, COMPLETED, bytes32(0), MAX_STALENESS, MAX_TTL);
        _expectSwapReject(TaskGateHook.Reason.WRONG_EPOCH);
        _swap(keyA, ZERO_BYTES);
        _expectSwapReject(TaskGateHook.Reason.WRONG_EPOCH);
        _swap(keyA, _hookData(b));
    }

    function test_paused_failsClosed_forCallbacksAndInstall() public {
        bytes memory hd = _hookData(b);
        vm.prank(owner);
        hook.setPaused(true);
        _expectSwapReject(TaskGateHook.Reason.PAUSED);
        _swap(keyA, hd);
        assertEq(uint8(_submit(_binding(idA, address(swapRouter), SWAP), adapterPk)), uint8(TaskGateHook.Reason.PAUSED));
        vm.prank(owner);
        hook.setPaused(false);
        _swap(keyA, hd);
    }

    function test_revokeGrant_byAdapter_blocksFurtherUse() public {
        b.maxUses = 3;
        _submit(b, adapterPk);
        _swap(keyA, ZERO_BYTES);
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.BindingRevoked(idA, address(swapRouter), adapter);
        vm.prank(adapter);
        hook.revokeGrant(idA, address(swapRouter));
        _expectSwapReject(TaskGateHook.Reason.NO_GRANT);
        _swap(keyA, ZERO_BYTES);
    }

    function test_bindingRejected_isLogged_andChangesNoState() public {
        b.statusHash = keccak256("cancelled");
        vm.expectEmit(true, true, true, true, address(hook));
        emit TaskGateHook.BindingRejected(
            idA, address(swapRouter), TASK_ID, b.nonce, stranger, TaskGateHook.Reason.WRONG_STATUS
        );
        vm.prank(stranger);
        assertEq(uint8(_submit(b, adapterPk)), uint8(TaskGateHook.Reason.WRONG_STATUS));
        assertFalse(hook.nonceUsed(adapter, b.nonce));
        assertEq(hook.grantOf(idA, address(swapRouter)).usesLeft, 0);
    }

    function test_install_actionsNotGatedOnPool_rejected() public {
        vm.prank(owner);
        hook.configurePool(keyA, true, SWAP, COMPLETED, bytes32(0), MAX_STALENESS, MAX_TTL);
        TaskBindingLib.TaskBinding memory both = _binding(idA, address(swapRouter), BOTH);
        assertEq(uint8(_submit(both, adapterPk)), uint8(TaskGateHook.Reason.WRONG_ACTION));
    }

    function test_install_unallowlistedPool_rejected() public {
        PoolKey memory unlisted = PoolKey(currency0, currency1, 100, 1, IHooks(address(hook)));
        TaskBindingLib.TaskBinding memory x = _binding(unlisted.toId(), address(swapRouter), SWAP);
        assertEq(uint8(_submit(x, adapterPk)), uint8(TaskGateHook.Reason.POOL_NOT_ALLOWED));
    }
}
