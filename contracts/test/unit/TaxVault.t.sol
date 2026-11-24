// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {MockQuote} from "../utils/MockQuote.sol";

/// The Tax Vault's public calls (#245, ADR 0025, ADR 0029), each in capped pieces, with the coin as
/// currency0, as currency1 and paired with the native asset: Support Liquidity with no coin bought and the
/// price unmoved, the Reward Burn burning exactly what it bought, the holders' part kept apart and handed to
/// the Distributor, a Payout Asset of the coin bought in the same capped pieces.
contract TaxVaultTest is TaxLocalBase {
    StokerHook.PayoutAsset internal constant IN_QUOTE = StokerHook.PayoutAsset.QuoteAsset;
    StokerHook.PayoutAsset internal constant IN_COIN = StokerHook.PayoutAsset.Coin;

    /// 0: the coin is currency0; 1: the coin is currency1; 2: paired with the native asset.
    function _reward(uint256 kind, uint16 burnShare, uint16 liqShare, StokerHook.PayoutAsset pa)
        internal
        returns (PoolKey memory key)
    {
        if (kind == 2) return _launchNativeTyped(StokerHook.LaunchType.Reward, burnShare, liqShare, pa);
        return _launchReward(kind == 1, burnShare, liqShare, pa);
    }

    function _stoke(uint256 kind) internal returns (PoolKey memory key) {
        if (kind == 2) return _launchNativeTyped(StokerHook.LaunchType.Liquidity, 0, 0, IN_QUOTE);
        return _launchStoke(kind == 1, TAX_BPS);
    }

    function _unit(PoolKey memory key) internal pure returns (uint256) {
        return _native(key) ? 0.05 ether : 1 ether;
    }

    /// Trades that book tax: buys and sells in turn, ending with the trader holding a few coins.
    function _churn(PoolKey memory key, uint256 rounds) internal {
        uint256 u = _unit(key);
        for (uint256 i; i < rounds; i++) {
            _trade(key, trader, true, true, 40 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
        }
    }

    function _waiting(PoolKey memory key)
        internal
        view
        returns (uint256 burnPart, uint256 supportPart, uint256 holdersPart_, uint256 holdersCoins)
    {
        return taxVault.waiting(key);
    }

    // ------------------------------------------------ Support Liquidity

    function test_support_aPiece_capped_quoteAlone_priceUnmoved_noCoinBought() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _stoke(kind);
            _churn(key, 3);
            uint256 cap = taxVault.pieceCap(key);
            (, uint256 supportPart,,) = _waiting(key);
            assertGt(supportPart, cap, "more waiting than one piece");
            uint160 price = _sqrtPrice(key);
            uint256 supply = _coinOfKey(key).totalSupply();
            uint256 claims = _vaultClaims(key);

            (Support memory s, uint256 added) = _addSupport(key);
            assertLe(added, cap, "never more than the cap");
            assertApproxEqRel(added, cap, 1e12, "a whole piece when enough waits");
            assertEq(claims - _vaultClaims(key), added, "paid by burning exactly that many claims");
            assertEq(_sqrtPrice(key), price, "the price did not move");
            assertEq(_coinOfKey(key).totalSupply(), supply, "no coin burned");
            assertEq(_coinOfKey(key).balanceOf(address(taxVault)), 0, "no coin bought");
            (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, s);
            assertEq(coinsHeld, 0, "Quote Asset alone");
            assertApproxEqAbs(quoteHeld, added, 1);
            assertEq(taxVault.booksOf(key.toId()).supportSpent, added);
            // Just below the price: within one tick spacing of it, ten spacings deep.
            int24 tick = _tickOf(key);
            if (_quoteIsCurrency0(key)) {
                assertGt(s.lower, tick);
                assertLe(s.lower - tick, TICK_SPACING);
                assertEq(s.upper - s.lower, SUPPORT_WIDTH_SPACINGS * TICK_SPACING);
            } else {
                assertLe(s.upper, tick);
                assertLt(tick - s.upper, TICK_SPACING);
                assertEq(s.upper - s.lower, SUPPORT_WIDTH_SPACINGS * TICK_SPACING);
            }
        }
    }

    function test_support_onePiecePerInterval() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _stoke(kind);
            _churn(key, 3);
            _addSupport(key);
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + PIECE_INTERVAL));
            taxVault.addSupport(key);
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL - 1);
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + 1));
            taxVault.addSupport(key);
            vm.warp(vm.getBlockTimestamp() + 1);
            _addSupport(key);
        }
    }

    /// A Stoke Launch's whole tax becomes Support Liquidity, piece by piece; it has no holders' part and
    /// no burn share.
    function test_support_stokeLaunch_wholeTaxBecomesSupport_noHoldersPart() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _stoke(kind);
            _churn(key, 2);
            uint256 booked = _taxBooked(key);
            (uint256 burnPart, uint256 supportPart, uint256 holdersPart_,) = _waiting(key);
            assertEq(supportPart, booked, "all of it waits for liquidity");
            assertEq(burnPart + holdersPart_, 0);
            uint256 total;
            for (uint256 i; i < 400; i++) {
                (, supportPart,,) = _waiting(key);
                if (supportPart < 1e9) break;
                (, uint256 added) = _addSupport(key);
                total += added;
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            }
            (, supportPart,,) = _waiting(key);
            assertLt(supportPart, 1e9, "drained to dust");
            assertEq(total + supportPart, booked, "every unit of the tax became Support Liquidity");
            assertEq(_vaultClaims(key), supportPart, "the vault keeps nothing else of it");
            vm.startPrank(stranger);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.burn(key);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.passHoldersPart(key);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.buyForHolders(key);
            vm.stopPrank();
        }
    }

    // ------------------------------------------------ the Reward Burn

    function test_burn_aPiece_capped_supplyFallsByWhatItBought() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _reward(kind, 5_000, 0, IN_QUOTE);
            _churn(key, 3);
            uint256 cap = taxVault.pieceCap(key);
            (uint256 burnPart,,,) = _waiting(key);
            assertGt(burnPart, cap, "more waiting than one piece");
            IERC20 coin = _coinOfKey(key);
            uint256 supply = coin.totalSupply();
            uint256 claims = _vaultClaims(key);

            vm.prank(stranger);
            (uint256 spent, uint256 burned) = taxVault.burn(key);
            assertEq(spent, cap, "a whole piece, no more");
            assertGt(burned, 0);
            assertEq(supply - coin.totalSupply(), burned, "the supply fell by exactly what it bought");
            assertEq(coin.balanceOf(address(taxVault)), 0, "it kept none");
            assertEq(claims - _vaultClaims(key), spent, "paid by burning exactly that many claims");
            assertEq(taxVault.booksOf(key.toId()).burnSpent, spent);

            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + PIECE_INTERVAL));
            taxVault.burn(key);
        }
    }

    /// The burn spends its own share and nothing else: drained to the end, the holders' part and the
    /// liquidity share wait untouched.
    function test_burn_drained_neverTouchesTheOtherParts() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _reward(kind, 2_500, 2_500, IN_QUOTE);
            _churn(key, 2);
            (, uint256 supportBefore, uint256 holdersBefore,) = _waiting(key);
            uint256 booked = _taxBooked(key);
            uint256 spentTotal;
            for (uint256 i; i < 400; i++) {
                (uint256 burnPart,,,) = _waiting(key);
                if (burnPart < 1e9) break;
                vm.prank(stranger);
                (uint256 spent,) = taxVault.burn(key);
                spentTotal += spent;
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            }
            (uint256 burnLeft, uint256 supportAfter, uint256 holdersAfter,) = _waiting(key);
            assertEq(spentTotal + burnLeft, booked * 2_500 / 10_000, "the burn spent its quarter, no more");
            assertEq(supportAfter, supportBefore, "the liquidity share untouched");
            assertEq(holdersAfter, holdersBefore, "the holders' part untouched");
        }
    }

    /// The cap is measured against the Seed Position's Quote Asset depth, not what the pool holds: a coin
    /// bought and sold back to its start price holds almost no Quote Asset, yet its burn is not starved.
    function test_burn_capIsNeverStarvedByAnEmptyPool_coinIsCurrency0() public {
        _capNotStarved(0);
    }

    function test_burn_capIsNeverStarvedByAnEmptyPool_coinIsCurrency1() public {
        _capNotStarved(1);
    }

    function test_burn_capIsNeverStarvedByAnEmptyPool_native() public {
        _capNotStarved(2);
    }

    function _capNotStarved(uint256 kind) internal {
        PoolKey memory key = _reward(kind, 5_000, 0, IN_QUOTE);
        // 0.5% of the Opening Value, the whole supply at the start price (the First Buy lifted it a little).
        uint256 openingCap = (_native(key) ? 1.66 ether : 24.8 ether) * PIECE_BPS / 10_000;
        assertApproxEqRel(taxVault.pieceCap(key), openingCap, 0.1e18, "0.5% of the Opening Value");
        // Bought up and sold all the way back, the Creator's First Buy too.
        uint256 u = _unit(key);
        for (uint256 i; i < 5; i++) {
            _trade(key, trader, true, true, 40 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        _trade(key, creator, false, true, _coinOfKey(key).balanceOf(creator));
        // What the pool itself holds now: the PoolManager's Quote Asset less every claim on it.
        uint256 poolQuote = _quoteBalanceOf(key, address(pm)) - _hookClaimsOf(key) - _vaultClaims(key);
        (uint256 burnPart,,,) = _waiting(key);
        assertLt(poolQuote * PIECE_BPS / 10_000, burnPart / 1_000, "a cap on what the pool holds would starve it");
        uint256 cap = taxVault.pieceCap(key);
        assertGe(cap, openingCap * 9 / 10, "the cap stays near 0.5% of the Opening Value");
        vm.prank(stranger);
        (uint256 spent, uint256 burned) = taxVault.burn(key);
        assertEq(spent, cap, "the burn spends a whole piece");
        assertGt(burned, 0);
        emit log_named_decimal_uint("Quote Asset the pool holds", poolQuote, 18);
        emit log_named_decimal_uint("the burn's piece", spent, 18);
    }

    // ------------------------------------------------ the holders' part

    function test_holders_quoteAsset_passedWholeToTheDistributor() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _reward(kind, 1_000, 2_500, IN_QUOTE);
            _churn(key, 2);
            uint256 booked = _taxBooked(key);
            (,, uint256 holdersPart_,) = _waiting(key);
            assertEq(holdersPart_, booked * 6_500 / 10_000, "the rest of the tax after the two shares");
            Currency q = _quoteOfKey(key);
            address coin = address(_coinOfKey(key));
            uint256 claims = _vaultClaims(key);
            uint256 standIn = _quoteBalanceOf(key, address(holdersPart));

            vm.prank(stranger);
            (Currency asset, uint256 amount) = taxVault.passHoldersPart(key);
            assertEq(Currency.unwrap(asset), Currency.unwrap(q), "in the Quote Asset");
            assertEq(amount, holdersPart_);
            assertEq(holdersPart.deposited(coin, q), amount, "deposited for this coin");
            assertEq(_quoteBalanceOf(key, address(holdersPart)) - standIn, amount, "and really received");
            assertEq(claims - _vaultClaims(key), amount);
            assertEq(_quoteBalanceOf(key, address(taxVault)), 0, "the vault kept none");
            if (!_native(key)) {
                assertEq(quote.allowance(address(taxVault), address(holdersPart)), 0, "no allowance left");
            }
            (,, holdersPart_,) = _waiting(key);
            assertEq(holdersPart_, 0);
            vm.prank(stranger);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.passHoldersPart(key);
        }
    }

    function test_holders_aDistributorThatPullsShort_isRefused() public {
        PoolKey memory key = _reward(0, 0, 0, IN_QUOTE);
        _churn(key, 1);
        holdersPart.setShortBy(1);
        vm.prank(stranger);
        vm.expectRevert(TaxVault.DepositShort.selector);
        taxVault.passHoldersPart(key);
    }

    /// A Stock Token that refuses the Distributor stops the hand-off, and the holders' part stays waiting.
    function test_holders_aRefusingQuoteAsset_leavesThePartWaiting() public {
        PoolKey memory key = _reward(0, 0, 0, IN_QUOTE);
        _churn(key, 1);
        (,, uint256 before,) = _waiting(key);
        MockQuote(address(quote)).setBlocked(address(holdersPart), true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockQuote.Blocked.selector, address(holdersPart)));
        taxVault.passHoldersPart(key);
        (,, uint256 afterRefusal,) = _waiting(key);
        assertEq(afterRefusal, before);
        MockQuote(address(quote)).setBlocked(address(holdersPart), false);
        vm.prank(stranger);
        taxVault.passHoldersPart(key);
    }

    /// A Payout Asset of the coin: the holders' part buys the coin in capped pieces, under the burn's
    /// interval, and the coins bought are handed to the Distributor.
    function test_holders_coin_boughtInCappedPieces_thenPassed() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _reward(kind, 1_000, 0, IN_COIN);
            _churn(key, 2);
            IERC20 coin = _coinOfKey(key);
            uint256 cap = taxVault.pieceCap(key);
            uint256 supply = coin.totalSupply();

            vm.prank(stranger);
            (uint256 spent, uint256 bought) = taxVault.buyForHolders(key);
            assertEq(spent, cap, "a whole piece");
            assertEq(coin.balanceOf(address(taxVault)), bought, "kept for the holders");
            assertEq(coin.totalSupply(), supply, "nothing burned");
            (,,, uint256 holdersCoins) = _waiting(key);
            assertEq(holdersCoins, bought);

            // The burn and the holders' buy share one interval: one vault buy per pool per minute.
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, vm.getBlockTimestamp() + PIECE_INTERVAL));
            taxVault.burn(key);

            vm.prank(stranger);
            (Currency asset, uint256 amount) = taxVault.passHoldersPart(key);
            assertEq(Currency.unwrap(asset), address(coin), "in the coin");
            assertEq(amount, bought);
            assertEq(coin.balanceOf(address(holdersPart)), bought);
            assertEq(holdersPart.deposited(address(coin), asset), bought);
            assertEq(coin.balanceOf(address(taxVault)), 0);
        }
    }

    function test_holders_quotePayout_hasNoBuy() public {
        PoolKey memory key = _reward(0, 0, 0, IN_QUOTE);
        _churn(key, 1);
        vm.prank(stranger);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.buyForHolders(key);
    }

    function test_vault_standardLaunchHasNothing() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _trade(key, trader, true, true, 10 ether);
        vm.startPrank(stranger);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.addSupport(key);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.burn(key);
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.passHoldersPart(key);
        vm.stopPrank();
    }

    /// Each coin's tax pays for that coin alone: draining one Launch's parts leaves another's untouched.
    function test_vault_oneCoinsTaxNeverPaysForAnother() public {
        PoolKey memory a = _reward(0, 2_500, 2_500, IN_QUOTE);
        PoolKey memory b = _reward(1, 2_500, 2_500, IN_QUOTE);
        _churn(a, 1);
        _churn(b, 1);
        (uint256 bBurn, uint256 bSupport, uint256 bHolders,) = _waiting(b);
        for (uint256 i; i < 200; i++) {
            (uint256 burnPart, uint256 supportPart,,) = _waiting(a);
            if (burnPart < 1e9 && supportPart < 1e9) break;
            vm.startPrank(stranger);
            if (burnPart >= 1e9) taxVault.burn(a);
            if (supportPart >= 1e9) taxVault.addSupport(a);
            vm.stopPrank();
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
        }
        vm.prank(stranger);
        taxVault.passHoldersPart(a);
        (uint256 burnB, uint256 supportB, uint256 holdersB,) = _waiting(b);
        assertEq(burnB, bBurn);
        assertEq(supportB, bSupport);
        assertEq(holdersB, bHolders);
        assertEq(_vaultClaims(b), _taxBooked(a) + _taxBooked(b) - _spentOf(a), "the claims back every unspent part");
    }

    function _spentOf(PoolKey memory key) internal view returns (uint256) {
        TaxVault.Books memory bk = taxVault.booksOf(key.toId());
        return bk.burnSpent + bk.supportSpent + bk.holdersSpent;
    }
}
