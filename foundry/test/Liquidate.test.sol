// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPool} from "../src/interfaces/aave-v3/IPool.sol";
import {IAaveOracle} from "../src/interfaces/aave-v3/IAaveOracle.sol";
import {Flash} from "../src/aave-v3/Flash.sol";
import {Liquidator} from "../src/aave-v3/Liquidator.sol";
import {PoolKey} from "../src/types/PoolKey.sol";
import {AAVE_V3_POOL, AAVE_V3_ORACLE, WETH, USDC} from "../src/Constants.sol";
import {Liquidate} from "@exercises/Liquidate.sol";

/*
forge test --fork-url $FORK_URL --match-path test/Liquidate.test.sol -vvv
*/
contract LiquidateTest is Test {
    IERC20 constant weth = IERC20(WETH);
    IERC20 constant usdc = IERC20(USDC);
    IPool constant pool = IPool(AAVE_V3_POOL);
    IAaveOracle constant oracle = IAaveOracle(AAVE_V3_ORACLE);
    Flash flash;
    Liquidator liquidator;
    Liquidate ex;

    function setUp() public {
        // Fork Ethereum mainnet to access WETH and Aave V3 contracts
        // Use latest block to avoid pruned state issues
        // If FORK_URL env var is set, use it; otherwise use a public RPC endpoint
        string memory forkUrl = vm.envOr("FORK_URL", string("https://eth.llamarpc.com"));
        vm.createSelectFork(forkUrl);
        // Supply to Aave V3
        deal(WETH, address(this), 1e18);
        weth.approve(address(pool), type(uint256).max);
        pool.supply({
            asset: WETH,
            amount: 1e18,
            onBehalfOf: address(this),
            referralCode: 0
        });

        // Borrow from Aave V3
        vm.mockCall(
            AAVE_V3_ORACLE,
            abi.encodeCall(IAaveOracle.getAssetPrice, (WETH)),
            abi.encode(uint256(2000 * 1e8))
        );
        pool.borrow({
            asset: USDC,
            amount: 1000 * 1e6,
            interestRateMode: 2,
            referralCode: 0,
            onBehalfOf: address(this)
        });

        // Mock ETH price. Set it to 500 USD
        uint256 ethPrice = 500 * 1e8;

        vm.mockCall(
            AAVE_V3_ORACLE,
            abi.encodeCall(IAaveOracle.getAssetPrice, (WETH)),
            abi.encode(ethPrice)
        );

        flash = new Flash();
        liquidator = new Liquidator();
        ex = new Liquidate(address(flash), address(liquidator));
        // deal(USDC, address(ex), 10000 * 1e6);
    }

    function test_liquidate() public {
        (uint256 colUsdBefore, uint256 debtUsdBefore,,,,) =
            pool.getUserAccountData(address(this));

        ex.liquidate({
            tokenToRepay: USDC,
            user: address(this),
            key: PoolKey({
                currency0: address(0),
                currency1: USDC,
                fee: 500,
                tickSpacing: 10,
                hooks: address(0)
            })
        });

        (uint256 colUsdAfter, uint256 debtUsdAfter,,,,) =
            pool.getUserAccountData(address(this));

        // Check liquidation
        assertLt(colUsdAfter, colUsdBefore, "USD collateral after");
        assertLt(debtUsdAfter, debtUsdBefore, "USD debt after");

        // Check profit
        uint256 usdcBal = usdc.balanceOf(address(this));
        console.log("USDC balance: %e", usdcBal);
        assertGe(usdcBal, 0, "USDC balance");
    }
}
