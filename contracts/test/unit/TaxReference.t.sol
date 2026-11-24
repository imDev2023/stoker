// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";

/// The Reference Price (#271), from outside: what the hook answers for a taxed pool's reference as the pool
/// trades and time passes, and what the Tax Vault does with it. In every pool kind: the coin as currency0,
/// as currency1, and paired with the native asset (always currency1, so a dearer coin is a lower tick).
contract TaxReferenceTest is TaxLocalBase {
    enum Pair {
        Coin0,
        Coin1,
        Native
    }

    address internal attacker = makeAddr("attacker");

    // ---------------------------------------------------------------- fixtures

    /// A Reward Launch at 3% with every path: a burn share, a liquidity share, and holders paid in the coin.
    function _rewardCoin(Pair pair, uint256 firstBuy) internal returns (PoolKey memory key) {
        (, key) = _launchWith(
            _typedParams(
                pair == Pair.Native ? address(0) : address(quote),
                pair != Pair.Coin0,
                firstBuy,
                StokerHook.LaunchType.Reward,
                TAX_BPS,
                2_500,
                2_500,
                StokerHook.PayoutAsset.Coin
            )
        );
    }

    /// The same coin after enough trading for tax to wait on every path, then a quiet day, so its
    /// Reference Price stands at its price.
    function _settled(Pair pair) internal returns (PoolKey memory key) {
        key = _rewardCoin(pair, pair == Pair.Native ? 0.1 ether : 1 ether);
        uint256 tradeIn = _depth(key) * 2;
        for (uint256 i; i < 10; i++) {
            _trade(key, trader, true, true, tradeIn);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        _quiet(1 days);
        assertEq(_ref(key), _tickOf(key), "a quiet day: the reference stands at the price");
    }

    function _depth(PoolKey memory key) internal view returns (uint256) {
        return taxVault.pieceCap(key) * 10_000 / PIECE_BPS;
    }

    function _ref(PoolKey memory key) internal view returns (int24) {
        return hook.referenceTick(key.toId());
    }

    function _quiet(uint256 secs) internal {
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    /// +1 when a dearer coin is a higher pool tick (the coin as currency0), -1 when it is a lower one.
    function _dearer(PoolKey memory key) internal view returns (int256) {
        return _quoteIsCurrency0(key) ? int256(-1) : int256(1);
    }

    /// How far the coin's price stands above `from`, in ticks (negative below).
    function _above(PoolKey memory key, int24 tick, int24 from) internal view returns (int256) {
        return (int256(tick) - int256(from)) * _dearer(key);
    }

    function _fund(PoolKey memory key, address who) internal {
        if (_native(key)) vm.deal(who, 100_000 ether);
        else mockQuote.mint(who, 1_000_000 ether);
    }

    // ---------------------------------------------------------------- at launch and after a quiet

    /// Before a pool's first swap its reference is the price it opened at; a First Buy in the launch's own
    /// transaction starts it there, not at the price the First Buy reached; a quiet afterwards is followed.
    function test_reference_startsAtTheOpenPrice() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory none = _rewardCoin(Pair(p), 0);
            int24 openTick = _tickOf(none);
            assertEq(_ref(none), openTick, "before any swap: the open price");
            _quiet(1 days);
            assertEq(_ref(none), openTick, "no swap, no move");

            PoolKey memory bought = _rewardCoin(Pair(p), Pair(p) == Pair.Native ? 0.1 ether : 1 ether);
            assertGt(_above(bought, _tickOf(bought), openTick), 0, "the First Buy lifted the price");
            assertEq(_ref(bought), openTick, "the reference starts at the open price");
            _quiet(1 days);
            assertEq(_ref(bought), _tickOf(bought), "after a quiet day: the price the First Buy left");
        }
    }

    /// A standard coin keeps no reference and its swaps pay nothing for one: it answers its own tick.
    function test_reference_aStandardCoinKeepsNone() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _trade(key, trader, true, true, 10 ether);
        assertEq(_ref(key), _tickOf(key), "standard: its own tick");
        (, PoolKey memory native) = _launchNative(0.1 ether, address(0));
        _trade(native, trader, true, true, 1 ether);
        assertEq(_ref(native), _tickOf(native), "standard native: its own tick");
    }

    // ---------------------------------------------------------------- inside one block

    /// A swap that lifts the price and is undone in the same block moves the reference by nothing, then or
    /// later: the next swap credits the time since to the price that stood, the old one.
    function test_reference_spikeUndoneInOneBlock_movesNothing() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            int24 r0 = _ref(key);
            _quiet(60);
            _trade(key, trader, true, true, _depth(key) * 3);
            assertGt(_above(key, _tickOf(key), r0), 1_000, "lifted");
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
            assertEq(_ref(key), r0, "the same block: nothing");
            _quiet(1 hours);
            _trade(key, trader, true, true, 1e12);
            assertEq(_ref(key), r0, "an hour later: still nothing");
        }
    }

    /// A swap that drops the price and is undone in the same block moves it by nothing either.
    function test_reference_dipUndoneInOneBlock_movesNothing() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            // A holder, the price having stood since its buy.
            _trade(key, trader, true, true, _depth(key));
            _quiet(30 days);
            int24 r0 = _ref(key);
            assertEq(r0, _tickOf(key), "settled at the holder's price");
            uint256 held = _coinOfKey(key).balanceOf(trader);
            _trade(key, trader, false, true, held);
            assertLt(_above(key, _tickOf(key), r0), -1_000, "dropped");
            // Buy back exactly the coins sold, which brings the price back to within a tick of where it was.
            _trade(key, trader, true, false, held);
            assertEq(_ref(key), r0, "the same block: nothing");
            _quiet(1 hours);
            assertLe(_above(key, r0, _ref(key)), 1, "an hour later: within the tick the round trip left");
        }
    }

    // ---------------------------------------------------------------- a rise held

    /// A dearer coin is followed by the rise rate and no faster; once the price has stood the time that
    /// implies, Support Liquidity is placed near the price again and buys go through.
    function test_reference_riseFollowedAtTheRate_thenSpendingResumes() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            int24 r0 = _ref(key);
            uint256 capBefore = taxVault.pieceCap(key);
            _quiet(60);
            _trade(key, trader, true, true, _depth(key) / 4);
            int24 lifted = _tickOf(key);
            // A piece is capped at the depth at the reference, so a lifted price does not grow it.
            assertApproxEqRel(taxVault.pieceCap(key), capBefore, 0.0001e18, "the cap stays at the reference's");
            int256 rise = _above(key, lifted, r0);
            assertGt(rise, int256(uint256(BUY_BAND)) + 200, "a rise past the band");
            assertEq(_ref(key), r0, "reached a moment ago: nothing yet");

            // Each minute it stood moves the reference by the rise rate, exactly.
            uint256[3] memory minutes_ = [uint256(1), 10, 60];
            uint256 waited;
            for (uint256 i; i < 3; i++) {
                _quiet((minutes_[i] - waited) * 60);
                waited = minutes_[i];
                assertEq(_above(key, _ref(key), r0), int256(minutes_[i] * REFERENCE_RISE), "the rise rate per minute");
            }
            // Meanwhile a buy waits, by name, and Support Liquidity goes under the reference, not the price.
            vm.expectRevert(abi.encodeWithSelector(TaxVault.AboveReference.selector, lifted, _ref(key)));
            taxVault.burn(key);
            (Support memory s,) = _addSupport(key);
            assertLe(_above(key, _supportTop(key, s), _ref(key)), 0, "Support Liquidity under the reference");

            // Followed: the time the settings imply, and then the price is the reference.
            _quiet(uint256(rise) * 60 / REFERENCE_RISE);
            assertEq(_ref(key), lifted, "followed");
            _quiet(60);
            (s,) = _addSupport(key);
            int256 gap = _above(key, lifted, _supportTop(key, s));
            assertGe(gap, 0, "under the price");
            assertLe(gap, TICK_SPACING, "within one spacing of the price again");
            vm.prank(stranger);
            taxVault.burn(key);
        }
    }

    /// The tick on the Support Liquidity's coin-dear edge: its top with the coin as currency0, its bottom
    /// with the Quote Asset as currency0.
    function _supportTop(PoolKey memory key, Support memory s) internal view returns (int24) {
        return _quoteIsCurrency0(key) ? s.lower : s.upper;
    }

    // ---------------------------------------------------------------- a fall, then a lift back

    /// A real fall is followed within seconds, at the fall rate; a wallet that then lifts the price back to
    /// the old level finds the buys waiting and Support Liquidity under the fallen price, and loses.
    function test_reference_fallFollowedFast_thenALiftBackGainsNothing() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            _trade(key, trader, true, true, _depth(key));
            _quiet(30 days);
            int24 high = _tickOf(key);
            assertEq(_ref(key), high, "the old level stood for a month");

            uint256 sold = _coinOfKey(key).balanceOf(trader);
            _trade(key, trader, false, true, sold);
            int24 low = _tickOf(key);
            int256 fall = _above(key, high, low);
            assertGt(fall, 2_000, "a real fall");
            _quiet(1);
            assertEq(_above(key, high, _ref(key)), int256(uint256(REFERENCE_FALL) / 60), "one second's fall");
            _quiet(uint256(fall) * 60 / REFERENCE_FALL + 1);
            assertEq(_ref(key), low, "followed within seconds");

            // The wallet lifts it back to the old level and holds while the pieces are called.
            uint256 snap = vm.snapshotState();
            _fund(key, attacker);
            uint256 before = _quoteBalanceOf(key, attacker);
            // Buying back exactly the coins the fall sold.
            _trade(key, attacker, true, false, sold);
            assertLt(_above(key, high, _tickOf(key)), 300, "lifted back near the old level");
            for (uint256 i; i < 40; i++) {
                _quiet(60);
                vm.startPrank(attacker);
                try taxVault.addSupport(key) {} catch {}
                try taxVault.burn(key) {
                    revert("a buy went through under a lifted price");
                } catch {}
                try taxVault.buyForHolders(key) {
                    revert("a buy went through under a lifted price");
                } catch {}
                vm.stopPrank();
            }
            _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
            assertLt(_quoteBalanceOf(key, attacker), before, "the lift back loses");
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- the buys' own clocks

    /// The burn's and the holders' buys keep separate clocks: one of each in the same block goes through
    /// once a seller has brought the price back under the reference, a second of either waits its interval,
    /// so a caller who always chooses the burn cannot hold off the holders' buys.
    function test_buys_burnAndHoldersKeepSeparateClocks() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            _trade(key, trader, true, true, _depth(key) / 10);
            _quiet(30 days);
            vm.prank(stranger);
            taxVault.burn(key);
            // The burn's own buy left the price above the reference; a holder's sale brings it back under.
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
            vm.startPrank(stranger);
            taxVault.buyForHolders(key);
            uint256 next = vm.getBlockTimestamp() + PIECE_INTERVAL;
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, next));
            taxVault.burn(key);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, next));
            taxVault.buyForHolders(key);
            vm.stopPrank();
        }
    }

    /// With the band at 0 the vault's own buy is judged like anyone's: after a burn at the reference, the
    /// next buy waits until the reference has followed the burn's own move.
    function test_buys_theVaultsOwnBuyIsFollowedLikeAnyOther() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            int24 r = _ref(key);
            vm.prank(stranger);
            taxVault.burn(key);
            int24 moved = _tickOf(key);
            int256 impact = _above(key, moved, r);
            assertGt(impact, 0, "the burn's buy moved the price");
            _quiet(PIECE_INTERVAL);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.AboveReference.selector, moved, _ref(key)));
            vm.prank(stranger);
            taxVault.buyForHolders(key);
            _quiet(uint256(impact) * 60 / REFERENCE_RISE);
            vm.prank(stranger);
            taxVault.buyForHolders(key);
        }
    }

    /// The buys' check is the band above the reference, edge for edge: at `BUY_BAND` ticks above it a buy
    /// goes through, one tick more and it waits by name.
    function test_buys_bandEdge() public {
        for (uint256 p; p < 3; p++) {
            PoolKey memory key = _settled(Pair(p));
            int24 r = _ref(key);
            uint256 snap = vm.snapshotState();
            // Find the largest buy that leaves the price within the band, by halving.
            uint256 lo = 0;
            uint256 hi = _depth(key);
            for (uint256 i; i < 80; i++) {
                uint256 mid = (lo + hi) / 2;
                _trade(key, trader, true, true, mid + 1e6);
                bool within = _above(key, _tickOf(key), r) <= int256(uint256(BUY_BAND));
                vm.revertToState(snap);
                snap = vm.snapshotState();
                if (within) lo = mid;
                else hi = mid;
            }
            _trade(key, trader, true, true, lo + 1e6);
            assertEq(_above(key, _tickOf(key), r), int256(uint256(BUY_BAND)), "at the band's edge");
            uint256 at = vm.snapshotState();
            vm.prank(stranger);
            taxVault.burn(key);
            vm.revertToState(at);
            _trade(key, trader, true, true, 1e15);
            int24 past = _tickOf(key);
            assertGt(_above(key, past, r), int256(uint256(BUY_BAND)), "past the edge");
            vm.expectRevert(abi.encodeWithSelector(TaxVault.AboveReference.selector, past, r));
            vm.prank(stranger);
            taxVault.burn(key);
            vm.expectRevert(abi.encodeWithSelector(TaxVault.AboveReference.selector, past, r));
            vm.prank(stranger);
            taxVault.buyForHolders(key);
        }
    }

    // ---------------------------------------------------------------- the settings

    /// The rates are the Tax Vault's settings, fixed at its deployment and read by the hook in its
    /// constructor; out-of-bounds settings are refused, and the bounds' edges deploy.
    function test_settings_fixedAtDeploymentAndBounded() public {
        assertEq(taxVault.referenceRiseTicksPerMinute(), REFERENCE_RISE);
        assertEq(taxVault.referenceFallTicksPerMinute(), REFERENCE_FALL);
        assertEq(taxVault.buyBandTicks(), BUY_BAND);

        IHoldersPart d = holdersPart;
        IPoolManager m = pm;
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        this.create(abi.encodePacked(type(TaxVault).creationCode, abi.encode(m, stranger, d, 50, 60, 10, 0, 60_000, 200)));
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        this.create(abi.encodePacked(type(TaxVault).creationCode, abi.encode(m, stranger, d, 50, 60, 10, 1_001, 60_000, 200)));
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        this.create(abi.encodePacked(type(TaxVault).creationCode, abi.encode(m, stranger, d, 50, 60, 10, 2, 1, 200)));
        vm.expectRevert(TaxVault.InvalidSettings.selector);
        this.create(abi.encodePacked(type(TaxVault).creationCode, abi.encode(m, stranger, d, 50, 60, 10, 2, 60_000, 2_001)));
        new TaxVault(m, stranger, d, 50, 60, 10, 1_000, 1_000, 2_000);
        new TaxVault(m, stranger, d, 50, 60, 10, 1, type(uint24).max, 0);
    }
}
