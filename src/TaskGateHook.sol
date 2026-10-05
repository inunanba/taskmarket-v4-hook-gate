// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {TaskBindingLib} from "./TaskBindingLib.sol";

/// @title TaskGateHook
/// @notice Testnet prototype. A Uniswap v4 hook that gates `beforeSwap` and `beforeAddLiquidity` on allowlisted pools
///         behind a Taskmarket task binding signed by an authorized off-chain adapter. `beforeInitialize` only admits
///         allowlisted pools. Everything else (remove liquidity, donate, all after* callbacks) is deliberately NOT
///         hooked. Taskmarket settles on Base Mainnet; this contract never touches Taskmarket funds or settlement.
/// @dev Two delivery modes share one validator:
///      1. Install: anyone relays `submitBinding(binding, sig)`; on success a grant is stored and `BindingUpdated` is
///         emitted, on failure the call does NOT revert, nothing is stored and `BindingRejected(reason)` is emitted,
///         so rejections leave an on-chain record. Gated callbacks with empty hookData then consume the grant.
///      2. Inline: `hookData = abi.encode(binding, sig)` is verified and consumed atomically for exactly one callback.
///      Every failure inside a callback reverts `Rejected(reason)` (fail closed).
contract TaskGateHook is IHooks {
    using PoolIdLibrary for PoolKey;

    enum Reason {
        OK,
        PAUSED,
        POOL_NOT_ALLOWED,
        MALFORMED,
        WRONG_CHAIN,
        WRONG_HOOK,
        WRONG_POOL,
        WRONG_ACTION,
        WRONG_ACTOR,
        WRONG_TASK,
        WRONG_STATUS,
        WRONG_EPOCH,
        NOT_YET_VALID,
        STALE,
        EXPIRED,
        TTL_TOO_LONG,
        BAD_SIGNATURE,
        UNAUTHORIZED_ADAPTER,
        NONCE_USED,
        OUTDATED,
        NO_GRANT
    }

    struct PoolConfig {
        bool allowed;
        uint8 gatedActions; // TaskBindingLib.ACTION_* bits that require authorization on this pool
        uint32 maxStaleness; // max seconds between the adapter's observation and use/installation
        uint32 maxTtl; // max seconds between observation and binding expiry
        uint64 epoch; // bumped on every (re)configuration; invalidates older bindings and grants
        bytes32 requiredStatus; // keccak256 of the Taskmarket status string that unlocks this pool
        bytes32 requiredTaskId; // optional: 0 = any task id
    }

    struct Grant {
        bytes32 taskId;
        bytes32 evidenceHash;
        address adapter;
        uint64 observedAt;
        uint64 expiry;
        uint64 epoch;
        uint32 usesLeft;
        uint8 actions;
        uint256 nonce;
    }

    error NotPoolManager();
    error NotOwner();
    error NotPendingOwner();
    error NotAdapterOrOwner();
    error InvalidConfig();
    error HookNotImplemented();
    error Rejected(Reason reason);

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event AdapterUpdated(address indexed adapter, bool authorized);
    event PausedSet(bool paused);
    event PoolConfigured(
        PoolId indexed poolId,
        bool allowed,
        uint8 gatedActions,
        bytes32 requiredStatus,
        bytes32 requiredTaskId,
        uint32 maxStaleness,
        uint32 maxTtl,
        uint64 epoch
    );
    event BindingUpdated(
        PoolId indexed poolId,
        address indexed actor,
        bytes32 indexed taskId,
        address adapter,
        uint256 nonce,
        uint8 actions,
        uint32 maxUses,
        uint64 expiry,
        bytes32 evidenceHash
    );
    event BindingRejected(
        PoolId indexed poolId,
        address indexed actor,
        bytes32 indexed taskId,
        uint256 nonce,
        address relayer,
        Reason reason
    );
    event BindingRevoked(PoolId indexed poolId, address indexed actor, address indexed by);
    event AuthorizationGranted(
        PoolId indexed poolId,
        address indexed actor,
        bytes32 indexed taskId,
        uint8 action,
        address adapter,
        uint256 nonce,
        bytes32 evidenceHash,
        bool inlineBinding,
        uint32 usesLeft
    );
    event NonceCancelled(address indexed adapter, uint256 indexed nonce);

    IPoolManager public immutable poolManager;
    address public owner;
    address public pendingOwner;
    bool public paused;

    mapping(address => bool) public isAdapter;
    mapping(PoolId => PoolConfig) internal _pools;
    mapping(PoolId => mapping(address => Grant)) internal _grants;
    mapping(address => mapping(uint256 => bool)) public nonceUsed;

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager, address _owner) {
        if (address(_poolManager) == address(0) || _owner == address(0)) revert InvalidConfig();
        poolManager = _poolManager;
        owner = _owner;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        emit OwnershipTransferred(address(0), _owner);
    }

    /// @notice beforeInitialize + beforeAddLiquidity + beforeSwap only. No return-delta flags: the hook never moves value.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------------------------------------------------
    // Configuration (owner only, every change emits an event)
    // ------------------------------------------------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }

    function setAdapter(address adapter, bool authorized) external onlyOwner {
        if (adapter == address(0)) revert InvalidConfig();
        isAdapter[adapter] = authorized;
        emit AdapterUpdated(adapter, authorized);
    }

    /// @notice Global kill switch: while paused every gated action and every installation fails closed.
    ///         Remove-liquidity is never hooked, so LPs can always exit.
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    /// @notice Allowlist / reconfigure / delist a pool. Always bumps the pool epoch, invalidating outstanding grants.
    function configurePool(
        PoolKey calldata key,
        bool allowed,
        uint8 gatedActions,
        bytes32 requiredStatus,
        bytes32 requiredTaskId,
        uint32 maxStaleness,
        uint32 maxTtl
    ) external onlyOwner {
        if (address(key.hooks) != address(this)) revert InvalidConfig();
        if (gatedActions & ~TaskBindingLib.ACTION_MASK != 0) revert InvalidConfig();
        if (allowed && (requiredStatus == bytes32(0) || maxTtl == 0)) revert InvalidConfig();
        PoolId id = key.toId();
        PoolConfig storage cfg = _pools[id];
        uint64 epoch = cfg.epoch + 1;
        _pools[id] = PoolConfig({
            allowed: allowed,
            gatedActions: gatedActions,
            maxStaleness: maxStaleness,
            maxTtl: maxTtl,
            epoch: epoch,
            requiredStatus: requiredStatus,
            requiredTaskId: requiredTaskId
        });
        emit PoolConfigured(id, allowed, gatedActions, requiredStatus, requiredTaskId, maxStaleness, maxTtl, epoch);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Binding lifecycle
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Install (or replace) the grant described by an adapter-signed binding. Never reverts on a bad binding:
    ///         returns the reason and emits `BindingRejected` so relayers and monitors get an on-chain record.
    function submitBinding(TaskBindingLib.TaskBinding calldata b, bytes calldata signature)
        external
        returns (Reason reason)
    {
        address signer;
        (reason, signer) = _validate(b, signature, PoolId.wrap(b.poolId), 0, b.actor, true);
        if (reason != Reason.OK) {
            emit BindingRejected(PoolId.wrap(b.poolId), b.actor, b.taskId, b.nonce, msg.sender, reason);
            return reason;
        }
        nonceUsed[signer][b.nonce] = true;
        _grants[PoolId.wrap(b.poolId)][b.actor] = Grant({
            taskId: b.taskId,
            evidenceHash: b.evidenceHash,
            adapter: signer,
            observedAt: b.observedAt,
            expiry: b.expiry,
            epoch: b.epoch,
            usesLeft: b.maxUses,
            actions: b.actions,
            nonce: b.nonce
        });
        emit BindingUpdated(
            PoolId.wrap(b.poolId), b.actor, b.taskId, signer, b.nonce, b.actions, b.maxUses, b.expiry, b.evidenceHash
        );
    }

    /// @notice Owner or any authorized adapter can revoke a grant (e.g. the task left the required status).
    function revokeGrant(PoolId poolId, address actor) external {
        if (msg.sender != owner && !isAdapter[msg.sender]) revert NotAdapterOrOwner();
        delete _grants[poolId][actor];
        emit BindingRevoked(poolId, actor, msg.sender);
    }

    /// @notice An adapter can pre-burn one of its own nonces (cancels a signed but unused binding).
    function cancelNonce(uint256 nonce) external {
        nonceUsed[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views (monitoring / adapter pre-flight). They return exactly what the state-changing paths would decide.
    // ------------------------------------------------------------------------------------------------------------

    function poolConfig(PoolId poolId) external view returns (PoolConfig memory) {
        return _pools[poolId];
    }

    function grantOf(PoolId poolId, address actor) external view returns (Grant memory) {
        return _grants[poolId][actor];
    }

    function domainSeparator() external view returns (bytes32) {
        return TaskBindingLib.domainSeparator(block.chainid, address(this));
    }

    function hashBinding(TaskBindingLib.TaskBinding calldata b) external view returns (bytes32) {
        return TaskBindingLib.digest(b, block.chainid, address(this));
    }

    function previewBinding(TaskBindingLib.TaskBinding calldata b, bytes calldata signature)
        external
        view
        returns (Reason reason, address signer)
    {
        return _validate(b, signature, PoolId.wrap(b.poolId), 0, b.actor, true);
    }

    function previewCallback(PoolKey calldata key, address sender, uint8 action, bytes calldata hookData)
        external
        view
        returns (Reason reason)
    {
        (reason,,) = _check(key, sender, action, hookData);
    }

    /// @notice Canonical hookData layout accepted by the inline path: `abi.encode(TaskBinding, bytes signature)` with
    ///         a 65-byte r||s||v signature, i.e. exactly 576 bytes. Anything else is MALFORMED (never a revert).
    uint256 public constant HOOKDATA_LENGTH = 576;

    // ------------------------------------------------------------------------------------------------------------
    // Hook callbacks
    // ------------------------------------------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (paused) revert Rejected(Reason.PAUSED);
        if (!_pools[key.toId()].allowed) revert Rejected(Reason.POOL_NOT_ALLOWED);
        return IHooks.beforeInitialize.selector;
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4) {
        _gate(key, sender, TaskBindingLib.ACTION_ADD_LIQUIDITY, hookData);
        return IHooks.beforeAddLiquidity.selector;
    }

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata hookData)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _gate(key, sender, TaskBindingLib.ACTION_SWAP, hookData);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // Out-of-scope callbacks: their permission bits are off, so the PoolManager never calls them.
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Kinds returned by `_check` so `_gate` knows which state to mutate.
    uint8 private constant KIND_UNGATED = 0;
    uint8 private constant KIND_INLINE = 1;
    uint8 private constant KIND_GRANT = 2;

    function _gate(PoolKey calldata key, address sender, uint8 action, bytes calldata hookData) internal {
        (Reason reason, uint8 kind, address signer) = _check(key, sender, action, hookData);
        if (reason != Reason.OK) revert Rejected(reason);
        if (kind == KIND_UNGATED) return;
        PoolId id = key.toId();
        if (kind == KIND_INLINE) {
            // Already proven canonical by _check, so this decode cannot revert.
            (TaskBindingLib.TaskBinding memory b,) = abi.decode(hookData, (TaskBindingLib.TaskBinding, bytes));
            nonceUsed[signer][b.nonce] = true;
            emit AuthorizationGranted(id, sender, b.taskId, action, signer, b.nonce, b.evidenceHash, true, 0);
        } else {
            Grant storage g = _grants[id][sender];
            uint32 left = g.usesLeft - 1;
            g.usesLeft = left;
            emit AuthorizationGranted(id, sender, g.taskId, action, g.adapter, g.nonce, g.evidenceHash, false, left);
        }
    }

    function _check(PoolKey calldata key, address sender, uint8 action, bytes calldata hookData)
        internal
        view
        returns (Reason, uint8 kind, address signer)
    {
        PoolId id = key.toId();
        PoolConfig storage cfg = _pools[id];
        if (address(key.hooks) != address(this) || !cfg.allowed) {
            return (Reason.POOL_NOT_ALLOWED, KIND_UNGATED, address(0));
        }
        if (cfg.gatedActions & action == 0) return (Reason.OK, KIND_UNGATED, address(0));
        if (paused) return (Reason.PAUSED, KIND_UNGATED, address(0));

        if (hookData.length != 0) {
            if (!_isCanonicalHookData(hookData)) return (Reason.MALFORMED, KIND_INLINE, address(0));
            (TaskBindingLib.TaskBinding memory b, bytes memory sig) =
                abi.decode(hookData, (TaskBindingLib.TaskBinding, bytes));
            Reason r;
            (r, signer) = _validate(b, sig, id, action, sender, false);
            return (r, KIND_INLINE, signer);
        }

        Grant storage g = _grants[id][sender];
        if (g.usesLeft == 0) return (Reason.NO_GRANT, KIND_GRANT, address(0));
        if (g.epoch != cfg.epoch) return (Reason.WRONG_EPOCH, KIND_GRANT, address(0));
        if (!isAdapter[g.adapter]) return (Reason.UNAUTHORIZED_ADAPTER, KIND_GRANT, address(0));
        if (block.timestamp > g.expiry) return (Reason.EXPIRED, KIND_GRANT, address(0));
        if (g.actions & action == 0) return (Reason.WRONG_ACTION, KIND_GRANT, address(0));
        return (Reason.OK, KIND_GRANT, g.adapter);
    }

    /// @dev Strict structural check so that untrusted bytes can never make `abi.decode` revert: fixed length, fixed
    ///      offset/length words, and every narrow-typed field must be zero-padded. No external call is needed.
    function _isCanonicalHookData(bytes calldata d) internal pure returns (bool) {
        if (d.length != HOOKDATA_LENGTH) return false;
        uint256[15] memory w;
        for (uint256 i; i < 15; ++i) {
            w[i] = uint256(bytes32(d[i * 32:(i + 1) * 32]));
        }
        return w[4] >> 160 == 0 // actor
            && w[5] >> 8 == 0 // actions
            && w[6] >> 32 == 0 // maxUses
            && w[7] >> 64 == 0 && w[8] >> 64 == 0 && w[9] >> 64 == 0 && w[10] >> 64 == 0 // u64 fields
            && w[11] >> 160 == 0 // hook
            && w[13] == 0x1c0 // offset of `signature` (13 static words + 1 offset word = 14 * 32)
            && w[14] == 65; // signature length
    }

    /// @dev Deterministic, documented decision order. `install` = submitBinding context (no callback in flight).
    function _validate(
        TaskBindingLib.TaskBinding memory b,
        bytes memory signature,
        PoolId ctxPool,
        uint8 ctxAction,
        address ctxActor,
        bool install
    ) internal view returns (Reason, address) {
        if (paused) return (Reason.PAUSED, address(0));
        if (b.actions == 0 || b.actions & ~TaskBindingLib.ACTION_MASK != 0 || b.maxUses == 0 || b.actor == address(0)) {
            return (Reason.MALFORMED, address(0));
        }
        if (b.chainId != block.chainid) return (Reason.WRONG_CHAIN, address(0));
        if (b.hook != address(this)) return (Reason.WRONG_HOOK, address(0));
        if (PoolId.unwrap(ctxPool) != b.poolId) return (Reason.WRONG_POOL, address(0));
        PoolConfig storage cfg = _pools[ctxPool];
        if (!cfg.allowed) return (Reason.POOL_NOT_ALLOWED, address(0));
        if (install ? (b.actions & ~cfg.gatedActions != 0) : (b.actions & ctxAction == 0)) {
            return (Reason.WRONG_ACTION, address(0));
        }
        if (b.actor != ctxActor) return (Reason.WRONG_ACTOR, address(0));
        if (cfg.requiredTaskId != bytes32(0) && b.taskId != cfg.requiredTaskId) return (Reason.WRONG_TASK, address(0));
        if (b.statusHash != cfg.requiredStatus) return (Reason.WRONG_STATUS, address(0));
        if (b.epoch != cfg.epoch) return (Reason.WRONG_EPOCH, address(0));
        if (b.observedAt > block.timestamp) return (Reason.NOT_YET_VALID, address(0));
        if (block.timestamp - b.observedAt > cfg.maxStaleness) return (Reason.STALE, address(0));
        if (block.timestamp > b.expiry) return (Reason.EXPIRED, address(0));
        if (b.expiry - b.observedAt > cfg.maxTtl) return (Reason.TTL_TOO_LONG, address(0));

        (address signer, ECDSA.RecoverError err,) =
            ECDSA.tryRecover(TaskBindingLib.digest(b, block.chainid, address(this)), signature);
        if (err != ECDSA.RecoverError.NoError) return (Reason.BAD_SIGNATURE, address(0));
        if (!isAdapter[signer]) return (Reason.UNAUTHORIZED_ADAPTER, signer);
        if (nonceUsed[signer][b.nonce]) return (Reason.NONCE_USED, signer);
        if (install) {
            Grant storage g = _grants[ctxPool][b.actor];
            if (g.usesLeft != 0 && g.epoch == cfg.epoch && b.observedAt < g.observedAt) {
                return (Reason.OUTDATED, signer);
            }
        }
        return (Reason.OK, signer);
    }
}
