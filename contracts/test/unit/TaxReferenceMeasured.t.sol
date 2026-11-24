// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// What is left after the Reference Price (#271), measured for the README: what a wallet that holds a lifted
/// price for hours, with nobody selling into it, ends with, and what holding off the vault's buys by a spike
/// or a dip costs. Logged, with assertions only on the mechanism each figure stands on.
contract TaxReferenceMeasuredTest is TaxLocalBase {
    address internal attacker = makeAddr("attacker");
    address internal holder = makeAddr("holder");

    /// A coin of the issue's table, busy and then quiet a day, on the mock Stock Token with the coin as
    /// currency0.
    function _busy(StokerHook.LaunchType launchType, uint16 taxBps, uint16 burnShareBps)
        internal
        returns (PoolKey memory key)
    {
        (, key) = _launchWith(
            _typedParams(
                address(quote), false, 1 ether, launchType, taxBps, burnShareBps, 0, StokerHook.PayoutAsset.QuoteAsset
            )
        );
        uint256 tradeIn = _depth(key) * 60 / 25;
        for (uint256 i; i < 80; i++) {
            _trade(key, trader, true, true, tradeIn);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        _quiet(1 days);
    }

    function _depth(PoolKey memory key) internal view returns (uint256) {
        return taxVault.pieceCap(key) * 10_000 / PIECE_BPS;
    }

    function _quiet(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    function _ref(PoolKey memory key) internal view returns (int24) {
        return hook.referenceTick(key.toId());
    }

    /// The Quote Asset a buy needs to lift the coin's price by about `ticks`, on the Seed Position's depth.
    function _liftFor(PoolKey memory key, uint256 ticks) internal view returns (uint256) {
        // sqrt(1.0001^ticks) - 1, to first order ticks / 20,000, with the second order added.
        uint256 x = ticks * 1e18 / 20_000;
        return _depth(key) * (x + x * x / 2e18) / 1e18;
    }

    /// Holds a lift of about `ticks` for a day with `burn` or `addSupport` called every minute, and logs
    /// what selling everything would have brought at 1, 3, 6, 12 and 24 hours.
    function _holdADay(PoolKey memory key, uint256 ticks, bool burn) internal {
        uint256 snap = vm.snapshotState();
        mockQuote.mint(attacker, 1_000_000 ether);
        uint256 before = quote.balanceOf(attacker);
        _trade(key, attacker, true, true, _liftFor(key, ticks));
        emit log_named_uint("lift, ticks", ticks);
        uint256[5] memory marks = [uint256(60), 180, 360, 720, 1440];
        uint256 next;
        for (uint256 m = 1; m <= 1440; m++) {
            _quiet(60);
            vm.startPrank(attacker);
            if (burn) {
                try taxVault.burn(key) {} catch {}
            } else {
                try taxVault.addSupport(key) {} catch {}
            }
            vm.stopPrank();
            if (m == marks[next]) {
                uint256 at = vm.snapshotState();
                _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
                emit log_named_uint("  hours", m / 60);
                // forge-lint: disable-next-line(unsafe-typecast)
                emit log_named_decimal_int("  wallet's result", int256(quote.balanceOf(attacker)) - int256(before), 18);
                vm.revertToState(at);
                next++;
            }
        }
        vm.revertToState(snap);
    }

    /// Past the fuzz's two hours: Support Liquidity on a Stoke Launch at 1%, lifts from 2% to 65%, held for
    /// up to a day.
    function test_measured_longHolds_support() public {
        PoolKey memory stoke = _busy(StokerHook.LaunchType.Liquidity, 100, 0);
        (, uint256 supportWaiting,,) = taxVault.waiting(stoke);
        emit log_named_decimal_uint("depth", _depth(stoke), 18);
        emit log_named_decimal_uint("Support Liquidity waiting", supportWaiting, 18);
        uint256[4] memory lifts = [uint256(200), 600, 2_000, 5_000];
        for (uint256 i; i < lifts.length; i++) {
            _holdADay(stoke, lifts[i], false);
        }
    }

    /// The same for the Reward Burn, on a Reward Launch at 3% with half to the burn.
    function test_measured_longHolds_burn() public {
        PoolKey memory reward = _busy(StokerHook.LaunchType.Reward, 300, 5_000);
        (uint256 burnWaiting,,,) = taxVault.waiting(reward);
        emit log_named_decimal_uint("depth", _depth(reward), 18);
        emit log_named_decimal_uint("Reward Burn waiting", burnWaiting, 18);
        uint256[4] memory lifts = [uint256(200), 600, 2_000, 5_000];
        for (uint256 i; i < lifts.length; i++) {
            _holdADay(reward, lifts[i], true);
        }
    }

    /// What it costs to hold the vault's buys off for an hour and for a day, by a spike or by a dip.
    ///
    /// A spike must stand above the reference by more than the band, and the reference climbs toward it at
    /// the rise rate, so holding the buys off for `t` minutes takes a spike of the band plus `t` times the
    /// rise rate, held all that time and paid for by its round trip. A dip drags the reference down within
    /// seconds; once the price is restored the buys wait while the reference climbs back, so the same `t`
    /// takes a dip of that size standing a few seconds, and the holder who makes it pays the round trip.
    /// Neither stops Support Liquidity: a dip only places it deeper while the reference climbs back.
    function test_measured_stallCosts() public {
        PoolKey memory key = _busy(StokerHook.LaunchType.Reward, 300, 5_000);
        uint256[2] memory minutes_ = [uint256(60), 1_440];
        for (uint256 i; i < 2; i++) {
            uint256 ticks = BUY_BAND + minutes_[i] * REFERENCE_RISE + 20;

            // The spike.
            uint256 snap = vm.snapshotState();
            mockQuote.mint(attacker, 1_000_000 ether);
            uint256 before = quote.balanceOf(attacker);
            // The fee and the tax come off the buy first, so it is sized a tenth over.
            _trade(key, attacker, true, true, _liftFor(key, ticks * 11 / 10));
            assertGt(int256(_tickOf(key)) - _ref(key), int256(ticks), "the spike's height");
            _quiet(minutes_[i] * 60 - 60);
            vm.expectRevert();
            taxVault.burn(key);
            assertGt(int256(_tickOf(key)) - _ref(key), int256(uint256(BUY_BAND)), "held off to the end");
            _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
            emit log_named_uint("held off, minutes", minutes_[i]);
            emit log_named_decimal_uint("  a spike costs", before - quote.balanceOf(attacker), 18);
            vm.revertToState(snap);

            // The dip, by a holder whose coins have stood a day.
            snap = vm.snapshotState();
            mockQuote.mint(holder, 1_000_000 ether);
            _trade(key, holder, true, true, _liftFor(key, ticks * 12 / 10) * 2);
            _quiet(30 days);
            int24 level = _tickOf(key);
            uint256 coins = _coinOfKey(key).balanceOf(holder);
            before = quote.balanceOf(holder);
            _trade(key, holder, false, true, coins / 2);
            uint256 got = quote.balanceOf(holder) - before;
            assertGe(int256(level) - int256(_tickOf(key)), int256(ticks), "dipped");
            _quiet(ticks * 60 / REFERENCE_FALL + 1);
            // Buy back the coins sold.
            _trade(key, holder, true, false, coins - _coinOfKey(key).balanceOf(holder));
            uint256 spentBack = before + got - quote.balanceOf(holder);
            _quiet(minutes_[i] * 60 - 60);
            vm.expectRevert();
            taxVault.burn(key);
            emit log_named_decimal_uint("  a dip costs", spentBack - got, 18);
            vm.revertToState(snap);
        }
    }

    /// What one Support Liquidity piece and one buy cost the caller, for the Keeper's budget.
    function test_measured_callGas() public {
        PoolKey memory key = _busy(StokerHook.LaunchType.Reward, 300, 5_000);
        PoolKey memory stoke = _busy(StokerHook.LaunchType.Liquidity, 100, 0);
        uint256 g = gasleft();
        taxVault.addSupport(stoke);
        emit log_named_uint("addSupport gas", g - gasleft());
        g = gasleft();
        taxVault.burn(key);
        emit log_named_uint("burn gas", g - gasleft());
        assertTrue(TaxVault(taxVault).buyBandTicks() == BUY_BAND);
    }
}
