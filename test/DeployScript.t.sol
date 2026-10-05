// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {DeployTaskGateHook} from "../script/DeployTaskGateHook.s.sol";

/// @notice The real deployment script (CREATE2 + salt mining, no cheatcode placement) yields a valid hook.
contract DeployScriptTest is Test, Deployers {
    function test_deployScript_minesAddressWithExactPermissionBits() public {
        deployFreshManager();
        vm.chainId(46630);
        address pmAddr = address(manager);
        TaskGateHook hook = new DeployTaskGateHook().deploy(pmAddr, address(0xA11CE), 46630);
        assertEq(
            uint160(address(hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
        assertEq(hook.owner(), address(0xA11CE));
        assertEq(address(hook.poolManager()), address(manager));
    }

    function test_deployScript_refusesWrongChain() public {
        deployFreshManager();
        vm.chainId(1);
        address pmAddr = address(manager);
        DeployTaskGateHook s = new DeployTaskGateHook();
        vm.expectRevert(bytes("wrong chain: EXPECTED_CHAIN_ID mismatch"));
        s.deploy(pmAddr, address(0xA11CE), 46630);
    }

    function test_deployScript_refusesPoolManagerWithoutCode() public {
        vm.chainId(46630);
        address pmAddr = address(0xdead);
        DeployTaskGateHook s = new DeployTaskGateHook();
        vm.expectRevert(bytes("POOL_MANAGER has no code on this chain"));
        s.deploy(pmAddr, address(0xA11CE), 46630);
    }
}
