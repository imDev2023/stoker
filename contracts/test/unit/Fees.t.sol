// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The hook only keeps the books (ADR 0025): every swap takes the 1.00% Platform Fee on the Quote
/// Asset's side and records it as two Credits, the Creator's and the platform's, with no transfer.
contract FeesTest is LocalBase {
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
}
