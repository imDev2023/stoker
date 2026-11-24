// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Vm} from "forge-std/Vm.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";

/// The Opening Fee in the swap (#246, ADR 0026): for a Launch's first 20 seconds a buy pays an extra fee,
/// from the block's time alone, so that at the launch's own second its fees take 99% together, falling in a
/// straight line to the standing fees at 20 seconds. Proven from outside in all four swap types, with the
/// coin as currency0, as currency1 and paired with the native asset, on a standard coin, a Reward Launch and
/// a Stoke Launch, with and without a referrer, against the rule kept as a second, plain copy.
contract OpeningFeeTest is TaxLocalBase, OpeningFeeHelpers {
    using StateLibrary for IPoolManager;

    /// Every exact-in and exact-out buy at `elapsed` seconds, in every kind of pool, every type, with no
    /// referrer and with one at the cap, checked against the rule; each from a fresh launch.
    function _everyBuyAt(uint256 elapsed) internal {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 lt; lt < 3; lt++) {
                for (uint256 r; r < 2; r++) {
                    for (uint256 e; e < 2; e++) {
                        bool exactIn = e == 0;
                        uint256 referrerBps = r * REFERRER_FEE_CAP_BPS;
                        uint256 snap = vm.snapshotState();
                        PoolKey memory key = _launchOpen(kind, lt, 0);
                        vm.warp(_launchedAt(key) + elapsed);
                        Seen memory s = _tradeAndSee(key, true, exactIn, _buyAmount(key, exactIn), referrerBps);
                        uint256 taxBps = _taxBpsOf(key);
                        Fees memory f = _checkBuy(s, exactIn, elapsed, referrerBps, taxBps);
                        _checkTotal(s, f, exactIn, elapsed, referrerBps, taxBps);
                        vm.revertToState(snap);
                    }
                }
            }
        }
    }

    /// The fees together, as the ticket states them at the three seconds it names.
    function _checkTotal(Seen memory s, Fees memory f, bool exactIn, uint256 elapsed, uint256 rBps, uint256 tBps)
        internal
        view
    {
        uint256 taken = _taken(s);
        uint256 net = s.quoteIn - taken;
        if (elapsed == 0) {
            // 99% together at the launch's own second, rounded up once to the wei, a referrer or not: no
            // Referrer Fee fits under the start figure then.
            assertEq(s.referrerCredit, 0, "no Referrer Fee at the launch's own second");
            if (exactIn) assertEq(taken, _rateOfGross(s.quoteIn, OPENING_FEE_START_BPS), "99% of the payment");
            else assertEq(taken, _rateOfNet(net, OPENING_FEE_START_BPS, OPENING_FEE_START_BPS), "99% of gross");
            assertGt(f.opening, 0, "an Opening Fee was paid");
        } else if (elapsed == 10) {
            // Half the Opening Fee's start rate above the Platform Fee and the tax, which stay whole, and the
            // Referrer Fee whole too: half the schedule leaves room for any the Listing's cap allows.
            uint256 halfBps = (OPENING_FEE_START_BPS - PLATFORM_FEE_BPS - tBps + 1) / 2;
            assertEq(_referrerRateUnder(rBps, tBps, halfBps), rBps, "the Referrer Fee whole at ten seconds");
            uint256 rateBps = PLATFORM_FEE_BPS + tBps + halfBps + rBps;
            if (exactIn) assertEq(taken, _rateOfGross(s.quoteIn, rateBps), "the standing fees and half the rest");
            else assertEq(taken, _rateOfNet(net, rateBps, rateBps), "the standing fees and half the rest");
            // About half of 99%: between 49.5% and 53.5% of the payment, by the standing fees.
            assertGe(taken * B, s.quoteIn * 4_950, "about half");
            assertLe(taken * B, s.quoteIn * 5_350 + B, "about half");
        } else {
            assertEq(f.opening, 0, "no Opening Fee from 20 seconds on");
            assertEq(s.opening, 0, "nothing booked as an Opening Fee");
        }
    }

    function test_opening_buyAtTheLaunchSecond_feesTake99PercentTogether() public {
        _everyBuyAt(0);
    }

    function test_opening_buyAtTenSeconds_paysHalfTheOpeningFee() public {
        _everyBuyAt(10);
    }

    function test_opening_buyAtTwentySecondsAndAfter_paysNone() public {
        _everyBuyAt(20);
        _everyBuyAt(21);
        _everyBuyAt(1 days);
    }

    function test_opening_buyAtEverySecondOfTheWindow_matchesTheRule() public {
        for (uint256 elapsed; elapsed <= OPENING_FEE_DURATION; elapsed++) {
            for (uint256 kind; kind < 3; kind++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(kind, 1, 0);
                vm.warp(_launchedAt(key) + elapsed);
                Seen memory s = _tradeAndSee(key, true, elapsed % 2 == 0, _buyAmount(key, elapsed % 2 == 0), 50);
                _checkBuy(s, elapsed % 2 == 0, elapsed, 50, TAX_BPS);
                vm.revertToState(snap);
            }
        }
    }

    /// At the launch's own second the buy keeps exactly what is left after 99%, and the Platform Fee is the
    /// very figure the same payment pays after the window: no Credit grows by the Opening Fee.
    function test_opening_noCreditGrowsByIt() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 lt; lt < 3; lt++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(kind, lt, 0);
                uint256 amount = _buyAmount(key, true);
                uint256 inWindow = vm.snapshotState();
                Seen memory inside = _tradeAndSee(key, true, true, amount, REFERRER_FEE_CAP_BPS);
                vm.revertToState(inWindow);
                vm.warp(_launchedAt(key) + OPENING_FEE_DURATION);
                Seen memory outside = _tradeAndSee(key, true, true, amount, REFERRER_FEE_CAP_BPS);
                assertEq(inside.creatorCredit, outside.creatorCredit, "the Creator's Credit");
                assertEq(inside.platformCredit, outside.platformCredit, "the platform's Credit");
                // At the launch's own second no Referrer Fee fits under the start figure: the referrer the buy
                // named is credited nothing, never a share of the Opening Fee.
                assertEq(inside.referrerCredit, 0, "the referrer's Credit inside: nothing");
                assertGt(outside.referrerCredit, 0, "the referrer's Credit outside: its fee");
                assertEq(inside.tax, outside.tax, "the tax");
                assertGt(inside.opening, 0, "inside, an Opening Fee");
                assertEq(outside.opening, 0, "outside, none");
                vm.revertToState(snap);
            }
        }
    }

    /// The Creator's First Buy, the swap the factory makes inside the launch, pays the Platform Fee and the
    /// tax and no Opening Fee, in every kind of pool and every type.
    function test_opening_firstBuyPaysTheStandingFeesAlone() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 lt; lt < 3; lt++) {
                uint256 snap = vm.snapshotState();
                uint256 firstBuy = kind == 2 ? 0.1 ether : 1 ether;
                uint256 creditsBefore = _hookClaimsOrZero(kind);
                PoolKey memory key = _launchOpen(kind, lt, firstBuy);
                uint256 taxBps = _taxBpsOf(key);
                assertEq(hook.openingFeeBooked(key.toId()), 0, "no Opening Fee on the First Buy");
                assertEq(hook.taxBooked(key.toId()), _rateOfGross(firstBuy, taxBps), "the First Buy's tax");
                assertEq(
                    _hookClaimsOf(key) - creditsBefore,
                    _rateOfGross(firstBuy, PLATFORM_FEE_BPS),
                    "the First Buy's Platform Fee"
                );
                assertEq(_vaultClaims(key), hook.taxBooked(key.toId()), "the vault holds the tax alone");
                vm.revertToState(snap);
            }
        }
    }

    function _hookClaimsOrZero(uint256 kind) internal view returns (uint256) {
        return pm.balanceOf(address(hook), (kind == 2 ? NATIVE : _quoteCurrency()).toId());
    }

    /// A sell inside the window, exact in and exact out, pays the standing fees and no Opening Fee.
    function test_opening_sellsNeverPayIt() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 lt; lt < 3; lt++) {
                for (uint256 e; e < 2; e++) {
                    bool exactIn = e == 0;
                    uint256 snap = vm.snapshotState();
                    PoolKey memory key = _launchOpen(kind, lt, kind == 2 ? 0.1 ether : 1 ether);
                    // The Creator sells from the First Buy's coins at the launch's own second and at ten.
                    for (uint256 at; at <= 10; at += 10) {
                        vm.warp(_launchedAt(key) + at);
                        uint256 amount = exactIn ? _coinOfKey(key).balanceOf(creator) / 4 : (kind == 2 ? 1e12 : 1e15);
                        Seen memory s = _tradeAndSeeAs(creator, key, false, exactIn, amount, REFERRER_FEE_CAP_BPS);
                        assertEq(s.opening, 0, "a sell pays no Opening Fee");
                        uint256 taxBps = _taxBpsOf(key);
                        uint256 gross = s.quoteOut + s.creatorCredit + s.platformCredit + s.referrerCredit + s.tax;
                        if (exactIn) {
                            assertEq(s.creatorCredit + s.platformCredit, _rateOfGross(gross, PLATFORM_FEE_BPS), "fee");
                            assertEq(s.tax, _rateOfGross(gross, taxBps), "tax");
                        } else {
                            uint256 total = PLATFORM_FEE_BPS + REFERRER_FEE_CAP_BPS + taxBps;
                            assertEq(
                                s.creatorCredit + s.platformCredit,
                                _rateOfNet(s.quoteOut, PLATFORM_FEE_BPS, total),
                                "fee on net"
                            );
                            assertEq(s.tax, _rateOfNet(s.quoteOut, taxBps, total), "tax on net");
                        }
                    }
                    vm.revertToState(snap);
                }
            }
        }
    }

    // ---------------------------------------------------------------- the schedule

    /// For any two moments and any buy, the Opening Fee at the later is never more than at the earlier, the
    /// fees together never pass 99% of the payment (rounded up once to the wei), and from 20 seconds on the
    /// Opening Fee is exactly zero.
    function testFuzz_opening_neverRisesNeverAboveTheStartZeroAtTheEnd(
        uint256 kind,
        uint256 lt,
        bool exactIn,
        uint256 amountSeed,
        uint256 referrerBps,
        uint256 e1,
        uint256 e2
    ) public {
        kind = bound(kind, 0, 2);
        lt = bound(lt, 0, 2);
        referrerBps = bound(referrerBps, 0, REFERRER_FEE_CAP_BPS);
        e1 = bound(e1, 0, 2 * OPENING_FEE_DURATION);
        e2 = bound(e2, e1, 2 * OPENING_FEE_DURATION);
        PoolKey memory key = _launchOpen(kind, lt, 0);
        uint256 amount = exactIn
            ? bound(amountSeed, 1e6, _buyAmount(key, true) * 10)
            : bound(amountSeed, 1e12, _buyAmount(key, false) * 10);

        uint256 snap = vm.snapshotState();
        vm.warp(_launchedAt(key) + e1);
        Seen memory early = _tradeAndSee(key, true, exactIn, amount, referrerBps);
        _checkBuy(early, exactIn, e1, referrerBps, _taxBpsOf(key));
        vm.revertToState(snap);
        vm.warp(_launchedAt(key) + e2);
        Seen memory late = _tradeAndSee(key, true, exactIn, amount, referrerBps);
        _checkBuy(late, exactIn, e2, referrerBps, _taxBpsOf(key));

        assertLe(late.opening, early.opening, "never rises with time");
        assertLe(_taken(early), _rateOfGross(early.quoteIn, OPENING_FEE_START_BPS), "never past 99% of the payment");
        assertLe(_taken(late), _rateOfGross(late.quoteIn, OPENING_FEE_START_BPS), "never past 99% of the payment");
        if (e1 >= OPENING_FEE_DURATION) assertEq(early.opening, 0, "zero from 20 seconds on");
        if (e2 >= OPENING_FEE_DURATION) assertEq(late.opening, 0, "zero from 20 seconds on");
    }

    /// Five blocks sharing one timestamp, as on Base, pay the same Opening Fee for the same buy: the schedule
    /// reads the time alone. Among them the launch's own second, the next block keeping its timestamp.
    function test_opening_fiveBlocksOnOneTimestampPayTheSameFee() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 at; at < 20; at += 7) {
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(kind, 2, 0);
                vm.warp(_launchedAt(key) + at);
                uint256 amount = _buyAmount(key, true);
                uint256 first;
                for (uint256 i; i < 5; i++) {
                    vm.roll(vm.getBlockNumber() + 1);
                    Seen memory s = _tradeAndSee(key, true, true, amount, 0);
                    _checkBuy(s, true, at, 0, TAX_BPS);
                    if (i == 0) first = s.opening;
                    assertEq(s.opening, first, "the same Opening Fee in every block of the second");
                }
                vm.revertToState(snap);
            }
        }
    }

    /// A clock read before the launch's own second (no chain does this; a test can) still never charges more
    /// than the start figure: the Opening Fee is the launch second's.
    function test_opening_aClockThatRanBackChargesTheStartFigureAtMost() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            vm.warp(1_000);
            PoolKey memory key = _launchOpen(kind, 0, 0);
            vm.warp(_launchedAt(key) - 500);
            Seen memory s = _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
            _checkBuy(s, true, 0, 0, 0);
            assertEq(_taken(s), _rateOfGross(s.quoteIn, OPENING_FEE_START_BPS), "99%, never more");
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- the edges of the arithmetic

    /// At the launch's own second a buy of 100 wei keeps one wei for the pool and trades it, in every kind of
    /// pool, with the most a trade can name beside it; a buy of 99 wei, which 99% would take whole, is refused
    /// by name before the pool runs.
    function test_opening_at99PercentABuyStillTradesAndASwallowedOneIsRefused() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 1, 0);
            Seen memory s = _tradeAndSee(key, true, true, 100, REFERRER_FEE_CAP_BPS);
            assertEq(_taken(s), 99, "99 of 100 taken");
            assertGt(_coinOfKey(key).balanceOf(trader), 0, "the one wei left bought coins");

            bytes memory swallowed =
                _hookError(IHooks.beforeSwap.selector, abi.encodeWithSelector(StokerHook.SwapTooSmall.selector));
            if (_native(key)) {
                vm.expectRevert(swallowed);
                _swapNativeWithData(key, trader, true, true, 99, 0, TickMath.MIN_SQRT_PRICE + 1, "");
            } else {
                bool zeroForOne = _quoteIsCurrency0(key);
                uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
                vm.expectRevert(swallowed);
                _swapWithData(key, trader, true, true, 99, limit, "");
            }
            vm.revertToState(snap);
        }
    }

    /// For any buy of at least 100 wei at any second, the fees never swallow it and it never reverts for
    /// rounding alone: the pool always receives at least one wei.
    function testFuzz_opening_aBuyOfAHundredWeiOrMoreAlwaysTrades(
        uint256 kind,
        uint256 amount,
        uint256 elapsed,
        uint256 referrerBps
    ) public {
        kind = bound(kind, 0, 2);
        amount = bound(amount, 100, 1e21);
        elapsed = bound(elapsed, 0, OPENING_FEE_DURATION + 5);
        referrerBps = bound(referrerBps, 0, REFERRER_FEE_CAP_BPS);
        PoolKey memory key = _launchOpen(kind, 1, 0);
        vm.warp(_launchedAt(key) + elapsed);
        Seen memory s = _tradeAndSee(key, true, true, amount, referrerBps);
        assertEq(s.quoteIn, amount, "the whole payment");
        assertLt(_taken(s), amount, "something reached the pool");
        _checkBuy(s, true, elapsed, referrerBps, TAX_BPS);
    }

    /// A buy so small that the Platform Fee's and the tax's own roundings take more than the combined rate
    /// pays those and no Opening Fee, and is not refused: ten wei at 19 seconds with a referrer and a 5% tax.
    function test_opening_aBuyTheStandingRoundingsOutweighPaysThemAlone() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _tradeInOpening = true;
            (, PoolKey memory key) = _launchWith(
                _typedParams(
                    kind == 2 ? address(0) : address(quote),
                    kind == 1,
                    0,
                    StokerHook.LaunchType.Liquidity,
                    500,
                    0,
                    0,
                    StokerHook.PayoutAsset.QuoteAsset
                )
            );
            vm.warp(_launchedAt(key) + 19);
            Seen memory s = _tradeAndSee(key, true, true, 10, REFERRER_FEE_CAP_BPS);
            assertEq(s.opening, 0, "no Opening Fee");
            // A wei each of the Platform Fee and the tax; the Referrer Fee is what its rate adds to theirs and
            // the Opening Fee's, rounded once, which on ten wei is nothing.
            assertEq(_taken(s), 2, "a wei each of the Platform Fee and the tax");
            _checkBuy(s, true, 19, REFERRER_FEE_CAP_BPS, 500);
            vm.revertToState(snap);
        }
    }

    /// An exact-out buy of a single coin unit cannot round the fee to nothing: whatever the pool takes, the
    /// buyer pays 99 times it on top at the launch's own second.
    function test_opening_exactOutBuyCannotRoundTheFeeToNothing() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, 0);
            for (uint256 coins = 1; coins <= 1e12; coins *= 1_000) {
                Seen memory s = _tradeAndSee(key, true, false, coins, 0);
                uint256 net = s.quoteIn - _taken(s);
                assertGe(net, 1, "the pool took something");
                assertEq(_taken(s), net * 99, "99 times the net on top");
                _checkBuy(s, false, 0, 0, 0);
            }
            vm.revertToState(snap);
        }
    }

    /// `SwapStoppedEarly` counts the Opening Fee with the other three: inside the window an exact-in buy its
    /// own price limit stops is refused by name, with and without a referrer, in every kind of pool; the
    /// same buy with the coin specified goes through and pays on the Quote Asset that really moved.
    function test_opening_aBuyStoppedEarlyIsRefusedAndExactOutPaysOnWhatMoved() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 r; r < 2; r++) {
                uint256 referrerBps = r * REFERRER_FEE_CAP_BPS;
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(kind, 1, 0);
                vm.warp(_launchedAt(key) + 3);
                uint160 limit = _limitOneSpacingAway(key);
                bytes memory stopped =
                    _hookError(IHooks.afterSwap.selector, abi.encodeWithSelector(StokerHook.SwapStoppedEarly.selector));
                uint256 big = _native(key) ? 500 ether : 500_000 ether;
                if (_native(key)) {
                    vm.expectRevert(stopped);
                    _swapNativeWithData(key, trader, true, true, big, 0, limit, _data(referrerBps));
                } else {
                    _approveRouter(key, trader);
                    vm.expectRevert(stopped);
                    _swapWithData(key, trader, true, true, big, limit, _data(referrerBps));
                }
                // The coin specified, the same limit: it stops at the limit and pays on what moved.
                Seen memory before = _snapshot(key, trader);
                if (_native(key)) {
                    _swapNativeWithData(key, trader, true, false, 1e30, trader.balance, limit, _data(referrerBps));
                } else {
                    _swapWithData(key, trader, true, false, 1e30, limit, _data(referrerBps));
                }
                Seen memory afterwards = _snapshot(key, trader);
                assertEq(_sqrtPrice(key), limit, "stopped at its limit");
                Seen memory s;
                s.quoteIn = before.quoteIn - afterwards.quoteIn;
                s.creatorCredit = afterwards.creatorCredit - before.creatorCredit;
                s.platformCredit = afterwards.platformCredit - before.platformCredit;
                s.referrerCredit = afterwards.referrerCredit - before.referrerCredit;
                s.tax = afterwards.tax - before.tax;
                s.opening = afterwards.opening - before.opening;
                _checkBuy(s, false, 3, referrerBps, TAX_BPS);
                vm.revertToState(snap);
            }
        }
    }

    /// A price one tick spacing past the pool's, the way a buy moves it.
    function _limitOneSpacingAway(PoolKey memory key) internal view returns (uint160) {
        int24 tick = _tickOf(key);
        return _quoteIsCurrency0(key)
            ? TickMath.getSqrtPriceAtTick(tick - TICK_SPACING)
            : TickMath.getSqrtPriceAtTick(tick + TICK_SPACING);
    }

    // ---------------------------------------------------------------- its terms

    /// Every Launch carries its Opening Fee as terms written at launch from the factory's settings: its own
    /// second, read by the hook, the start figure and the duration, with their event.
    function test_opening_termsAreWrittenAtLaunchFromTheSettings() public {
        assertEq(factory.openingFeeStartBps(), OPENING_FEE_START_BPS, "the factory's start figure");
        assertEq(factory.openingFeeDuration(), OPENING_FEE_DURATION, "the factory's duration");
        vm.warp(123_456);
        for (uint256 kind; kind < 3; kind++) {
            vm.recordLogs();
            PoolKey memory key = _launchOpen(kind, kind, 0);
            StokerHook.Terms memory t = hook.termsOf(key.toId());
            assertEq(t.launchedAt, 123_456, "the launch's own second");
            assertEq(t.openingFeeStartBps, OPENING_FEE_START_BPS, "the start figure");
            assertEq(t.openingFeeDuration, OPENING_FEE_DURATION, "the duration");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool seen;
            for (uint256 i; i < logs.length; i++) {
                if (
                    logs[i].emitter == address(hook)
                        && logs[i].topics[0] == StokerHook.OpeningFeeTermsRegistered.selector
                ) {
                    assertEq(logs[i].topics[1], PoolId.unwrap(key.toId()), "its pool");
                    (uint64 at, uint16 startBps, uint32 duration) = abi.decode(logs[i].data, (uint64, uint16, uint32));
                    assertEq(at, 123_456);
                    assertEq(startBps, OPENING_FEE_START_BPS);
                    assertEq(duration, OPENING_FEE_DURATION);
                    seen = true;
                }
            }
            assertTrue(seen, "the terms' event");
        }
    }

    /// A buy's Opening Fee is its own event, with the claims minted to the vault.
    function test_opening_eachBuysOpeningFeeIsAnEvent() public {
        PoolKey memory key = _launchOpen(0, 0, 0);
        uint256 amount = _buyAmount(key, true);
        Fees memory f = _feesOfGross(amount, 0, 0, _openingRateAt(0, PLATFORM_FEE_BPS));
        _approveRouter(key, trader);
        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.OpeningFeeBooked(key.toId(), _quoteOfKey(key), f.opening);
        _swapApproved(key, trader, true, true, amount);
    }
}

