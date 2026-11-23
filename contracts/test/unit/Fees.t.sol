// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The hook only keeps the books (ADR 0025): every swap takes the 1.00% Platform Fee on the Quote
/// Asset's side and records it as two Credits, the Creator's and the platform's, with no transfer.
contract FeesTest is LocalBase {
    using StateLibrary for IPoolManager;

    /// What a trader and the books saw on one swap, measured from outside.
    struct Seen {
        uint256 quoteIn; // Quote Asset the trader paid (buys)
        uint256 quoteOut; // Quote Asset the trader received (sells)
        uint256 fee; // what the hook's claims grew by
        uint256 creatorCredit;
        uint256 platformCredit;
    }

    function _swapAndSee(PoolKey memory key, bool buy, bool exactIn, uint256 amount) internal returns (Seen memory s) {
        uint256 q0 = quote.balanceOf(trader);
        uint256 claims0 = _hookClaims();
        uint256 c0 = _credit(creator);
        uint256 p0 = _credit(platform);
        uint256 creatorQuote0 = quote.balanceOf(creator);
        uint256 platformQuote0 = quote.balanceOf(platform);
        _swap(key, trader, buy, exactIn, amount);
        uint256 q1 = quote.balanceOf(trader);
        if (q0 > q1) s.quoteIn = q0 - q1;
        else s.quoteOut = q1 - q0;
        s.fee = _hookClaims() - claims0;
        s.creatorCredit = _credit(creator) - c0;
        s.platformCredit = _credit(platform) - p0;
        // No transfer to either recipient inside the swap.
        assertEq(quote.balanceOf(creator), creatorQuote0, "no transfer to the creator");
        assertEq(quote.balanceOf(platform), platformQuote0, "no transfer to the platform");
        // The Credits of the swap sum to the fee taken, split by the Launch's terms.
        assertEq(s.creatorCredit + s.platformCredit, s.fee, "credits sum to the fee");
        assertEq(s.creatorCredit, s.fee * CREATOR_SHARE_BPS / 10_000, "creator's share");
        // The hook holds no ERC-20 at all: the fee stays in the PoolManager as claims.
        assertEq(quote.balanceOf(address(hook)), 0, "hook holds no quote");
    }

    function test_fee_buyExactIn() public {
        for (uint256 i; i < 2; i++) {
            (, PoolKey memory key) = _launch(i == 0, 0);
            Seen memory s = _swapAndSee(key, true, true, 10 ether);
            assertEq(s.quoteIn, 10 ether, "paid the specified amount");
            assertEq(s.fee, _feeOnGross(10 ether), "1.00% of what the trader paid");
            assertEq(s.fee, 0.1 ether);
        }
    }

    function test_fee_buyExactOut() public {
        for (uint256 i; i < 2; i++) {
            (address coin, PoolKey memory key) = _launch(i == 0, 0);
            uint256 coinsBefore = _coin(key).balanceOf(trader);
            Seen memory s = _swapAndSee(key, true, false, 1e9 ether);
            assertEq(_coin(key).balanceOf(trader) - coinsBefore, 1e9 ether, "received the specified coins");
            assertEq(s.fee, _feeOnNet(s.quoteIn - s.fee), "1.00% of what the trader paid, fee included");
            assertApproxEqAbs(s.fee * 10_000, s.quoteIn * PLATFORM_FEE_BPS, 10_000, "about 1.00% of the gross");
            coin;
        }
    }

    function test_fee_sellExactIn() public {
        for (uint256 i; i < 2; i++) {
            (address coin, PoolKey memory key) = _launch(i == 0, 0);
            _swap(key, trader, true, true, 50 ether);
            uint256 coins = _coin(key).balanceOf(trader);
            Seen memory s = _swapAndSee(key, false, true, coins / 2);
            assertEq(s.fee, _feeOnGross(s.quoteOut + s.fee), "1.00% of the pool's output");
            coin;
        }
    }

    function test_fee_sellExactOut() public {
        for (uint256 i; i < 2; i++) {
            (, PoolKey memory key) = _launch(i == 0, 0);
            _swap(key, trader, true, true, 50 ether);
            Seen memory s = _swapAndSee(key, false, false, 10 ether);
            assertEq(s.quoteOut, 10 ether, "received the specified Quote Asset");
            assertEq(s.fee, _feeOnNet(10 ether), "1.00% of the pool's output, fee included");
        }
    }

    function test_fee_eventSaysTheSame() public {
        (, PoolKey memory key) = _launch(true, 0);
        uint256 fee = _feeOnGross(10 ether);
        uint256 creatorCredit = fee * CREATOR_SHARE_BPS / 10_000;
        _approveRouter(key, trader);
        vm.expectEmit(true, true, true, true, address(hook));
        emit StokerHook.FeeCredited(key.toId(), _quoteCurrency(), creator, fee, creatorCredit, fee - creatorCredit);
        _swapApproved(key, trader, true, true, 10 ether);
    }

    function testFuzz_fee_creditsAlwaysSumToTheFee(bool q0, bool buy, bool exactIn, uint256 amount) public {
        (, PoolKey memory key) = _launch(q0, 0);
        _swap(key, trader, true, true, 100 ether);
        if (buy) amount = bound(amount, 1e6, exactIn ? 1_000 ether : 1e10 ether);
        else amount = bound(amount, 1e6, exactIn ? _coin(key).balanceOf(trader) : 50 ether);
        Seen memory s = _swapAndSee(key, buy, exactIn, amount);
        uint256 expected;
        if (buy && exactIn) expected = _feeOnGross(s.quoteIn);
        else if (buy) expected = _feeOnNet(s.quoteIn - s.fee);
        else if (exactIn) expected = _feeOnGross(s.quoteOut + s.fee);
        else expected = _feeOnNet(s.quoteOut);
        assertEq(s.fee, expected, "the fee is 1.00% of the Quote Asset's side");
    }

    function test_fee_noFeeOnTheCoinSide() public {
        // A sell pays its fee in the Quote Asset, never in the coin: every coin sold reaches the pool.
        (, PoolKey memory key) = _launch(true, 0);
        _swap(key, trader, true, true, 50 ether);
        uint256 coins = _coin(key).balanceOf(trader);
        uint256 poolCoins = _coin(key).balanceOf(address(pm));
        _swap(key, trader, false, true, coins);
        assertEq(_coin(key).balanceOf(address(pm)) - poolCoins, coins);
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(_coin(key))))), 0, "no coin claims");
    }

    function test_fee_tinySwapCannotBeSwallowed() public {
        // A 1-wei exact-in buy would leave nothing to swap after a fee rounded up; it reverts instead of
        // becoming a swap the hook consumed whole.
        (, PoolKey memory key) = _launch(true, 0);
        _approveRouter(key, trader);
        vm.expectRevert();
        _swapApproved(key, trader, true, true, 1);
    }

    // ------------------------------------------------ a swap its own price limit stops early

    /// A price limit `ticks` away from the pool's price, in the direction a buy or a sell moves it.
    function _limit(PoolKey memory key, bool buy, int24 ticks) internal view returns (uint160) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        bool zeroForOne = buy == _isQuote0(key);
        return TickMath.getSqrtPriceAtTick(zeroForOne ? tick - ticks : tick + ticks);
    }

    function _swapWithLimit(PoolKey memory key, bool buy, bool exactIn, uint256 amount, uint160 limit) internal {
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: buy == _isQuote0(key),
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The hook's `SwapStoppedEarly`, as the PoolManager wraps a hook's revert from `afterSwap`.
    function _stoppedEarly() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(StokerHook.SwapStoppedEarly.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// When the Quote Asset is the specified side the fee is taken before the pool runs, on the whole
    /// specified amount. A price limit that stops such a swap early would leave the trader paying 1.00%
    /// of what they asked for, not of what they traded (measured in review: a fee of 1 on a buy of 1.5),
    /// so the hook refuses it.
    function test_fee_quoteSpecifiedSwapStoppedByItsLimit_reverts() public {
        for (uint256 i; i < 2; i++) {
            (, PoolKey memory key) = _launch(i == 0, 0);
            _swap(key, trader, true, true, 50 ether);
            _approveRouter(key, trader);

            // An exact-in buy of 100 that its limit stops after a fraction.
            uint160 buyLimit = _limit(key, true, 400);
            vm.expectRevert(_stoppedEarly());
            _swapWithLimit(key, true, true, 100 ether, buyLimit);

            // An exact-out sell of 40 that its limit stops after a fraction.
            uint160 sellLimit = _limit(key, false, 400);
            vm.expectRevert(_stoppedEarly());
            _swapWithLimit(key, false, false, 40 ether, sellLimit);

            // The same limits leave a swap they do not stop alone.
            uint256 claims0 = _hookClaims();
            _swapWithLimit(key, true, true, 0.01 ether, buyLimit);
            assertEq(_hookClaims() - claims0, _feeOnGross(0.01 ether), "a limit that does not bind changes nothing");
            claims0 = _hookClaims();
            _swapWithLimit(key, false, false, 0.01 ether, _limit(key, false, 400));
            assertEq(_hookClaims() - claims0, _feeOnNet(0.01 ether));
        }
    }

    /// When the coin is the specified side the fee is taken after the pool runs, on the Quote Asset that
    /// really moved, so a swap its limit stops early still pays exactly 1.00% of the Quote Asset's side.
    function test_fee_coinSpecifiedSwapStoppedByItsLimit_paysOnWhatItTraded() public {
        for (uint256 i; i < 2; i++) {
            (, PoolKey memory key) = _launch(i == 0, 0);
            _swap(key, trader, true, true, 50 ether);
            _approveRouter(key, trader);

            // An exact-out buy of far more coins than the limit lets through.
            uint256 q0 = quote.balanceOf(trader);
            uint256 c0 = _coin(key).balanceOf(trader);
            uint256 claims0 = _hookClaims();
            _swapWithLimit(key, true, false, 1e11 ether, _limit(key, true, 400));
            uint256 fee = _hookClaims() - claims0;
            assertLt(_coin(key).balanceOf(trader) - c0, 1e11 ether, "stopped early");
            assertGt(fee, 0);
            assertEq(fee, _feeOnNet(q0 - quote.balanceOf(trader) - fee), "1.00% of what the buy really paid");

            // An exact-in sell of far more coins than the limit lets through.
            q0 = quote.balanceOf(trader);
            c0 = _coin(key).balanceOf(trader);
            claims0 = _hookClaims();
            _swapWithLimit(key, false, true, c0, _limit(key, false, 400));
            fee = _hookClaims() - claims0;
            assertLt(c0 - _coin(key).balanceOf(trader), c0, "stopped early");
            assertGt(fee, 0);
            assertEq(fee, _feeOnGross(quote.balanceOf(trader) - q0 + fee), "1.00% of what the pool really paid");
        }
    }
}
