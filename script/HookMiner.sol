// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Minimal CREATE2 salt miner: finds a salt whose resulting address carries exactly `flags` in the low 14 bits
///         (Uniswap v4 encodes hook permissions in the hook address).
library HookMiner {
    uint256 internal constant MAX_LOOP = 200_000;

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & Hooks.ALL_HOOK_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i; i < MAX_LOOP; ++i) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags) return (hookAddress, salt);
        }
        revert("HookMiner: no salt found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
