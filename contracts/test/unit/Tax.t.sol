// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The Reward Tax and the Stoke Tax in the swap (#245, ADR 0025): every swap of a coin with a tax moves
/// exactly its rate of the Quote Asset's side to the Tax Vault's books, beside the Platform Fee, in all four
/// swap types, with the coin as currency0, as currency1 and paired with the native asset; nothing else is
/// done with it in the swap.
contract TaxTest is TaxLocalBase {
    using StateLibrary for IPoolManager;

    /// What a trader and the books saw on one swap, measured from outside.
    struct Seen {
        uint256 quoteIn; // Quote Asset the trader paid (buys)
        uint256 quoteOut; // Quote Asset the trader received (sells)
        uint256 fee; // what the hook's claims grew by
        uint256 tax; // what the pool's booked tax grew by
        uint256 vaultClaims; // what the Tax Vault's claims grew by
    }

    /// 0: the coin is currency0; 1: the coin is currency1; 2: paired with the native asset.
    function _launchKind(uint256 kind, StokerHook.LaunchType launchType, uint16 taxBps)
        internal
        returns (PoolKey memory key)
    {
        address q = kind == 2 ? address(0) : address(quote);
        uint16 liquidityShare = launchType == StokerHook.LaunchType.Reward ? 2_500 : 0;
        uint16 burnShare = launchType == StokerHook.LaunchType.Reward ? 2_500 : 0;
        if (launchType == StokerHook.LaunchType.Standard) taxBps = 0;
        (, key) = _launchWith(
            _typedParams(
                q, kind == 1, 0, launchType, taxBps, burnShare, liquidityShare, StokerHook.PayoutAsset.QuoteAsset
            )
        );
    }

    function _unit(PoolKey memory key) internal pure returns (uint256) {
        return _native(key) ? 0.05 ether : 1 ether;
    }

    function _swapAndSee(PoolKey memory key, bool buy, bool exactIn, uint256 amount) internal returns (Seen memory s) {
        uint256 q0 = _quoteBalanceOf(key, trader);
        uint256 fee0 = _hookClaimsOf(key);
        uint256 tax0 = _taxBooked(key);
        uint256 vault0 = _vaultClaims(key);
        _trade(key, trader, buy, exactIn, amount);
        uint256 q1 = _quoteBalanceOf(key, trader);
        if (q0 > q1) s.quoteIn = q0 - q1;
        else s.quoteOut = q1 - q0;
        s.fee = _hookClaimsOf(key) - fee0;
        s.tax = _taxBooked(key) - tax0;
        s.vaultClaims = _vaultClaims(key) - vault0;
        assertEq(s.vaultClaims, s.tax, "the tax booked is exactly the claims minted to the Tax Vault");
        // Nothing else is done with it in the swap: the vault holds no Quote Asset or coin of its own.
        assertEq(_quoteBalanceOf(key, address(taxVault)), 0, "nothing transferred to the vault");
        assertEq(_coinOfKey(key).balanceOf(address(taxVault)), 0, "no coin bought");
    }

    /// The fee and the tax a swap must take, from the Quote Asset side the trader saw.
    function _expected(Seen memory s, bool buy, bool exactIn, uint256 taxBps)
        internal
        pure
        returns (uint256 fee, uint256 tax)
    {
        uint256 total = PLATFORM_FEE_BPS + taxBps;
        if (buy && exactIn) {
            return (_rateOfGross(s.quoteIn, PLATFORM_FEE_BPS), _rateOfGross(s.quoteIn, taxBps));
        }
        if (buy) {
            uint256 net = s.quoteIn - s.fee - s.tax;
            return (_rateOfNet(net, PLATFORM_FEE_BPS, total), _rateOfNet(net, taxBps, total));
        }
        if (exactIn) {
            uint256 gross = s.quoteOut + s.fee + s.tax;
            return (_rateOfGross(gross, PLATFORM_FEE_BPS), _rateOfGross(gross, taxBps));
        }
        return (_rateOfNet(s.quoteOut, PLATFORM_FEE_BPS, total), _rateOfNet(s.quoteOut, taxBps, total));
    }

    function _assertFourSwaps(PoolKey memory key, uint256 taxBps) internal {
        uint256 u = _unit(key);
        _trade(key, trader, true, true, 40 * u);
        bool[2][4] memory types = [[true, true], [true, false], [false, true], [false, false]];
        for (uint256 i; i < 4; i++) {
            (bool buy, bool exactIn) = (types[i][0], types[i][1]);
            uint256 amount;
            if (buy) amount = exactIn ? 5 * u : 1e9 ether;
            else amount = exactIn ? _coinOfKey(key).balanceOf(trader) / 4 : 2 * u;
            uint256 coins0 = _coinOfKey(key).balanceOf(trader);
            Seen memory s = _swapAndSee(key, buy, exactIn, amount);
            (uint256 fee, uint256 tax) = _expected(s, buy, exactIn, taxBps);
            assertEq(s.tax, tax, "the tax is its rate of the Quote Asset's side");
            assertEq(s.fee, fee, "the Platform Fee is unchanged beside it");
            assertGt(s.tax, 0);
            if (buy && exactIn) assertEq(s.quoteIn, amount, "paid the specified amount, both included");
            if (buy && !exactIn) assertEq(_coinOfKey(key).balanceOf(trader) - coins0, amount, "got the coins");
            if (!buy && exactIn) assertEq(coins0 - _coinOfKey(key).balanceOf(trader), amount, "sold the coins");
            if (!buy && !exactIn) assertEq(s.quoteOut, amount, "received the specified amount");
        }
    }

    function test_tax_fourSwapTypes_rewardLaunch_coinIsCurrency0() public {
        _assertFourSwaps(_launchKind(0, StokerHook.LaunchType.Reward, TAX_BPS), TAX_BPS);
    }

    function test_tax_fourSwapTypes_rewardLaunch_coinIsCurrency1() public {
        _assertFourSwaps(_launchKind(1, StokerHook.LaunchType.Reward, TAX_BPS), TAX_BPS);
    }

    function test_tax_fourSwapTypes_rewardLaunch_native() public {
        _assertFourSwaps(_launchKind(2, StokerHook.LaunchType.Reward, TAX_BPS), TAX_BPS);
    }

    function test_tax_fourSwapTypes_stokeLaunch_everyOrder() public {
        for (uint256 kind; kind < 3; kind++) {
            _assertFourSwaps(_launchKind(kind, StokerHook.LaunchType.Liquidity, 500), 500);
        }
    }

    function testFuzz_tax_alwaysItsRateOfTheQuoteSide(
        uint256 kind,
        uint256 rate,
        bool buy,
        bool exactIn,
        uint256 amount
    ) public {
        kind = bound(kind, 0, 2);
        uint16 taxBps = uint16(bound(rate, 1, 5) * 100);
        PoolKey memory key = _launchKind(kind, StokerHook.LaunchType.Reward, taxBps);
        uint256 u = _unit(key);
        _trade(key, trader, true, true, 100 * u);
        if (buy) amount = bound(amount, 1e6, exactIn ? 500 * u : 1e10 ether);
        else amount = bound(amount, exactIn ? 1e12 : 1e6, exactIn ? _coinOfKey(key).balanceOf(trader) : 50 * u);
        Seen memory s = _swapAndSee(key, buy, exactIn, amount);
        (uint256 fee, uint256 tax) = _expected(s, buy, exactIn, taxBps);
        assertEq(s.tax, tax, "the tax");
        assertEq(s.fee, fee, "the fee");
    }

    function test_tax_standardLaunchBooksNone() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchKind(kind, StokerHook.LaunchType.Standard, 0);
            uint256 u = _unit(key);
            _trade(key, trader, true, true, 10 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
            assertEq(_taxBooked(key), 0, "no tax");
            assertEq(_vaultClaims(key), 0, "nothing minted to the vault");
        }
    }

    function test_tax_theFirstBuyPaysIt() public {
        (, PoolKey memory key) = _launchWith(
            _typedParams(
                address(quote),
                true,
                1 ether,
                StokerHook.LaunchType.Reward,
                TAX_BPS,
                0,
                0,
                StokerHook.PayoutAsset.QuoteAsset
            )
        );
        assertEq(_taxBooked(key), 0.03 ether, "3% of the First Buy");
        assertEq(_vaultClaims(key), 0.03 ether);
    }

    function test_tax_eventSaysTheSame() public {
        PoolKey memory key = _launchKind(0, StokerHook.LaunchType.Reward, TAX_BPS);
        _approveRouter(key, trader);
        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.TaxBooked(key.toId(), _quoteOfKey(key), 0.3 ether);
        _swapApproved(key, trader, true, true, 10 ether);
    }

    // ------------------------------------------------ the Tax Vault's own buy

    /// The vault's buy pays the Platform Fee like any buy, and no tax: taxing the tax would send part of
    /// the burn's share back to the holders and the liquidity.
    function test_tax_theVaultsOwnBuyPaysTheFeeButNoTax() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchKind(kind, StokerHook.LaunchType.Reward, TAX_BPS);
            _trade(key, trader, true, true, 40 * _unit(key));
            _letThePriceStand();
            uint256 booked = _taxBooked(key);
            uint256 fee0 = _hookClaimsOf(key);
            vm.prank(stranger);
            (uint256 spent,) = taxVault.burn(key);
            assertGt(spent, 0);
            assertEq(_taxBooked(key), booked, "the vault's buy booked no tax");
            assertEq(_hookClaimsOf(key) - fee0, _rateOfGross(spent, PLATFORM_FEE_BPS), "it paid the Platform Fee");
        }
    }

    // ------------------------------------------------ the fee and the tax together, at the edges

    function _limit(PoolKey memory key, bool buy, int24 ticks) internal view returns (uint160) {
        bool zeroForOne = buy == _quoteIsCurrency0(key);
        int24 tick = _tickOf(key);
        return TickMath.getSqrtPriceAtTick(zeroForOne ? tick - ticks : tick + ticks);
    }

    function _swapWithLimit(PoolKey memory key, bool buy, bool exactIn, uint256 amount, uint160 limit) internal {
        bool zeroForOne = buy == _quoteIsCurrency0(key);
        uint256 value = _native(key) && buy ? trader.balance : 0;
        vm.prank(trader);
        swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The `SwapStoppedEarly` comparison counts the fee and the tax together: a swap with the Quote Asset
    /// specified that its limit does not stop goes through (it would be refused if the tax were left out),
    /// and one its limit stops is refused.
    function test_tax_quoteSpecifiedStoppedEarly_comparesFeeAndTaxTogether() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchKind(kind, StokerHook.LaunchType.Reward, TAX_BPS);
            uint256 u = _unit(key);
            _trade(key, trader, true, true, 50 * u);
            vm.startPrank(trader);
            _coinOfKey(key).approve(address(swapRouter), type(uint256).max);
            if (!_native(key)) quote.approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();

            uint256 tax0 = _taxBooked(key);
            _swapWithLimit(key, true, true, u / 100, _limit(key, true, 400));
            assertEq(_taxBooked(key) - tax0, _rateOfGross(u / 100, TAX_BPS), "a limit that does not bind");
            tax0 = _taxBooked(key);
            _swapWithLimit(key, false, false, u / 100, _limit(key, false, 400));
            uint256 total = PLATFORM_FEE_BPS + TAX_BPS;
            assertEq(_taxBooked(key) - tax0, _rateOfNet(u / 100, TAX_BPS, total));

            bytes memory stopped =
                _hookError(IHooks.afterSwap.selector, abi.encodeWithSelector(StokerHook.SwapStoppedEarly.selector));
            uint160 buyLimit = _limit(key, true, 400);
            vm.expectRevert(stopped);
            _swapWithLimit(key, true, true, 100 * u, buyLimit);
            uint160 sellLimit = _limit(key, false, 400);
            vm.expectRevert(stopped);
            _swapWithLimit(key, false, false, 40 * u, sellLimit);
        }
    }

    /// An exact-in sell whose fee and tax, each rounded up, would come to more than the pool pays out is
    /// refused: the trader would pay to sell.
    function test_tax_sellTheFeeAndTaxWouldOutweigh_reverts() public {
        PoolKey memory key = _launchKind(0, StokerHook.LaunchType.Reward, TAX_BPS);
        _trade(key, trader, true, true, 10 ether);
        // Coins worth about 1.5 raw units of the Quote Asset: the pool pays 1, the fee and the tax take 1 each.
        uint256 sqrtP = _sqrtPrice(key);
        uint256 coins = FullMath.mulDiv(3 << 191, 1, sqrtP * sqrtP);
        _approveRouter(key, trader);
        vm.expectRevert(_hookError(IHooks.afterSwap.selector, abi.encodeWithSelector(StokerHook.SwapTooSmall.selector)));
        _swapApproved(key, trader, false, true, coins);
    }

    /// An exact-in buy that the fee and the tax together would swallow is refused before the pool runs.
    function test_tax_buyTheFeeAndTaxWouldSwallow_reverts() public {
        PoolKey memory key = _launchKind(0, StokerHook.LaunchType.Reward, TAX_BPS);
        _approveRouter(key, trader);
        vm.expectRevert(
            _hookError(IHooks.beforeSwap.selector, abi.encodeWithSelector(StokerHook.SwapTooSmall.selector))
        );
        _swapApproved(key, trader, true, true, 2);
    }
}
