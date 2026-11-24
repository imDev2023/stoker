// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {IQuoteListings} from "../../src/interfaces/IQuoteListings.sol";

/// The Quote Registry (ADR 0028): only the Admin writes it; a Listing takes one write a day, a routine
/// write moves a start price by 25% at most, a deliberate change is scheduled and readable at once, applies
/// 48 hours later and can be withdrawn before then; and no write touches a coin already launched.
contract RegistryTest is LocalBase {
    using StateLibrary for IPoolManager;

    address internal constant ASSET = address(0xA55E7);

    function _list(address asset) internal {
        vm.prank(platform);
        registry.list(asset, START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
    }

    function _write(int24 tick) internal {
        vm.prank(platform);
        registry.writeStartPrice(address(quote), tick);
    }

    function _schedule(int24 tick, uint16 multiple, uint16 cap) internal {
        vm.prank(platform);
        registry.scheduleChange(address(quote), tick, multiple, cap);
    }

    function _listing(address asset) internal view returns (IQuoteListings.Listing memory) {
        return registry.listingOf(asset);
    }

    // ------------------------------------------------ a new Listing

    function test_registry_list_oneWriteByTheAdmin_readAtOnce() public {
        assertFalse(_listing(ASSET).listed, "never listed");
        vm.expectEmit(true, true, true, true, address(registry));
        emit QuoteRegistry.Listed(ASSET, START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        _list(ASSET);
        IQuoteListings.Listing memory l = _listing(ASSET);
        assertTrue(l.listed);
        assertEq(l.startTick, START_TICK);
        assertEq(l.graduationMultiple, GRADUATION_MULTIPLE);
        assertEq(l.referrerFeeCapBps, REFERRER_FEE_CAP_BPS);
        assertEq(registry.lastWriteAt(ASSET), vm.getBlockTimestamp());
    }

    function test_registry_onlyTheAdminWrites() public {
        address[3] memory others = [stranger, creator, trader];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(QuoteRegistry.NotAdmin.selector);
            registry.list(ASSET, START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
            vm.expectRevert(QuoteRegistry.NotAdmin.selector);
            registry.writeStartPrice(address(quote), START_TICK + 200);
            vm.expectRevert(QuoteRegistry.NotAdmin.selector);
            registry.scheduleChange(address(quote), START_TICK, 30, REFERRER_FEE_CAP_BPS);
            vm.expectRevert(QuoteRegistry.NotAdmin.selector);
            registry.withdrawChange(address(quote));
            vm.expectRevert(QuoteRegistry.NotAdmin.selector);
            registry.delist(address(quote));
            vm.stopPrank();
        }
    }

    /// A server key is not the Admin either: the round key, the ladder key and the Keeper write nothing.
    function test_registry_noServerKeyWrites() public {
        StokerKeys.Role[3] memory roles = [StokerKeys.Role.RoundKey, StokerKeys.Role.LadderKey, StokerKeys.Role.Keeper];
        for (uint256 i; i < roles.length; i++) {
            address holder = makeAddr(string.concat("key", vm.toString(i)));
            vm.prank(platform);
            keys.proposeKey(roles[i], holder);
            vm.prank(holder);
            keys.acceptKey(roles[i]);
            vm.prank(holder);
            vm.expectRevert(QuoteRegistry.NotAdmin.selector);
            registry.list(ASSET, START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        }
    }

    function test_registry_list_onceOnly() public {
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.AlreadyListed.selector, address(quote)));
        registry.list(address(quote), START_TICK + 2_000, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
    }

    function test_registry_refusesFiguresOutsideItsBounds() public {
        vm.startPrank(platform);
        // A start price off the pools' tick spacing, or with no room above it for the Graduation Target.
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidStartTick.selector, START_TICK + 1));
        registry.list(ASSET, START_TICK + 1, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        int24 top = TickMath.maxUsableTick(TICK_SPACING) - registry.GRADUATION_HEADROOM();
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidStartTick.selector, top));
        registry.list(ASSET, top, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        int24 bottom = TickMath.minUsableTick(TICK_SPACING);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidStartTick.selector, bottom));
        registry.list(ASSET, bottom, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        // A Graduation multiple of at least 2 and at most 1,000.
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidGraduationMultiple.selector, 1));
        registry.list(ASSET, START_TICK, 1, REFERRER_FEE_CAP_BPS);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidGraduationMultiple.selector, 1_001));
        registry.list(ASSET, START_TICK, 1_001, REFERRER_FEE_CAP_BPS);
        // A Referrer Fee cap of at most 5%.
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidReferrerFeeCap.selector, 501));
        registry.list(ASSET, START_TICK, GRADUATION_MULTIPLE, 501);
        // The edges themselves are taken.
        registry.list(ASSET, top - TICK_SPACING, 1_000, 500);
        registry.list(address(0xB0B), bottom + TICK_SPACING, 2, 0);
        vm.stopPrank();
    }

    function test_registry_constructor_refusesAMisconfiguration() public {
        vm.expectRevert(QuoteRegistry.InvalidSettings.selector);
        new QuoteRegistry(StokerKeys(address(0)), TICK_SPACING);
        vm.expectRevert(QuoteRegistry.InvalidSettings.selector);
        new QuoteRegistry(keys, 0);
        vm.expectRevert(QuoteRegistry.InvalidSettings.selector);
        new QuoteRegistry(keys, TickMath.MAX_TICK_SPACING + 1);
    }

    // ------------------------------------------------ one write a day

    function test_registry_secondWriteInsideADay_reverts() public {
        // The Listing was written at setUp; a routine write the same day is refused, to the second.
        uint256 next = registry.lastWriteAt(address(quote)) + 1 days;
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.WriteTooSoon.selector, next));
        registry.writeStartPrice(address(quote), START_TICK + 200);

        vm.warp(next - 1);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.WriteTooSoon.selector, next));
        registry.writeStartPrice(address(quote), START_TICK + 200);

        vm.warp(next);
        vm.expectEmit(true, true, true, true, address(registry));
        emit QuoteRegistry.StartPriceWritten(address(quote), START_TICK, START_TICK + 200);
        _write(START_TICK + 200);
        assertEq(_listing(address(quote)).startTick, START_TICK + 200);

        // And the next write waits another day after that one.
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.WriteTooSoon.selector, next + 1 days));
        registry.writeStartPrice(address(quote), START_TICK);
        // A scheduled change is a write as well.
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.WriteTooSoon.selector, next + 1 days));
        registry.scheduleChange(address(quote), START_TICK, 30, REFERRER_FEE_CAP_BPS);
    }

    // ------------------------------------------------ a routine write moves 25% at most

    /// On a registry with a tick spacing of 1, so the edges are reached exactly: up to 2,231 ticks up
    /// (x1.24995) and 2,876 down (x0.75008) are taken; one tick more either way is over 25% and refused.
    function test_registry_routineWriteOver25Percent_reverts() public {
        QuoteRegistry fine = new QuoteRegistry(keys, 1);
        int24[2] memory bases = [int24(0), START_TICK];
        for (uint256 b; b < bases.length; b++) {
            address asset = address(uint160(0xF00 + b));
            int24 base = bases[b];
            vm.prank(platform);
            fine.list(asset, base, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);

            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(platform);
            vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.MoveTooLarge.selector, base, base + 2_232));
            fine.writeStartPrice(asset, base + 2_232);
            vm.prank(platform);
            vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.MoveTooLarge.selector, base, base - 2_877));
            fine.writeStartPrice(asset, base - 2_877);
            vm.prank(platform);
            fine.writeStartPrice(asset, base + 2_231);

            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(platform);
            vm.expectRevert(
                abi.encodeWithSelector(QuoteRegistry.MoveTooLarge.selector, base + 2_231, base + 2_231 - 2_877)
            );
            fine.writeStartPrice(asset, base + 2_231 - 2_877);
            vm.prank(platform);
            fine.writeStartPrice(asset, base + 2_231 - 2_876);
            assertEq(fine.listingOf(asset).startTick, base + 2_231 - 2_876);
        }
    }

    /// The tick bounds are 25% as prices: 1.0001^2231 <= 1.25 < 1.0001^2232 and
    /// 1.0001^-2876 >= 0.75 > 1.0001^-2877, read from v4's own price at each tick.
    function test_registry_theBoundsAre25PercentAsPrices() public pure {
        // price = (sqrtPrice / 2^96)^2, so price * 4 <= 5 is sqrt^2 * 4 <= 5 * 2^192.
        uint256 q192 = uint256(1) << 192;
        assertLe(_sq(TickMath.getSqrtPriceAtTick(2_231)) * 4, 5 * q192, "2,231 ticks up is at most +25%");
        assertGt(_sq(TickMath.getSqrtPriceAtTick(2_232)) * 4, 5 * q192, "2,232 ticks up is over +25%");
        assertGe(_sq(TickMath.getSqrtPriceAtTick(-2_876)) * 4, 3 * q192, "2,876 ticks down is at most -25%");
        assertLt(_sq(TickMath.getSqrtPriceAtTick(-2_877)) * 4, 3 * q192, "2,877 ticks down is over -25%");
    }

    function _sq(uint160 x) internal pure returns (uint256) {
        return uint256(x) * uint256(x);
    }

    function test_registry_routineWrite_onTheSpacing_insideTheBand() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidStartTick.selector, START_TICK + 100));
        registry.writeStartPrice(address(quote), START_TICK + 100);
        // 2,400 ticks (+27%) is over the band; 2,200 (+24.6%) is in it.
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.MoveTooLarge.selector, START_TICK, START_TICK + 2_400));
        registry.writeStartPrice(address(quote), START_TICK + 2_400);
        _write(START_TICK + 2_200);
        assertEq(_listing(address(quote)).startTick, START_TICK + 2_200);
    }

    function test_registry_routineWrite_needsAListing() public {
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.NotListed.selector, ASSET));
        registry.writeStartPrice(ASSET, START_TICK);
    }

    // ------------------------------------------------ a scheduled change

    function test_registry_scheduledChange_readableAtOnce_appliesAfter48Hours() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        int24 farTick = START_TICK + 20_000; // x7.4, far beyond a routine write
        uint256 effectiveAt = vm.getBlockTimestamp() + 48 hours;
        vm.expectEmit(true, true, true, true, address(registry));
        emit QuoteRegistry.ChangeScheduled(address(quote), farTick, 30, 50, effectiveAt);
        _schedule(farTick, 30, 50);

        // Readable on-chain at once.
        QuoteRegistry.ScheduledChange memory c = registry.scheduledChangeOf(address(quote));
        assertEq(c.startTick, farTick);
        assertEq(c.graduationMultiple, 30);
        assertEq(c.referrerFeeCapBps, 50);
        assertEq(c.effectiveAt, effectiveAt);

        // Not in force a second early.
        vm.warp(effectiveAt - 1);
        IQuoteListings.Listing memory l = _listing(address(quote));
        assertEq(l.startTick, START_TICK);
        assertEq(l.graduationMultiple, GRADUATION_MULTIPLE);
        assertEq(l.referrerFeeCapBps, REFERRER_FEE_CAP_BPS);

        // In force at 48 hours, with nobody calling anything.
        vm.warp(effectiveAt);
        l = _listing(address(quote));
        assertEq(l.startTick, farTick);
        assertEq(l.graduationMultiple, 30);
        assertEq(l.referrerFeeCapBps, 50);
        assertEq(registry.scheduledChangeOf(address(quote)).effectiveAt, 0, "no change waits any more");

        // A coin launched now opens at the new start price.
        (, PoolKey memory key) = _launch(false, 0);
        (, int24 tick,,) = pm.getSlot0(key.toId());
        assertEq(tick, farTick);
    }

    function test_registry_scheduledChange_withdrawnBeforeItApplies() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _schedule(START_TICK + 20_000, 30, 50);
        uint256 effectiveAt = vm.getBlockTimestamp() + 48 hours;

        vm.warp(effectiveAt - 1);
        vm.expectEmit(true, true, true, true, address(registry));
        emit QuoteRegistry.ChangeWithdrawn(address(quote));
        vm.prank(platform);
        registry.withdrawChange(address(quote));
        assertEq(registry.scheduledChangeOf(address(quote)).effectiveAt, 0);

        vm.warp(effectiveAt + 30 days);
        IQuoteListings.Listing memory l = _listing(address(quote));
        assertEq(l.startTick, START_TICK, "never applied");
        assertEq(l.graduationMultiple, GRADUATION_MULTIPLE);
        assertEq(l.referrerFeeCapBps, REFERRER_FEE_CAP_BPS);
    }

    function test_registry_scheduledChange_cannotBeWithdrawnOnceInForce() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _schedule(START_TICK + 20_000, 30, 50);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.NoChangePending.selector, address(quote)));
        registry.withdrawChange(address(quote));
        assertEq(_listing(address(quote)).startTick, START_TICK + 20_000);
    }

    function test_registry_scheduledChange_oneAtATime_andNoRoutineWriteMeanwhile() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _schedule(START_TICK + 20_000, 30, 50);
        uint256 effectiveAt = vm.getBlockTimestamp() + 48 hours;
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.ChangePending.selector, effectiveAt));
        registry.scheduleChange(address(quote), START_TICK, 40, 50);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.ChangePending.selector, effectiveAt));
        registry.writeStartPrice(address(quote), START_TICK + 200);
    }

    /// The moment a change comes into force counts as the Listing's write: the next routine write waits a
    /// day after it and moves at most 25% from the new start price.
    function test_registry_scheduledChange_countsAsTheWriteOfTheDayItApplies() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        int24 farTick = START_TICK + 20_000;
        _schedule(farTick, 30, 50);
        uint256 effectiveAt = vm.getBlockTimestamp() + 48 hours;
        vm.warp(effectiveAt + 1 days - 1);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.WriteTooSoon.selector, effectiveAt + 1 days));
        registry.writeStartPrice(address(quote), farTick + 200);

        vm.warp(effectiveAt + 1 days);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.MoveTooLarge.selector, farTick, START_TICK));
        registry.writeStartPrice(address(quote), START_TICK);
        _write(farTick + 2_200);
        assertEq(_listing(address(quote)).startTick, farTick + 2_200);
        assertEq(_listing(address(quote)).graduationMultiple, 30);
    }

    function test_registry_scheduledChange_figuresInsideTheBounds() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidGraduationMultiple.selector, 0));
        registry.scheduleChange(address(quote), START_TICK, 0, 50);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidReferrerFeeCap.selector, 1_000));
        registry.scheduleChange(address(quote), START_TICK, 30, 1_000);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.InvalidStartTick.selector, START_TICK + 7));
        registry.scheduleChange(address(quote), START_TICK + 7, 30, 50);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.NeverListed.selector, ASSET));
        registry.scheduleChange(ASSET, START_TICK, 30, 50);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.NoChangePending.selector, address(quote)));
        registry.withdrawChange(address(quote));
        vm.stopPrank();
    }

    // ------------------------------------------------ delisting

    /// Delisting stops new Launches at once and harms nobody, so it is not held to the day; it withdraws a
    /// waiting change, and a delisted asset comes back only by a scheduled change, never by `list`, so the
    /// pair cannot step around the band or the 48 hours.
    function test_registry_delist_atOnce_andBackOnlyByASchedule() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _schedule(START_TICK + 20_000, 30, 50);
        vm.expectEmit(true, true, true, true, address(registry));
        emit QuoteRegistry.Delisted(address(quote));
        vm.prank(platform);
        registry.delist(address(quote));
        assertFalse(_listing(address(quote)).listed);
        assertEq(registry.scheduledChangeOf(address(quote)).effectiveAt, 0, "the waiting change is withdrawn");

        StokerFactory.LaunchParams memory p = _params(true, 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.NotListed.selector, address(quote)));
        factory.launch(p);

        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.AlreadyListed.selector, address(quote)));
        registry.list(address(quote), START_TICK + 20_000, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(QuoteRegistry.NotListed.selector, address(quote)));
        registry.writeStartPrice(address(quote), START_TICK);

        // The schedule was the day's write; a day on, a new one brings the asset back 48 hours later.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _schedule(START_TICK + 20_000, 30, 50);
        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        assertFalse(_listing(address(quote)).listed);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertTrue(_listing(address(quote)).listed);
        assertEq(_listing(address(quote)).startTick, START_TICK + 20_000);
    }

    // ------------------------------------------------ no write touches a launched coin

    function _terms(PoolKey memory key) internal view returns (StokerHook.Terms memory) {
        return hook.termsOf(key.toId());
    }

    /// A coin launched before any write keeps its own start price, Graduation multiple, Graduation Target
    /// and Referrer Fee cap; a coin launched after takes the new ones.
    function test_registry_aCoinLaunchedBeforeAWriteKeepsItsTerms() public {
        (, PoolKey memory before0) = _launch(true, 0);
        (, PoolKey memory before1) = _launch(false, 0);
        StokerHook.Terms memory t0 = _terms(before0);
        StokerHook.Terms memory t1 = _terms(before1);
        assertEq(t0.startTick, START_TICK);
        assertEq(t0.graduationMultiple, GRADUATION_MULTIPLE);
        assertEq(t0.referrerFeeCapBps, REFERRER_FEE_CAP_BPS);

        // A routine write, then a scheduled change of every figure.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _write(START_TICK + 2_200);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _schedule(START_TICK + 20_000, 30, 50);
        vm.warp(vm.getBlockTimestamp() + 48 hours);

        StokerHook.Terms memory a0 = _terms(before0);
        StokerHook.Terms memory a1 = _terms(before1);
        assertEq(abi.encode(a0), abi.encode(t0), "the first coin's terms, unchanged");
        assertEq(abi.encode(a1), abi.encode(t1), "the second coin's terms, unchanged");

        // A new coin takes the new figures; its target is its own.
        (creator, creatorKey) = makeAddrAndKey("laterCreator");
        (, PoolKey memory later) = _launch(true, 0);
        StokerHook.Terms memory tl = _terms(later);
        assertEq(tl.startTick, START_TICK + 20_000);
        assertEq(tl.graduationMultiple, 30);
        assertEq(tl.referrerFeeCapBps, 50);
        assertTrue(tl.graduationSqrtPriceX96 != t0.graduationSqrtPriceX96);
    }

    /// The Graduation Target is the start price times the Graduation multiple, as a price of the pool,
    /// in either currency order, rounded so it is never below that (and never easier to reach).
    function test_registry_theGraduationTargetIsTheStartPriceTimesTheMultiple() public {
        for (uint256 o; o < 2; o++) {
            bool q0 = o == 0;
            (, PoolKey memory key) = _launch(q0, 0);
            StokerHook.Terms memory t = _terms(key);
            (uint160 open,,,) = pm.getSlot0(key.toId());
            // The pool's price is coin per Quote Asset with the Quote Asset as currency0, so the target is
            // the open price divided by the multiple; otherwise multiplied.
            (uint256 hi, uint256 lo) =
                q0 ? (uint256(open), uint256(t.graduationSqrtPriceX96)) : (uint256(t.graduationSqrtPriceX96), open);
            // (hi / lo)^2 is the multiple, never below it (hi^2 >= m lo^2, exactly), and within a part in
            // 10^15 of it.
            uint256 hiSqOverLo = FullMath.mulDiv(hi, hi, lo);
            assertGe(hiSqOverLo, uint256(GRADUATION_MULTIPLE) * lo, "never below the multiple");
            uint256 ratio = FullMath.mulDiv(hiSqOverLo, 1e18, lo);
            assertApproxEqRel(ratio, uint256(GRADUATION_MULTIPLE) * 1e18, 1e3, "the multiple");
        }
    }
}
