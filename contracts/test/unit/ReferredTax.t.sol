// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// A trade that names a referrer on a Reward Launch (#243 with #245): the Platform Fee, the Referrer Fee and
/// the tax are each their own rate of the Quote Asset's side, taken together, in all four swap types, with
/// the coin as currency0, as currency1 and paired with the native asset; the Credits take the fee and the
/// Referrer Fee, the Tax Vault the tax.
contract ReferredTaxTest is TaxLocalBase {
    address internal referrer = makeAddr("frontEnd");
    uint256 internal constant REF_BPS = 75; // under the Listing's cap of 1.00%

    struct Seen {
        uint256 quoteIn;
        uint256 quoteOut;
        uint256 taken; // what the hook's claims grew by: the Platform Fee and the Referrer Fee
        uint256 referrerFee;
        uint256 tax;
    }

    function _kind(uint256 kind) internal returns (PoolKey memory) {
        if (kind == 2) {
            return _launchNativeTyped(StokerHook.LaunchType.Reward, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        }
        return _launchReward(kind == 1, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
    }

    function _referredSwap(PoolKey memory key, bool buy, bool exactIn, uint256 amount)
        internal
        returns (Seen memory s)
    {
        vm.startPrank(trader);
        _coinOfKey(key).approve(address(swapRouter), type(uint256).max);
        if (!_native(key)) quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        uint256 q0 = _quoteBalanceOf(key, trader);
        uint256 h0 = _hookClaimsOf(key);
        uint256 r0 = hook.creditOf(referrer, _quoteOfKey(key));
        uint256 t0 = _taxBooked(key);
        bool zeroForOne = buy == _quoteIsCurrency0(key);
        vm.prank(trader);
        swapRouter.swap{value: _native(key) && buy ? trader.balance / 2 : 0}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(referrer, REF_BPS)
        );
        uint256 q1 = _quoteBalanceOf(key, trader);
        if (q0 > q1) s.quoteIn = q0 - q1;
        else s.quoteOut = q1 - q0;
        s.taken = _hookClaimsOf(key) - h0;
        s.referrerFee = hook.creditOf(referrer, _quoteOfKey(key)) - r0;
        s.tax = _taxBooked(key) - t0;
    }

    function _assertFour(uint256 kind) internal {
        PoolKey memory key = _kind(kind);
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        _trade(key, trader, true, true, 40 * u);
        uint256 total = PLATFORM_FEE_BPS + REF_BPS + TAX_BPS;
        bool[2][4] memory types = [[true, true], [true, false], [false, true], [false, false]];
        for (uint256 i; i < 4; i++) {
            (bool buy, bool exactIn) = (types[i][0], types[i][1]);
            uint256 amount =
                buy ? (exactIn ? 5 * u : 1e9 ether) : (exactIn ? _coinOfKey(key).balanceOf(trader) / 4 : 2 * u);
            Seen memory s = _referredSwap(key, buy, exactIn, amount);
            uint256 fee = s.taken - s.referrerFee;
            uint256 pf;
            uint256 rf;
            uint256 tx_;
            if (buy && exactIn) {
                (pf, rf, tx_) =
                (_rateOfGross(amount, PLATFORM_FEE_BPS), _rateOfGross(amount, REF_BPS), _rateOfGross(amount, TAX_BPS));
                assertEq(s.quoteIn, amount, "paid the specified amount, all three included");
            } else if (buy) {
                uint256 net = s.quoteIn - s.taken - s.tax;
                (pf, rf, tx_) =
                (
                    _rateOfNet(net, PLATFORM_FEE_BPS, total),
                    _rateOfNet(net, REF_BPS, total),
                    _rateOfNet(net, TAX_BPS, total)
                );
            } else if (exactIn) {
                uint256 gross = s.quoteOut + s.taken + s.tax;
                (pf, rf, tx_) =
                (_rateOfGross(gross, PLATFORM_FEE_BPS), _rateOfGross(gross, REF_BPS), _rateOfGross(gross, TAX_BPS));
            } else {
                (pf, rf, tx_) =
                (
                    _rateOfNet(amount, PLATFORM_FEE_BPS, total),
                    _rateOfNet(amount, REF_BPS, total),
                    _rateOfNet(amount, TAX_BPS, total)
                );
                assertEq(s.quoteOut, amount, "received the specified amount");
            }
            assertEq(fee, pf, "the Platform Fee, its own rate");
            assertEq(s.referrerFee, rf, "the Referrer Fee, credited to the referrer");
            assertEq(s.tax, tx_, "the tax, to the Tax Vault");
            assertGt(rf, 0);
            assertGt(tx_, 0);
        }
    }

    function test_referredTax_fourSwapTypes_coinIsCurrency0() public {
        _assertFour(0);
    }

    function test_referredTax_fourSwapTypes_coinIsCurrency1() public {
        _assertFour(1);
    }

    function test_referredTax_fourSwapTypes_native() public {
        _assertFour(2);
    }
}
