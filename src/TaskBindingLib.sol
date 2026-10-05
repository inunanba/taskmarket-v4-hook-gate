// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TaskBindingLib
/// @notice Compact, EIP-712 typed "task binding": an off-chain adapter's signed statement that a Taskmarket task
///         was observed in a given status at a given time, authorizing one actor to perform selected actions on one
///         v4 pool until an expiry. Taskmarket itself settles on Base Mainnet; nothing here touches that settlement.
library TaskBindingLib {
    /// @dev Action bits. A binding may authorize one or both gated actions.
    uint8 internal constant ACTION_SWAP = 1;
    uint8 internal constant ACTION_ADD_LIQUIDITY = 2;
    uint8 internal constant ACTION_MASK = ACTION_SWAP | ACTION_ADD_LIQUIDITY;

    struct TaskBinding {
        bytes32 taskId; // Taskmarket task id (the 32-byte `id` returned by GET /api/tasks/{id})
        bytes32 statusHash; // keccak256(bytes(status)) as observed, e.g. keccak256("completed")
        bytes32 evidenceHash; // keccak256 of the exact raw HTTP response body the adapter preserved
        bytes32 poolId; // v4 PoolId the binding is valid for
        address actor; // the `sender` the PoolManager passes to the hook (router / caller of PoolManager)
        uint8 actions; // bitmask of ACTION_SWAP / ACTION_ADD_LIQUIDITY
        uint32 maxUses; // number of gated callbacks this binding may authorize once installed (>= 1)
        uint64 observedAt; // unix seconds of the adapter's final (re-)fetch
        uint64 expiry; // unix seconds; invalid when block.timestamp > expiry
        uint64 epoch; // pool configuration epoch the adapter read; any re-configuration invalidates it
        uint64 chainId; // explicit chain id (also in the EIP-712 domain); 46630 on Robinhood Chain testnet
        address hook; // explicit verifying hook (also in the EIP-712 domain)
        uint256 nonce; // single-use per adapter signer
    }

    bytes32 internal constant TYPEHASH = keccak256(
        "TaskBinding(bytes32 taskId,bytes32 statusHash,bytes32 evidenceHash,bytes32 poolId,address actor,uint8 actions,uint32 maxUses,uint64 observedAt,uint64 expiry,uint64 epoch,uint64 chainId,address hook,uint256 nonce)"
    );

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant NAME_HASH = keccak256("TaskGateHook");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    function structHash(TaskBinding memory b) internal pure returns (bytes32) {
        // All members are static, so abi.encode lays them out word-by-word as EIP-712 encodeData requires.
        return keccak256(abi.encode(TYPEHASH, b));
    }

    function domainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, chainId, verifyingContract));
    }

    function digest(TaskBinding memory b, uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(chainId, verifyingContract), structHash(b)));
    }
}
