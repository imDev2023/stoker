// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// The Opening Fee in the Tax Vault (#246, ADR 0025, ADR 0026): every wei of it reaches the vault's books for
/// its own coin and becomes that coin's Support Liquidity, whatever the Launch's type, a standard coin
/// included; it never feeds the burn or the holders; and the vault makes no buy of its own while it runs.
contract OpeningFeeVaultTest is TaxLocalBase, OpeningFeeHelpers {
    /// Buys inside the window at three seconds, and returns what they booked as Opening Fees.
    function _openingBuys(PoolKey memory key) internal returns (uint256 opening) {
        for (uint256 at; at < 15; at += 5) {
            vm.warp(_launchedAt(key) + at);
            opening += _tradeAndSee(key, true, at % 2 == 0, _buyAmount(key, at % 2 == 0), 0).opening;
        }
        assertGt(opening, 0, "the buys paid an Opening Fee");
        assertEq(hook.openingFeeBooked(key.toId()), opening, "the running total is every buy's Opening Fee");
    }

    /// A standard coin's only income is its Opening Fee: all of it waits as Support Liquidity, none for the
    /// burn or the holders, and `addSupport` spends it piece by piece, never more than it, in every kind of
    /// pool; the vault's claims are always what waits.
    function test_opening_aStandardCoinsOnlyIncomeBecomesSupportLiquidity() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, 0);
            uint256 opening = _openingBuys(key);
            assertEq(hook.taxBooked(key.toId()), 0, "a standard coin books no tax");
            (uint256 burnPart, uint256 supportPart, uint256 holdersPart, uint256 holdersCoins) = taxVault.waiting(key);
            assertEq(supportPart, opening, "all of it waits as Support Liquidity");
            assertEq(burnPart + holdersPart + holdersCoins, 0, "none for the burn or the holders");
            assertEq(_vaultClaims(key), opening, "the vault's claims are the Opening Fee");

            // Support Liquidity may be placed while the Opening Fee runs; pieces drain it, never past it.
            uint256 spent;
            for (uint256 i; i < 6; i++) {
                (, uint256 added) = _addSupport(key);
                spent += added;
                assertLe(spent, opening, "never more than the Opening Fee");
                (, supportPart,,) = taxVault.waiting(key);
                assertEq(supportPart, opening - spent, "what waits falls by each piece");
                assertEq(_vaultClaims(key), opening - spent, "the claims are what waits");
                if (supportPart == 0) break;
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            }
            assertGt(spent, 0, "pieces were placed");
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.burn(key);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.passHoldersPart(key);
            vm.revertToState(snap);
        }
    }

    /// On a Reward Launch and a Stoke Launch the Opening Fee is added to the Support Liquidity part alone:
    /// the burn's part and the holders' part are their shares of the tax and nothing more.
    function test_opening_isAddedToTheSupportPartAloneOnEveryType() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 lt = 1; lt < 3; lt++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(kind, lt, 0);
                uint256 opening = _openingBuys(key);
                uint256 tax = hook.taxBooked(key.toId());
                StokerHook.Terms memory t = hook.termsOf(key.toId());
                (uint256 burnPart, uint256 supportPart, uint256 holdersPart,) = taxVault.waiting(key);
                assertEq(burnPart, tax * t.burnShareBps / B, "the burn's part: its share of the tax");
                assertEq(supportPart, tax * t.liquidityShareBps / B + opening, "Support Liquidity: its share and all");
                uint256 holdersShare =
                    lt == uint256(StokerHook.LaunchType.Reward) ? B - t.burnShareBps - t.liquidityShareBps : 0;
                assertEq(holdersPart, tax * holdersShare / B, "the holders' part: its share of the tax");
                assertEq(_vaultClaims(key), tax + opening, "the vault's claims: the tax and the Opening Fee");
                vm.revertToState(snap);
            }
        }
    }

    /// One coin's Opening Fee never pays for another's Support Liquidity.
    function test_opening_oneCoinsOpeningFeeNeverPaysForAnother() public {
        PoolKey memory paid = _launchOpen(0, 0, 0);
        _openingBuys(paid);
        PoolKey memory other = _launchOpen(1, 0, 0);
        vm.warp(_launchedAt(other) + OPENING_FEE_DURATION);
        (, uint256 supportPart,,) = taxVault.waiting(other);
        assertEq(supportPart, 0, "nothing waits for the other coin");
        vm.expectRevert(TaxVault.NothingToSpend.selector);
        taxVault.addSupport(other);
    }

    /// While a Launch's Opening Fee runs, the vault makes no buy in its pool: neither the burn nor a Payout
    /// Asset of the coin, at every second of it, so neither pays it; the first may come at its end.
    function test_opening_theVaultMakesNoBuyWhileItRuns() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _tradeInOpening = true;
            (, PoolKey memory key) = _launchWith(
                _typedParams(
                    kind == 2 ? address(0) : address(quote),
                    kind == 1,
                    kind == 2 ? 0.1 ether : 1 ether,
                    StokerHook.LaunchType.Reward,
                    TAX_BPS,
                    2_500,
                    2_500,
                    StokerHook.PayoutAsset.Coin
                )
            );
            uint256 openAt = _launchedAt(key) + OPENING_FEE_DURATION;
            // The First Buy booked tax, so both parts have something to spend from the launch's second.
            for (uint256 at; at < OPENING_FEE_DURATION; at++) {
                vm.warp(_launchedAt(key) + at);
                vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, openAt));
                taxVault.burn(key);
                vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, openAt));
                taxVault.buyForHolders(key);
            }
            vm.warp(openAt);
            uint256 openingBefore = hook.openingFeeBooked(key.toId());
            (uint256 spent, uint256 burned) = taxVault.burn(key);
            assertGt(spent, 0, "the burn spends at the window's end");
            assertGt(burned, 0, "and burns");
            assertEq(hook.openingFeeBooked(key.toId()), openingBefore, "its buy paid no Opening Fee");
            vm.warp(openAt + PIECE_INTERVAL);
            (spent,) = taxVault.buyForHolders(key);
            assertGt(spent, 0, "the holders' buy too");
            assertEq(hook.openingFeeBooked(key.toId()), openingBefore, "its buy paid no Opening Fee");
            vm.revertToState(snap);
        }
    }
}
