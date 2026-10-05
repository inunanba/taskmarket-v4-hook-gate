// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice Deploy TaskGateHook through the deterministic CREATE2 deployer at an address carrying the permission bits.
/// Env (all REQUIRED, nothing is defaulted or invented):
///   POOL_MANAGER  v4 PoolManager on the target chain (verify it yourself; see docs/RUNBOOK.md)
///   HOOK_OWNER    owner of the hook config (use a testnet-only address / multisig)
///   EXPECTED_CHAIN_ID  e.g. 46630 for Robinhood Chain testnet; the script refuses to run on any other chain
contract DeployTaskGateHook is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    function run() external returns (TaskGateHook) {
        return deploy(vm.envAddress("POOL_MANAGER"), vm.envAddress("HOOK_OWNER"), vm.envUint("EXPECTED_CHAIN_ID"));
    }

    function deploy(address pm, address owner, uint256 expectedChain) public returns (TaskGateHook hook) {
        require(block.chainid == expectedChain, "wrong chain: EXPECTED_CHAIN_ID mismatch");
        require(pm.code.length > 0, "POOL_MANAGER has no code on this chain");
        require(CREATE2_DEPLOYER.code.length > 0, "CREATE2 deployer missing on this chain");

        bytes memory args = abi.encode(pm, owner);
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, FLAGS, type(TaskGateHook).creationCode, args);

        vm.startBroadcast();
        hook = new TaskGateHook{salt: salt}(IPoolManager(pm), owner);
        vm.stopBroadcast();

        require(address(hook) == predicted, "CREATE2 address mismatch");
        console2.log("chainId", block.chainid);
        console2.log("TaskGateHook", address(hook));
        console2.log("PoolManager", pm);
        console2.log("owner", owner);
        console2.logBytes32(salt);
    }
}
