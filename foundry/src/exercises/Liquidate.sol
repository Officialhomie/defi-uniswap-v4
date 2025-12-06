// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {IPermit2} from "../interfaces/IPermit2.sol";
import {IUniversalRouter} from "../interfaces/IUniversalRouter.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {Actions} from "../libraries/Actions.sol";
import {Commands} from "../libraries/Commands.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {UNIVERSAL_ROUTER, PERMIT2, WETH} from "../Constants.sol";

interface IFlash {
    function flash(address token, uint256 amount, bytes calldata data) external;
}

interface IFlashReceiver {
    function flashCallback(
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external;
}

interface ILiquidator {
    function getDebt(address token, address user)
        external
        view
        returns (uint256);
    function liquidate(address collateral, address borrowedToken, address user)
        external;
}

contract Liquidate is IFlashReceiver {
    IUniversalRouter constant router = IUniversalRouter(UNIVERSAL_ROUTER);
    IPermit2 constant permit2 = IPermit2(PERMIT2);
    IWETH constant weth = IWETH(WETH);
    IFlash public immutable flash;
    ILiquidator public immutable liquidator;

    constructor(address _flash, address _liquidator) {
        flash = IFlash(_flash);
        liquidator = ILiquidator(_liquidator);
    }

    receive() external payable {}

    function liquidate(
        // Token to flash loan
        address tokenToRepay,
        // User to liquidate
        address user,
        // V4 pool to swap collateral
        PoolKey calldata key
    ) external {
        // Write your code here
        // Get token amount to liquidate
        // Flash loan
        // Send profit to msg.sender

        (address v4Token0, address v4Token1) = (key.currency0, key.currency1);

        if (v4Token0 == address(0)) {
            v4Token0 = WETH;
        }
        if (v4Token1 == address(0)) {
            v4Token1 = WETH;
        }

        require(tokenToRepay == v4Token0 || tokenToRepay == v4Token1, "invalid pool key");
        uint256 debt = liquidator.getDebt(tokenToRepay, user);

        bytes memory data = abi.encode(user, key);

        flash.flash(tokenToRepay, debt, data);

        uint256 bal = IERC20(tokenToRepay).balanceOf(address(this));

        if (bal > 0) {
            IERC20(tokenToRepay).transfer(msg.sender, bal);
        }
    }

    function flashCallback(
        address tokenToRepay,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external {
        // Write your code here
        // decode user and key from data
        (address user, PoolKey memory key) = abi.decode(data, (address, PoolKey));

        // get v4 token0 and v4 token1
        (address v4Token0, address v4Token1) = (key.currency0, key.currency1);

        // validate and map address(0) to WETH
        if(v4Token0 == address(0)) {
            v4Token0 = WETH;
        }
        if(v4Token1 == address(0)) {
            v4Token1 = WETH;
        }

        // get collateral token which is the other token in the pool
        // if tokenToRepay is v4Token0, then collateral is v4Token1
        // if tokenToRepay is v4Token1, then collateral is v4Token0
        address collateral = tokenToRepay == v4Token0 
            ? v4Token1 
            : v4Token0;

        // approve liquidator to spend tokenToRepay
        IERC20(tokenToRepay).approve(address(liquidator), amount);

        // liquidate which will transfer tokenToRepay from user to liquidator
        // and liquidate the user's debt
        
        liquidator.liquidate(collateral, tokenToRepay, user);

        // get balance of collateral in this contract
        uint256 colBal = IERC20(collateral).balanceOf(address(this));

        // unwrap WETH if collateral is WETH
        if (collateral == WETH) {
            weth.withdraw(colBal);
        }

        // determine if collateral is token0 or token1
        bool zeroForOne = collateral == v4Token0;

        // swap collateral to tokenToRepay
        swap({
            key: key,
            amountIn: uint128(colBal),
            amountOutMin: 1,
            zeroForOne: zeroForOne
        });

        // Check original key value to determine if swap output was ETH (address(0))
        // The swap function uses the original key, so if key.currency0/currency1 is address(0),
        // we receive ETH and need to wrap it to WETH
        // Note: zeroForOne uses mapped values (v4Token0/v4Token1), but we check the original
        // key values here because the swap function outputs ETH when key.currency0/currency1 is address(0)
        address originalCurrencyOut = zeroForOne ? key.currency1 : key.currency0;
        if(originalCurrencyOut == address(0)) {
            weth.deposit{value: address(this).balance}();
        }

        uint256 bal = IERC20(tokenToRepay).balanceOf(address(this));

        require(bal >= amount + fee, "insufficient amount to repay flash loan");
        IERC20(tokenToRepay).transfer(address(flash), amount + fee);
    }

    function swap(
        PoolKey memory key,
        uint128 amountIn,
        uint128 amountOutMin,
        bool zeroForOne
    ) private {
        (address currencyIn, address currencyOut) = zeroForOne
            ? (key.currency0, key.currency1)
            : (key.currency1, key.currency0);

        if (currencyIn != address(0)) {
            approve(currencyIn, uint160(amountIn), uint48(block.timestamp));
        }

        // UniversalRouter inputs
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        // V4 actions and params
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        // SWAP_EXACT_IN_SINGLE
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                hookData: bytes("")
            })
        );
        // SETTLE_ALL (currency, max amount)
        params[1] = abi.encode(currencyIn, uint256(amountIn));
        // TAKE_ALL (currency, min amount)
        params[2] = abi.encode(currencyOut, uint256(amountOutMin));

        // Universal router input
        inputs[0] = abi.encode(actions, params);

        uint256 msgVal = currencyIn == address(0) ? address(this).balance : 0;
        router.execute{value: msgVal}(commands, inputs, block.timestamp);
    }

    function approve(address token, uint160 amount, uint48 expiration) private {
        IERC20(token).approve(address(permit2), uint256(amount));
        permit2.approve(token, address(router), amount, expiration);
    }
}
