// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

/// A stranger at the PoolManager itself, bypassing the router: swaps on, or provides liquidity
/// to, the fund's pool, settling and taking whatever the PoolManager says it owes or is owed.
contract PoolCaller is IUnlockCallback {
    using BalanceDeltaLibrary for BalanceDelta;

    IPoolManager immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) external {
        pm.unlock(abi.encode(key, zeroForOne, amountSpecified, int256(0)));
    }

    /// Adds (or, negative, removes) liquidity around the pool's starting price.
    function modifyLiquidity(PoolKey memory key, int256 liquidityDelta) external {
        pm.unlock(abi.encode(key, false, int256(0), liquidityDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amountSpecified, int256 liquidityDelta) =
            abi.decode(data, (PoolKey, bool, int256, int256));
        BalanceDelta delta;
        if (liquidityDelta == 0) {
            delta = pm.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
        } else {
            (delta,) = pm.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -1, tickUpper: 1, liquidityDelta: liquidityDelta, salt: 0
                }),
                ""
            );
        }
        _close(key.currency0, delta.amount0());
        _close(key.currency1, delta.amount1());
        return "";
    }

    /// Pay what we owe, take what we're owed.
    function _close(Currency currency, int128 amount) internal {
        if (amount < 0) {
            pm.sync(currency);
            ERC20(Currency.unwrap(currency)).transfer(address(pm), uint256(uint128(-amount)));
            pm.settle();
        } else if (amount > 0) {
            pm.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
