// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {TaskGateHook} from "../src/TaskGateHook.sol";
import {HookMiner} from "./HookMiner.sol";

/// @notice LOCAL ANVIL ONLY (requires chain id 31337 and LOCAL_STACK_OK=1). Deploys a fresh v4 PoolManager, test tokens/routers, the hook (CREATE2-mined), one
///         swap-gated pool, and writes deployments/local.json. Used by scripts/e2e-local.sh.
contract LocalStack is Script {
    using PoolIdLibrary for PoolKey;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        require(vm.envOr("LOCAL_STACK_OK", uint256(0)) == 1, "set LOCAL_STACK_OK=1 (local anvil only)");
        require(block.chainid == 31337, "local anvil (31337) only");
        address adapter = vm.envAddress("ADAPTER");
        vm.startBroadcast();
        address me = msg.sender;
        PoolManager pm = new PoolManager(me);
        MockERC20 t0 = new MockERC20("Test0", "T0", 18);
        MockERC20 t1 = new MockERC20("Test1", "T1", 18);
        if (address(t0) > address(t1)) (t0, t1) = (t1, t0);
        PoolSwapTest swapRouter = new PoolSwapTest(pm);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);

        uint160 flags = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;
        (, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(TaskGateHook).creationCode, abi.encode(address(pm), me));
        TaskGateHook hook = new TaskGateHook{salt: salt}(IPoolManager(address(pm)), me);

        PoolKey memory key =
            PoolKey(Currency.wrap(address(t0)), Currency.wrap(address(t1)), 3000, 60, IHooks(address(hook)));
        hook.setAdapter(adapter, true);
        hook.configurePool(key, true, 1, keccak256("completed"), bytes32(0), 600, 900); // gate swaps only
        pm.initialize(key, TickMath.getSqrtPriceAtTick(0));

        t0.mint(me, 1e24);
        t1.mint(me, 1e24);
        t0.approve(address(swapRouter), type(uint256).max);
        t1.approve(address(swapRouter), type(uint256).max);
        t0.approve(address(lpRouter), type(uint256).max);
        t1.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e21, salt: 0}),
            ""
        );
        vm.stopBroadcast();

        string memory o = "local";
        vm.serializeAddress(o, "poolManager", address(pm));
        vm.serializeAddress(o, "hook", address(hook));
        vm.serializeAddress(o, "swapRouter", address(swapRouter));
        vm.serializeAddress(o, "lpRouter", address(lpRouter));
        vm.serializeAddress(o, "currency0", address(t0));
        vm.serializeAddress(o, "currency1", address(t1));
        string memory out = vm.serializeBytes32(o, "poolId", PoolId.unwrap(key.toId()));
        vm.writeJson(out, "deployments/local.json");
        console2.log("hook", address(hook));
    }
}

/// @notice LOCAL ANVIL ONLY: one exact-input swap through PoolSwapTest with EMPTY hookData (uses an installed grant).
contract LocalSwap is Script {
    function run() external {
        require(vm.envOr("LOCAL_STACK_OK", uint256(0)) == 1 && block.chainid == 31337, "local anvil only");
        string memory j = vm.readFile("deployments/local.json");
        PoolKey memory key = PoolKey(
            Currency.wrap(vm.parseJsonAddress(j, ".currency0")),
            Currency.wrap(vm.parseJsonAddress(j, ".currency1")),
            3000,
            60,
            IHooks(vm.parseJsonAddress(j, ".hook"))
        );
        PoolSwapTest router = PoolSwapTest(vm.parseJsonAddress(j, ".swapRouter"));
        vm.startBroadcast();
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopBroadcast();
    }
}
