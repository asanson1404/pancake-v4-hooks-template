// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolKey} from "@pancakeswap/v4-core/src/types/PoolKey.sol";
import {IVault} from "@pancakeswap/v4-core/src/interfaces/IVault.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@pancakeswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@pancakeswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId, PoolIdLibrary} from "@pancakeswap/v4-core/src/types/PoolId.sol";
import {ICLPoolManager} from "@pancakeswap/v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLBaseHook} from "./CLBaseHook.sol";
import {CLPoolParametersHelper} from "@pancakeswap/v4-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";


/// @notice CLCounterHook is a contract that counts the number of times a hook is called
/// @dev note the code is not production ready, it is only to share how a hook looks like
contract LPLendHook is CLBaseHook {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    mapping(PoolId => uint256 count) public beforeAddLiquidityCount;
    mapping(PoolId => uint256 count) public afterAddLiquidityCount;
    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    address public fakeAaveLendingPool;

    uint256 public numberOfRangeAboveCurrentTick;
    uint256 public numberOfRangeBelowCurrentTick;
    uint256 public numberOfActiveRange;
    int24 public nbTicksBuffer = 100;

    // Create a mapping to store the last known tickLower value for a given Pool
    mapping(PoolId poolId => int24 tickLower) public tickLowerLasts;

    mapping(bytes32 => PositionStatus) public positionStatus;

    bytes32[] public positionIds;

    struct PositionStatus {
        int24 tickLower;
        int24 tickUpper;
        bool tokensWorkingSomewhereElse;
        PoolKey poolKey;
    }

    constructor(ICLPoolManager _poolManager, IVault _vault, address _fakeAaveLendingPool) CLBaseHook(_poolManager) {
        fakeAaveLendingPool = _fakeAaveLendingPool; 
        vault = _vault;
    }

    function getHooksRegistrationBitmap() external pure override returns (uint16) {
        return _hooksRegistrationBitmapFrom(
            Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnsDelta: false,
                afterSwapReturnsDelta: false,
                afterAddLiquidityReturnsDelta: false,
                afterRemoveLiquidityReturnsDelta: false
            })
        );
    }

    function afterInitialize(
        address,
        PoolKey calldata key,
        uint160,
        int24 tick,
        // Add bytes calldata after tick
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        int24 ts = key.parameters.getTickSpacing();
        _setTickLowerLast(key.toId(), getTickLower(tick, ts));
        return LPLendHook.afterInitialize.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta bal,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4, BalanceDelta) {
        bytes32 positionId =
            keccak256(abi.encodePacked(address(vault), params.tickLower, params.tickUpper, bytes32(0)));
        positionIds.push(positionId);

        // Create a PositionStatus
        positionStatus[positionId] = PositionStatus(
            params.tickLower,
            params.tickUpper,
            false,
            key
        );

        return (LPLendHook.afterAddLiquidity.selector, bal);
    }

    function beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        poolManagerOnly
        returns (bytes4, int128)
    {
        // Get the exact current tick and use it to calculate the currentTickLower
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 currentTickLower = getTickLower(currentTick, key.parameters.getTickSpacing());
        int24 lastTickLower = tickLowerLasts[key.toId()];

        bytes32 positionId;
        uint128 liquidityToSend;

        // If tick has increased since last tick (i.e. OneForZero swaps happened)
        if (lastTickLower < currentTickLower) {
            for (uint256 i = 0; i < positionIds.length; i++) {
                positionId = positionIds[i];
                if (positionStatus[positionId].tickLower > currentTickLower + (nbTicksBuffer * key.parameters.getTickSpacing()) ) {
                    liquidityToSend += poolManager.getLiquidity(key.toId(), address(vault), positionStatus[positionId].tickLower, positionStatus[positionId].tickUpper, bytes32(0));
                    positionStatus[positionId].tokensWorkingSomewhereElse = true;
                }
            }
            vault.take(key.currency1, address(this), liquidityToSend);
            key.currency1.transfer(fakeAaveLendingPool, uint256(liquidityToSend));
        } else {
            for (uint256 i = 0; i < positionIds.length; i++) {
                positionId = positionIds[i];
                if (positionStatus[positionId].tickUpper < currentTickLower - (nbTicksBuffer * key.parameters.getTickSpacing()) ) {
                    liquidityToSend += poolManager.getLiquidity(key.toId(), address(vault), positionStatus[positionId].tickLower, positionStatus[positionId].tickUpper, bytes32(0));
                    positionStatus[positionId].tokensWorkingSomewhereElse = true;
                }
            }
        }

        return (LPLendHook.afterSwap.selector, 0);
    }

    function _setTickLowerLast(PoolId poolId, int24 tickLower) private {
        tickLowerLasts[poolId] = tickLower;
    }

    function getTickLower(int24 actualTick, int24 tickSpacing) public pure returns (int24) {
        int24 intervals = actualTick / tickSpacing;
        if (actualTick < 0 && actualTick % tickSpacing != 0) intervals--; // round towards negative infinity
        return intervals * tickSpacing;
    }
}
