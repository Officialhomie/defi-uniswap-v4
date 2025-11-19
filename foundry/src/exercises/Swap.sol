// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// import {console} from "forge-std/Test.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {SwapParams} from "../types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {CurrencyLib} from "../libraries/CurrencyLib.sol";
import {MIN_SQRT_PRICE, MAX_SQRT_PRICE} from "../Constants.sol";

contract Swap is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLib for address;

    IPoolManager public immutable poolManager;

    struct SwapExactInputSingleHop {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMin;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), "not pool manager");
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
    }

    receive() external payable {}

    function unlockCallback(bytes calldata data)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        // Write your code here

        (address sender, SwapExactInputSingleHop memory params) = abi.decode(data, (address, SwapExactInputSingleHop));

        int256 swapDelta = poolManager.swap({
            key: params.poolKey,
            params: SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -(params.amountIn.toInt256()),
                sqrtPriceLimitX96: params.zeroForOne ?
                MIN_SQRT_PRICE + 1 :
                MAX_SQRT_PRICE - 1
            }),
            hookData: ""
        });

        BalanceDelta delta = BalanceDelta.wrap(swapDelta);

        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        (address currencyIn, address currencyOut, uint256 amountIn, uint256 amountOut) = params.zeroForOne ?
        (
            params.poolKey.currency0,
            params.poolKey.currency1,
            (-amount0).toUint256(),
            amount1.toUint256()
        ) : (
            params.poolKey.currency1,
            params.poolKey.currency0,
            (-amount1).toUint256(),
            amount0.toUint256()
        );

        require(amountOut >= params.amountOutMin, "amount out < min");

        poolManager.take({
            currency: currencyOut,
            to: sender,
            amount: amountOut
        });

        poolManager.sync(currencyIn);

        if (currencyIn == address(0)) {
            poolManager.settle{value: amountIn}();
        } else {
            IERC20(currencyIn).transfer(
                address(poolManager), 
                amountIn
            );
            poolManager.settle();
        }

        return "";
    }

    function swap(SwapExactInputSingleHop calldata params) external payable {
        // Write your code here
        address currency = params.zeroForOne ? 
             params.poolKey.currency0 :
             params.poolKey.currency1;
    
        currency.transferIn(msg.sender, params.amountIn);

        bytes memory data = abi.encode(msg.sender, params);

        poolManager.unlock(data);

        uint256 balance = currency.balanceOf(address(this));

        if (balance > 0) {
            currency.transferOut(msg.sender, balance);
        }

    }
}
