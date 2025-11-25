// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "../interfaces/IERC20.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {SafeCast} from "../libraries/SafeCast.sol";
import {CurrencyLib} from "../libraries/CurrencyLib.sol";
import {StateLibrary} from "../libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "../types/PoolId.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "../types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "../types/BalanceDelta.sol";
import {TStore} from "../TStore.sol";

contract LimitOrder is TStore {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for int128;
    using SafeCast for uint128;
    using CurrencyLib for address;

    error NotPoolManager();

    uint256 constant ADD_LIQUIDITY = 1;
    uint256 constant REMOVE_LIQUIDITY = 2;

    event Place(
        bytes32 indexed poolId,
        uint256 indexed slot,
        address indexed user,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    );
    event Cancel(
        bytes32 indexed poolId,
        uint256 indexed slot,
        address indexed user,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    );
    event Take(
        bytes32 indexed poolId,
        uint256 indexed slot,
        address indexed user,
        int24 tickLower,
        bool zeroForOne,
        uint256 amount0,
        uint256 amount1
    );
    event Fill(
        bytes32 indexed poolId,
        uint256 indexed slot,
        int24 tickLower,
        bool zeroForOne,
        uint256 amount0,
        uint256 amount1
    );

    // Bucket of limit orders
    struct Bucket {
        bool filled;
        uint256 amount0;
        uint256 amount1;
        // Total liquidity
        uint128 liquidity;
        // Liquidity provided per user
        mapping(address => uint128) sizes;
    }

    IPoolManager public immutable poolManager;

    // Bucket id => current slot to place limit orders
    mapping(bytes32 => uint256) public slots;
    // Bucket id => slot => Bucket
    mapping(bytes32 => mapping(uint256 => Bucket)) public buckets;
    // Pool id => last tick
    mapping(PoolId => int24) public ticks;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(address _poolManager) {
        poolManager = IPoolManager(_poolManager);
        Hooks.validateHookPermissions(address(this), getHookPermissions());
    }

    receive() external payable {}

    function getHookPermissions()
        public
        pure
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external onlyPoolManager returns (bytes4) {
        // Write your code here
        PoolId poolId = key.toId();
        ticks[poolId] = tick;
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    )
        external
        onlyPoolManager
        setAction(REMOVE_LIQUIDITY)
        returns (bytes4, int128)
    {
        // Write your code here
        return (this.afterSwap.selector, 0);
    }

    function unlockCallback(bytes calldata data)
        external
        onlyPoolManager
        returns (bytes memory)
    {
        uint256 action = _getAction();

        if (action == ADD_LIQUIDITY) {
            // Write your code here
            (
                address msgSender,
                uint256 msgVal,
                PoolKey memory key,
                int24 tickLower,
                bool zeroForOne,
                uint128 liquidity
            ) = abi.decode(
                data, (address, uint256, PoolKey, int24, bool, uint128)
            );

            (int256 d,) = poolManager.modifyLiquidity({
                key: key,
                params: ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                hookData: ""
            });

            BalanceDelta delta = BalanceDelta.wrap(d);

            int128 amount0 = delta.amount0();
            int128 amount1 = delta.amount1();

            address currency;
            uint256 amountToPay;

            if (zeroForOne) {
                require(amount0 < 0 && amount1 == 0, "Tick Crossed");
            } else {
                require(amount0 == 0 && amount1 < 0, "Tick Crossed");
            }

            currency = zeroForOne ? key.currency0 : key.currency1;
            amountToPay =
                zeroForOne ? (-amount0).toUint256() : (-amount1).toUint256();

            poolManager.sync(currency);

            bool isETH = currency == address(0);

            if (isETH) {
                require(msgVal >= amountToPay, "Not enough ETH sent");

                poolManager.settle{value: amountToPay}();

                bool hasExtra = msgVal > amountToPay;

                uint256 extra = msgVal - amountToPay;

                if (hasExtra) {
                    (bool ok,) = msgSender.call{value: extra}("");

                    require(ok, "Send ETH Failed");
                }
            } else {
                require(msgVal == 0, "received ETH");

                IERC20(currency)
                    .transferFrom(msgSender, address(poolManager), amountToPay);

                poolManager.settle();
            }

            return "";
        } else if (action == REMOVE_LIQUIDITY) {
            // Write your code here
            (
                PoolKey memory key,
                int24 tickLower, 
                uint128 size 
            ) = abi.decode(data, (PoolKey, int24, uint128));

            (int256 d, int256 fee) = poolManager.modifyLiquidity({
                key: key,
                params: ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickLower + key.tickSpacing,
                    liquidityDelta: -int256(uint256(size)),
                    salt: bytes32(0)
                }),
                hookData: ""
            });

            BalanceDelta delta = BalanceDelta.wrap(d);
            uint256 amount0 = 0;
            uint256 amount1 = 0;

            int128 d0 = delta.amount0();
            int128 d1 = delta.amount1();

            if (d0 > 0) {
                amount0 = uint256(uint128(d0));
                poolManager.take(key.currency0, address(this), amount0);
            }

            if (d1 > 0) {
                amount1 = uint256(uint128(d1));
                poolManager.take(key.currency1, address(this), amount1);
            }

            BalanceDelta fees = BalanceDelta.wrap(fee);

            uint256 fee0 = 0;
            uint256 fee1 = 0;

            int128 f0 = fees.amount0();
            int128 f1 = fees.amount1();

            if (f0 > 0) {
                fee0 = uint256(uint128(f0));
            }
            if (f1 > 0) {
                fee1 = uint256(int128(f1));
            }

            return abi.encode(amount0, amount1, fee0, fee1);
        }

        revert("Invalid action");
    }

    function place(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        uint128 liquidity
    ) external payable setAction(ADD_LIQUIDITY) {
        // Write your code here
        require(tickLower % key.tickSpacing == 0, "invalid tick lower");
        require(liquidity > 0, "liquidity = 0");

        PoolId poolId = key.toId();
        int24 currentTick = _getTick(poolId);
        int24 tickUpper = tickLower + key.tickSpacing;

        require(
            currentTick < tickLower || currentTick >= tickUpper, "Tick crossed"
        );

        bytes memory data = abi.encode(
            msg.sender, msg.value, key, tickLower, zeroForOne, liquidity
        );

        poolManager.unlock(data);

        bytes32 id = getBucketId(poolId, tickLower, zeroForOne);

        uint256 slot = slots[id];

        Bucket storage bucket = buckets[id][slot];

        bucket.liquidity += liquidity;

        bucket.sizes[msg.sender] += liquidity;

        emit Place(
            PoolId.unwrap(poolId),
            slot,
            msg.sender,
            tickLower,
            zeroForOne,
            liquidity
        );
    }

    function cancel(PoolKey calldata key, int24 tickLower, bool zeroForOne)
        external
        setAction(REMOVE_LIQUIDITY)
    {
        // Write your code here
        PoolId poolId = key.toId();
        bytes32 id = getBucketId(poolId, tickLower, zeroForOne);

        uint256 slot = slots[id];

        Bucket storage bucket = buckets[id][slot];

        require(!bucket.filled, "bucket filled");

        uint128 size = bucket.sizes[msg.sender];

        require(size > 0, "No amount sized to cancel");

        bucket.liquidity -= size;
        bucket.sizes[msg.sender] = 0;
        bytes memory data = abi.encode(key, tickLower, size);

        bytes memory res = poolManager.unlock(data);

        (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) =
            abi.decode(res, (uint256, uint256, uint256, uint256));

        bool stillHasLiq = bucket.liquidity > 0;

        if (stillHasLiq) {
            // Add fees back to bucket
            bucket.amount0 += fee0;
            bucket.amount1 += fee1;

            // Return principal minus fees
            uint256 refund0 = amount0 > fee0 ? amount0 - fee0 : 0;
            if (refund0 > 0) key.currency0.transferOut(msg.sender, refund0);

            uint256 refund1 = amount1 > fee1 ? amount1 - fee1 : 0;
            if (refund1 > 0) key.currency1.transferOut(msg.sender, refund1);

        } else {
            // User receives all their amounts + accumulated bucket amounts
            amount0 += bucket.amount0;
            bucket.amount0 = 0;
            if (amount0 > 0) key.currency0.transferOut(msg.sender, amount0);

            amount1 += bucket.amount1;
            bucket.amount1 = 0;
            if (amount1 > 0) key.currency1.transferOut(msg.sender, amount1);
        }

        emit Cancel(
            PoolId.unwrap(poolId),
            slot,
            msg.sender,
            tickLower,
            zeroForOne,
            size
        );
    }

    function take(
        PoolKey calldata key,
        int24 tickLower,
        bool zeroForOne,
        uint256 slot
    ) external {
        // Write your code here
    }

    function getBucketId(PoolId poolId, int24 tick, bool zeroForOne)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(PoolId.unwrap(poolId), tick, zeroForOne));
    }

    function getBucket(bytes32 id, uint256 slot)
        public
        view
        returns (
            bool filled,
            uint256 amount0,
            uint256 amount1,
            uint128 liquidity
        )
    {
        Bucket storage bucket = buckets[id][slot];
        return (bucket.filled, bucket.amount0, bucket.amount1, bucket.liquidity);
    }

    function getOrderSize(bytes32 id, uint256 slot, address user)
        public
        view
        returns (uint128)
    {
        return buckets[id][slot].sizes[user];
    }

    function _getTick(PoolId poolId) private view returns (int24 tick) {
        (, tick,,) = StateLibrary.getSlot0(address(poolManager), poolId);
    }

    function _getTickLower(int24 tick, int24 tickSpacing)
        private
        pure
        returns (int24)
    {
        int24 compressed = tick / tickSpacing;
        // Round towards negative infinity
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _getTickRange(int24 tick0, int24 tick1, int24 tickSpacing)
        private
        pure
        returns (int24 lower, int24 upper)
    {
        // Last lower tick
        int24 l0 = _getTickLower(tick0, tickSpacing);
        // Current lower tick
        int24 l1 = _getTickLower(tick1, tickSpacing);

        if (tick0 <= tick1) {
            lower = l0;
            upper = l1 - tickSpacing;
        } else {
            lower = l1 + tickSpacing;
            upper = l0;
        }
    }
}
