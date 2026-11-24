// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkTaxBase} from "./ForkTaxBase.sol";
import {SeedRemover} from "../utils/SeedRemover.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// Support Liquidity on the real PoolManager (#245's first criterion, which the grilling chose without a
/// test): the Tax Vault adds Quote Asset alone as a position below the current price in a coin's pool, the
/// position buys coins as the price falls through it, and no call removes it. With the coin as currency0,
/// as currency1, and paired with native ETH.
contract ForkSupportTest is ForkTaxBase {
    function test_fork_support_quoteAloneBelowThePrice_buysAsItFalls_coinIsCurrency0() public {
        _supportBuysAsThePriceFalls(_launchStoke(false, 500), 50 ether);
    }

    function test_fork_support_quoteAloneBelowThePrice_buysAsItFalls_coinIsCurrency1() public {
        _supportBuysAsThePriceFalls(_launchStoke(true, 500), 50 ether);
    }

    function test_fork_support_quoteAloneBelowThePrice_buysAsItFalls_native() public {
        PoolKey memory key =
            _launchNativeTyped(StokerHook.LaunchType.Liquidity, 0, 0, StokerHook.PayoutAsset.QuoteAsset);
        _supportBuysAsThePriceFalls(key, 2 ether);
    }

    function _supportBuysAsThePriceFalls(PoolKey memory key, uint256 buy) internal {
        IERC20 coin = _coinOfKey(key);
        // A trade books the Stoke Tax into the Tax Vault and lifts the price.
        _trade(key, trader, true, true, buy);
        assertGt(_taxBooked(key), 0, "the buy booked its tax");
        uint256 coins = coin.balanceOf(trader);

        // Without Support Liquidity, what selling every coin back would pay.
        uint256 snap = vm.snapshotState();
        uint256 q = _quoteBalanceOf(key, trader);
        _trade(key, trader, false, true, coins);
        uint256 proceedsWithout = _quoteBalanceOf(key, trader) - q;
        vm.revertToState(snap);

        // A stranger adds a piece: Quote Asset alone, below the price, no coin bought, the price unmoved.
        uint160 priceBefore = _sqrtPrice(key);
        uint256 supply = coin.totalSupply();
        uint256 claims = _vaultClaims(key);
        (Support memory s, uint256 added) = _addSupport(key);
        assertGt(added, 0, "a piece was added");
        assertEq(_sqrtPrice(key), priceBefore, "the price did not move");
        assertEq(coin.totalSupply(), supply, "no coin burned");
        assertEq(coin.balanceOf(address(taxVault)), 0, "no coin bought");
        assertEq(claims - _vaultClaims(key), added, "paid by burning exactly that many of the vault's claims");
        int24 tick = _tickOf(key);
        if (_quoteIsCurrency0(key)) {
            assertGt(s.lower, tick, "wholly above the pool's tick: below the coin's price");
        } else {
            assertLe(s.upper, tick, "wholly below the pool's tick: below the coin's price");
        }
        (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, s);
        assertEq(coinsHeld, 0, "it holds no coin");
        assertApproxEqAbs(quoteHeld, added, 1, "it holds the Quote Asset added");
        emit log_named_decimal_uint("Support Liquidity added", added, 18);

        // The price falls through it: every coin sold back. The position bought coins on the way down, so
        // the seller was paid more than without it.
        q = _quoteBalanceOf(key, trader);
        _trade(key, trader, false, true, coins);
        uint256 proceedsWith = _quoteBalanceOf(key, trader) - q;
        if (_quoteIsCurrency0(key)) {
            assertGe(_tickOf(key), s.upper, "the price fell through the whole range");
        } else {
            assertLt(_tickOf(key), s.lower, "the price fell through the whole range");
        }
        (quoteHeld, coinsHeld) = _supportHoldings(key, s);
        assertLe(quoteHeld, 1, "its Quote Asset is spent");
        assertGt(coinsHeld, 0, "it bought coins");
        assertGt(proceedsWith, proceedsWithout, "the seller was paid more with it");
        emit log_named_decimal_uint("coins it bought", coinsHeld, 18);
        emit log_named_decimal_uint("paid to the seller beyond the seed alone", proceedsWith - proceedsWithout, 18);

        _noCallRemoves(key, s);
    }

    /// No call removes it: not through a router by anyone, not even from the vault's own address given
    /// code that tries (a zero-liquidity poke included).
    function _noCallRemoves(PoolKey memory key, Support memory s) internal {
        uint128 liquidity = _supportLiquidity(key, s);
        assertGt(liquidity, 0);
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
        address[3] memory who = [creator, stranger, platform];
        for (uint256 i; i < who.length; i++) {
            vm.prank(who[i]);
            vm.expectRevert(_removalRefused());
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(s.lower, s.upper, -int256(uint256(liquidity)), 0), "");
        }

        uint256 snap = vm.snapshotState();
        vm.etch(address(taxVault), address(new SeedRemover(pm)).code);
        vm.expectRevert(_removalRefused());
        SeedRemover(address(taxVault)).remove(key, s.lower, s.upper, int256(uint256(liquidity)));
        vm.expectRevert(_removalRefused());
        SeedRemover(address(taxVault)).remove(key, s.lower, s.upper, 0);
        vm.revertToState(snap);

        assertEq(_supportLiquidity(key, s), liquidity, "the position is untouched");
    }
}
