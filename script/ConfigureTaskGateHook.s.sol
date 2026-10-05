// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";

/// @notice Owner operations and rollback, driven by env. ACTION is one of:
///   allow-pool | delist-pool | pause | unpause | adapter-on | adapter-off | revoke-grant | show
/// Pool actions need CURRENCY0, CURRENCY1 (sorted), FEE, TICK_SPACING; allow-pool also REQUIRED_STATUS (string, e.g.
/// "completed"), GATED_ACTIONS (1 swap, 2 add, 3 both), MAX_STALENESS, MAX_TTL, optional REQUIRED_TASK_ID.
contract ConfigureTaskGateHook is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        TaskGateHook hook = TaskGateHook(vm.envAddress("HOOK"));
        string memory action = vm.envString("ACTION");
        bytes32 a = keccak256(bytes(action));

        if (a == keccak256("show")) {
            PoolKey memory k = _key(hook);
            TaskGateHook.PoolConfig memory c = hook.poolConfig(k.toId());
            console2.logBytes32(PoolId.unwrap(k.toId()));
            console2.log("allowed", c.allowed);
            console2.log("gatedActions", c.gatedActions);
            console2.log("epoch", c.epoch);
            console2.log("paused", hook.paused());
            return;
        }

        vm.startBroadcast();
        if (a == keccak256("allow-pool")) {
            PoolKey memory k = _key(hook);
            hook.configurePool(
                k,
                true,
                uint8(vm.envUint("GATED_ACTIONS")),
                keccak256(bytes(vm.envString("REQUIRED_STATUS"))),
                vm.envOr("REQUIRED_TASK_ID", bytes32(0)),
                uint32(vm.envUint("MAX_STALENESS")),
                uint32(vm.envUint("MAX_TTL"))
            );
            console2.logBytes32(PoolId.unwrap(k.toId()));
        } else if (a == keccak256("delist-pool")) {
            hook.configurePool(_key(hook), false, 0, bytes32(0), bytes32(0), 0, 0);
        } else if (a == keccak256("pause")) {
            hook.setPaused(true);
        } else if (a == keccak256("unpause")) {
            hook.setPaused(false);
        } else if (a == keccak256("adapter-on")) {
            hook.setAdapter(vm.envAddress("ADAPTER"), true);
        } else if (a == keccak256("adapter-off")) {
            hook.setAdapter(vm.envAddress("ADAPTER"), false);
        } else if (a == keccak256("revoke-grant")) {
            hook.revokeGrant(_key(hook).toId(), vm.envAddress("ACTOR"));
        } else {
            revert("unknown ACTION");
        }
        vm.stopBroadcast();
    }

    function _key(TaskGateHook hook) internal view returns (PoolKey memory) {
        return PoolKey(
            Currency.wrap(vm.envAddress("CURRENCY0")),
            Currency.wrap(vm.envAddress("CURRENCY1")),
            uint24(vm.envUint("FEE")),
            int24(vm.envInt("TICK_SPACING")),
            IHooks(address(hook))
        );
    }
}
