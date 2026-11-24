// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerHook} from "../../src/StokerHook.sol";

/// The review of #269's reset (2026-11-24), the reverse of `HoldAttacker`: inside one unlock it sells coins it
/// does not own (flash accounting lets the coin delta go negative), taking the price under the target, then
/// buys exactly the same coins back, so its coin delta closes at zero and it pays only the round trip's fees.
/// Under the first rule it restarted the hour for that; judged by the price a transaction leaves, it does
/// nothing.
contract FlashReset is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable pm;
    StokerHook internal immutable hook;

    /// The hold as recorded, and the pool's price, after the sell and before the buy-back.
    uint256 public holdMidway;
    uint160 public priceMidway;
    /// What the round trip cost, in the Quote Asset.
    uint256 public cost;

    constructor(IPoolManager pm_, StokerHook hook_) {
        pm = pm_;
        hook = hook_;
    }

    function reset(PoolKey calldata key, uint256 coins) external {
        pm.unlock(abi.encode(key, coins));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only the PoolManager");
        (PoolKey memory key, uint256 coins) = abi.decode(data, (PoolKey, uint256));
        bool quoteIs0 = hook.termsOf(key.toId()).quoteIsCurrency0;
        // Sell `coins` it does not hold, exact in, no limit.
        pm.swap(
            key,
            SwapParams({
                zeroForOne: !quoteIs0,
                amountSpecified: -int256(coins),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        holdMidway = hook.graduationOf(key.toId()).holdSince;
        (priceMidway,,,) = StateLibrary.getSlot0(pm, key.toId());
        // Buy exactly the same coins back, exact out.
        pm.swap(
            key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: int256(coins),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        Currency q = quoteIs0 ? key.currency0 : key.currency1;
        Currency c = quoteIs0 ? key.currency1 : key.currency0;
        require(pm.currencyDelta(address(this), c) == 0, "the coin delta closes at zero");
        cost = uint256(-pm.currencyDelta(address(this), q));
        _pay(q, cost);
        return "";
    }

    function _pay(Currency q, uint256 amount) internal {
        if (q.isAddressZero()) {
            pm.settle{value: amount}();
        } else {
            pm.sync(q);
            require(IERC20(Currency.unwrap(q)).transfer(address(pm), amount), "pay");
            pm.settle();
        }
    }

    receive() external payable {}
}

/// A dust buy and a call to `graduate` in one transaction (#244): the call must refuse, since the price in a
/// transaction that has swapped the pool is not one a transaction has left.
contract SwapThenGraduate is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable pm;
    StokerHook internal immutable hook;

    constructor(IPoolManager pm_, StokerHook hook_) {
        pm = pm_;
        hook = hook_;
    }

    function run(PoolKey calldata key, uint256 quoteIn) external {
        pm.unlock(abi.encode(key, quoteIn));
        hook.graduate(key.toId());
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only the PoolManager");
        (PoolKey memory key, uint256 quoteIn) = abi.decode(data, (PoolKey, uint256));
        bool quoteIs0 = hook.termsOf(key.toId()).quoteIsCurrency0;
        pm.swap(
            key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        Currency q = quoteIs0 ? key.currency0 : key.currency1;
        Currency c = quoteIs0 ? key.currency1 : key.currency0;
        uint256 owed = uint256(-pm.currencyDelta(address(this), q));
        if (q.isAddressZero()) {
            pm.settle{value: owed}();
        } else {
            pm.sync(q);
            require(IERC20(Currency.unwrap(q)).transfer(address(pm), owed), "pay");
            pm.settle();
        }
        pm.take(c, address(this), uint256(pm.currencyDelta(address(this), c)));
        return "";
    }

    receive() external payable {}
}
