// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerHook} from "../../src/StokerHook.sol";

/// The spike review's forced Graduation as a flash loan (#244): inside one unlock of the PoolManager it buys
/// across the Graduation Target and sells every coin straight back, so it needs no coins and only the
/// round trip's cost in the Quote Asset. It records what the hook said between the two swaps.
contract HoldAttacker is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager internal immutable pm;
    StokerHook internal immutable hook;

    /// The hold's start as the hook reported it after the buy and before the sell.
    uint256 public holdSeenMidway;
    /// The pool's price after the buy and before the sell.
    uint160 public priceMidway;
    /// What the round trip cost, in the Quote Asset.
    uint256 public cost;

    constructor(IPoolManager pm_, StokerHook hook_) {
        pm = pm_;
        hook = hook_;
    }

    function roundTrip(PoolKey calldata key, uint256 quoteIn) external {
        pm.unlock(abi.encode(key, quoteIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "only the PoolManager");
        (PoolKey memory key, uint256 quoteIn) = abi.decode(data, (PoolKey, uint256));
        bool quoteIs0 = hook.termsOf(key.toId()).quoteIsCurrency0;

        BalanceDelta bought = pm.swap(
            key,
            SwapParams({
                zeroForOne: quoteIs0,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        int128 coins = quoteIs0 ? bought.amount1() : bought.amount0();
        holdSeenMidway = hook.graduationOf(key.toId()).holdSince;
        (priceMidway,,,) = StateLibrary.getSlot0(pm, key.toId());

        pm.swap(
            key,
            SwapParams({
                zeroForOne: !quoteIs0,
                amountSpecified: -int256(coins),
                sqrtPriceLimitX96: quoteIs0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // The coin's delta is closed; only the round trip's cost is owed, in the Quote Asset.
        Currency q = quoteIs0 ? key.currency0 : key.currency1;
        cost = uint256(-pm.currencyDelta(address(this), q));
        if (q.isAddressZero()) {
            pm.settle{value: cost}();
        } else {
            pm.sync(q);
            require(IERC20(Currency.unwrap(q)).transfer(address(pm), cost), "pay");
            pm.settle();
        }
        return "";
    }

    receive() external payable {}
}
