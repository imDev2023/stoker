// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vm} from "forge-std/Vm.sol";
import {LocalBase} from "../utils/LocalBase.sol";
import {HoldAttacker} from "../utils/HoldAttacker.sol";
import {FlashReset, SwapThenGraduate} from "../utils/FlashReset.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";

/// The Graduation Hold (#244, ADR 0024), proven from outside in every pairing: the coin as currency0, the
/// coin as currency1 (where the pool's price falls as the coin's rises), and the native asset (always
/// currency0). "Above" and "below" always mean the coin's price against its Graduation Target.
/// The hold judges the price each transaction leaves, so every top-level call here is a transaction of its own.
/// forge-config: default.isolate = true
abstract contract GraduationCases is LocalBase {
    using StateLibrary for IPoolManager;

    PoolKey internal key;
    PoolId internal id;
    address internal coin;
    uint160 internal openPrice;
    /// More coins than any of these buys reaches before its price limit stops it: 95% of the seed would take
    /// the coin to 400 times its start price, and the target is 20.
    uint256 internal constant ALL_THE_COINS = 9.5e11 ether;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_800_000_000);
        vm.deal(trader, 1_000 ether);
        vm.deal(stranger, 1_000 ether);
        vm.deal(creator, 100 ether);
        key = _launchCase(0);
        id = key.toId();
        coin = Currency.unwrap(_coinIs0(key) ? key.currency0 : key.currency1);
        (openPrice,,,) = pm.getSlot0(id);
        _approveAll(trader);
        _approveAll(stranger);
    }

    // ------------------------------------------------ what each pairing fills in

    function _launchCase(uint256 firstBuy) internal virtual returns (PoolKey memory);
    /// A second Launch by the same Creator, under another name.
    function _launchAnother(uint256 firstBuy) internal virtual returns (PoolKey memory);
    function _native() internal pure virtual returns (bool);
    /// Quote Asset that buys across the target from the start price, with room to spare.
    function _crossingBuy() internal pure virtual returns (uint256);

    // ------------------------------------------------ the coin's price against the target

    function _coinIs0(PoolKey memory k) internal view returns (bool) {
        return !hook.termsOf(k.toId()).quoteIsCurrency0;
    }

    function _target() internal view returns (uint160) {
        return hook.termsOf(id).graduationSqrtPriceX96;
    }

    function _price() internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(id);
    }

    /// `p` moved `by` units of sqrt price toward the coin's cheap side.
    function _cheaper(uint160 p, uint160 by) internal view returns (uint160) {
        return _coinIs0(key) ? p - by : p + by;
    }

    /// The pool's price a hundredth of the target's sqrt price on the coin's dear side of it.
    function _above() internal view returns (uint160) {
        uint160 t = _target();
        return _coinIs0(key) ? t + t / 100 : t - t / 100;
    }

    function _atOrAbove() internal view returns (bool) {
        return _coinIs0(key) ? _price() >= _target() : _price() <= _target();
    }

    /// The hold as the price stands now: what the next transaction or `graduate` would judge.
    function _hold() internal view returns (uint256) {
        return hook.graduationNow(id).holdSince;
    }

    /// The hold as last judged and recorded.
    function _recordedHold() internal view returns (uint256) {
        return hook.graduationOf(id).holdSince;
    }

    function _graduatedAt() internal view returns (uint256) {
        return hook.graduationOf(id).graduatedAt;
    }

    // ------------------------------------------------ trading, one external call each

    function _approveAll(address who) internal {
        vm.startPrank(who);
        IERC20(coin).approve(address(swapRouter), type(uint256).max);
        if (!_native()) quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swapTo(address who, bool buy, bool exactIn, uint256 amount, uint160 limit) internal {
        if (_native()) _swapNativeWithData(key, who, buy, exactIn, amount, who.balance, limit, "");
        else _swapWithData(key, who, buy, exactIn, amount, limit, "");
    }

    function _noLimit(bool buy) internal view returns (uint160) {
        bool zeroForOne = _native() ? buy : buy == _isQuote0(key);
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// A buy that stops at `limit`, with the coin as its specified side, so its own limit stops it lawfully.
    function _buyTo(address who, uint160 limit) internal {
        _swapTo(who, true, false, ALL_THE_COINS, limit);
    }

    /// A sell of every coin `who` holds that stops at `limit`, the coin again the specified side.
    function _sellTo(address who, uint160 limit) internal {
        _swapTo(who, false, true, IERC20(coin).balanceOf(who), limit);
    }

    function _sellAll(address who) internal {
        _swapTo(who, false, true, IERC20(coin).balanceOf(who), _noLimit(false));
    }

    function _dustBuy(address who) internal {
        _swapTo(who, true, true, 1e12, _noLimit(true));
    }

    function _dustSell(address who) internal {
        _swapTo(who, false, true, 1 ether, _noLimit(false));
    }

    // ------------------------------------------------ the hold starts, runs and clears

    function test_hold_aBuyToTheTargetStartsIt() public {
        uint256 t0 = vm.getBlockTimestamp();
        _buyTo(trader, _target());
        assertEq(_price(), _target(), "the buy stopped on the target");
        assertEq(_hold(), t0, "the hold runs from the transaction that left the price there");
        assertEq(_recordedHold(), 0, "judged by the next transaction, not by this one");
        assertEq(_graduatedAt(), 0, "and nothing has graduated");

        // The next transaction to swap the pool judges the price this one left, and records the hold from it.
        vm.warp(t0 + 5 minutes);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.GraduationHoldStarted(id, t0);
        _dustBuy(trader);
        assertEq(_recordedHold(), t0, "recorded from the transaction that left the price there");
    }

    function test_hold_aWeiUnderTheTargetStartsNothing() public {
        _buyTo(trader, _cheaper(_target(), 1));
        assertFalse(_atOrAbove(), "a wei of sqrt price under the target");
        assertEq(_hold(), 0);
    }

    function test_hold_59MinutesDoesNotGraduate_anHourDoes_byTheNextSwap() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();

        vm.warp(start + 59 minutes);
        _dustBuy(trader);
        assertEq(_graduatedAt(), 0, "59 minutes");
        vm.warp(start + 1 hours - 1);
        _dustSell(trader);
        assertEq(_graduatedAt(), 0, "a second short of the hour");

        vm.warp(start + 1 hours);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.Graduated(id, start + 1 hours, start);
        _dustBuy(trader);
        assertEq(_graduatedAt(), start + 1 hours, "the hour");
        assertEq(_hold(), start, "the hold that graduated it is kept");
    }

    function test_hold_anHourGraduatesByThePublicCall_madeByAnyone() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();

        vm.warp(start + 59 minutes);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, start));
        vm.prank(stranger);
        hook.graduate(id);

        vm.warp(start + 1 hours);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.Graduated(id, start + 1 hours, start);
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(_graduatedAt(), start + 1 hours);
    }

    function test_hold_aSwapUnderTheTargetRestartsTheHour() public {
        _buyTo(trader, _above());
        uint256 first = vm.getBlockTimestamp();

        vm.warp(first + 50 minutes);
        _sellTo(trader, _cheaper(_target(), 1));
        assertEq(_hold(), 0, "cleared");

        // The next transaction judges the price the sell left, and records the hold's end.
        vm.warp(first + 55 minutes);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.GraduationHoldCleared(id, first);
        _buyTo(trader, _above());
        uint256 second = vm.getBlockTimestamp();
        assertEq(_hold(), second, "a new hold");

        vm.warp(first + 1 hours + 30 minutes);
        _dustBuy(trader);
        assertEq(_graduatedAt(), 0, "the first hold's time does not count");
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, second));
        hook.graduate(id);

        vm.warp(second + 1 hours);
        hook.graduate(id);
        assertEq(_graduatedAt(), second + 1 hours);
    }

    function test_hold_dustAboveTheTargetNeitherRestartsNorClearsIt() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 20 minutes);
        _dustBuy(trader);
        vm.warp(start + 40 minutes);
        _dustSell(trader);
        assertEq(_hold(), start, "the hold runs from its first swap");
        vm.warp(start + 1 hours);
        hook.graduate(id);
        assertEq(_graduatedAt(), start + 1 hours);
    }

    /// A swap its own price limit stops a wei from where it began still moves the price, and a wei under
    /// the target is under it.
    function test_hold_aSwapItsLimitStopsAtOnce_isJudgedByWhereItLeftThePrice() public {
        _buyTo(trader, _target());
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 10 minutes);
        _sellTo(trader, _cheaper(_target(), 1));
        assertEq(_hold(), 0, "a wei under the target clears the hold");

        vm.warp(start + 20 minutes);
        _buyTo(trader, _target());
        assertEq(_hold(), start + 20 minutes, "a wei back to the target starts it again");
    }

    /// A buy with the Quote Asset specified that its own limit would stop at the target is refused whole
    /// (#241's review), so it starts no hold.
    function test_hold_aRefusedSwapStartsNothing() public {
        uint256 big = _crossingBuy();
        uint160 target = _target();
        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(StokerHook.SwapStoppedEarly.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        vm.expectRevert(expected);
        _swapTo(trader, true, true, big, target);
        assertEq(_hold(), 0);
    }

    // ------------------------------------------------ crossing and leaving cannot graduate

    /// The spike review's forced Graduation as a flash loan: across the target and straight back inside one
    /// unlock. Only the price the transaction leaves is judged, so the price between the two swaps counts for
    /// nothing, and an hour later nothing graduates.
    function test_hold_acrossAndBackInOneUnlock_leavesTheCoinNotGraduated() public {
        HoldAttacker attacker = new HoldAttacker(pm, hook);
        if (_native()) vm.deal(address(attacker), 100 ether);
        else mockQuote.mint(address(attacker), 1_000 ether);

        attacker.roundTrip(key, _crossingBuy());
        uint160 midway = attacker.priceMidway();
        assertTrue(_coinIs0(key) ? midway >= _target() : midway <= _target(), "the buy crossed the target");
        assertEq(attacker.holdSeenMidway(), 0, "and recorded nothing: a swap inside a transaction is not judged");
        assertEq(_hold(), 0, "the price the transaction left is under the target");
        assertGt(attacker.cost(), 0, "the round trip paid its fees");

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, 0));
        hook.graduate(id);
        _dustBuy(trader);
        assertEq(_graduatedAt(), 0, "not graduated");
    }

    function test_hold_acrossAndBackInOneBlock_leavesTheCoinNotGraduated() public {
        _swapTo(trader, true, true, _crossingBuy(), _noLimit(true));
        assertTrue(_atOrAbove(), "crossed");
        assertEq(_hold(), vm.getBlockTimestamp());
        _sellAll(trader);
        assertEq(_hold(), 0, "cleared in the same block");
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _dustBuy(trader);
        assertEq(_graduatedAt(), 0, "not graduated");
    }

    /// A Creator's First Buy that crosses the target starts the hold inside the launch: it graduates only
    /// if the price stays there for the hour, open to every holder selling into it.
    function test_hold_aFirstBuyAcrossTheTargetStartsItAtLaunch() public {
        uint256 launchedAt = vm.getBlockTimestamp();
        PoolKey memory k = _launchAnother(_crossingBuy());
        PoolId kid = k.toId();
        assertEq(hook.graduationNow(kid).holdSince, launchedAt, "the hold runs from the launch");
        vm.warp(launchedAt + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, launchedAt));
        hook.graduate(kid);
        vm.warp(launchedAt + 1 hours);
        hook.graduate(kid);
        assertEq(hook.graduationOf(kid).graduatedAt, launchedAt + 1 hours);
        assertEq(_hold(), 0, "the other Launch's hold is its own");
    }

    /// The review of #269's finding, the other direction: inside one unlock a contract with no coins sells
    /// coins it does not own, taking the price under the target, and buys the same coins back. It resets
    /// nothing now: only the price the transaction leaves is judged, and that is where it began.
    function test_hold_aFlashSellAndBuyBackInOneUnlock_resetsNothing() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        FlashReset griefer = new FlashReset(pm, hook);
        if (_native()) vm.deal(address(griefer), 1 ether);
        else mockQuote.mint(address(griefer), 1 ether);

        for (uint256 i = 1; i <= 5; i++) {
            vm.warp(start + i * 11 minutes);
            griefer.reset(key, 1e10 ether);
            assertTrue(_coinIs0(key) ? griefer.priceMidway() < _target() : griefer.priceMidway() > _target());
            assertEq(IERC20(coin).balanceOf(address(griefer)), 0, "the griefer holds no coins");
            assertEq(_hold(), start, "the hold runs on from its start");
        }
        vm.warp(start + 1 hours);
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(_graduatedAt(), start + 1 hours, "and the coin graduates on the hour");
    }

    /// Inside a transaction that has swapped the pool, the price is not one a transaction has left, so the
    /// public call refuses to judge it, even for a hold that has run the hour.
    function test_graduate_inATransactionThatSwappedThePool_isRefused() public {
        _buyTo(trader, _above());
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        SwapThenGraduate both = new SwapThenGraduate(pm, hook);
        if (_native()) vm.deal(address(both), 1 ether);
        else mockQuote.mint(address(both), 1 ether);
        vm.expectRevert(StokerHook.SwappedThisTransaction.selector);
        both.run(key, 1e12);

        vm.prank(stranger);
        hook.graduate(id);
        assertGt(_graduatedAt(), 0, "the same call on its own records it");
    }

    /// A price a transaction left under the target never graduates, whatever an earlier judgement recorded.
    function test_graduate_aPriceLeftUnderNeverGraduates_whateverWasRecorded() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 minutes);
        _dustBuy(trader);
        assertEq(_recordedHold(), start, "the hold recorded");
        vm.warp(start + 40 minutes);
        _sellTo(trader, _cheaper(_target(), 1));
        assertEq(_recordedHold(), start, "still recorded: the sell's price is judged later");

        vm.warp(start + 3 hours);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, 0));
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(hook.graduationNow(id).graduatedAt, 0, "nothing to record");
        _dustBuy(trader);
        assertEq(_recordedHold(), 0, "the next transaction records the hold's end");
        assertEq(_graduatedAt(), 0);
    }

    // ------------------------------------------------ once recorded, for good

    function test_graduation_survivesThePriceFallingToTheStart() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 hours);
        hook.graduate(id);
        uint256 graduatedAt = _graduatedAt();

        _sellAll(trader);
        assertApproxEqRel(_price(), openPrice, 1e9, "back at the start price");
        assertFalse(_atOrAbove());
        assertEq(_graduatedAt(), graduatedAt, "still graduated, at the same time");

        _buyTo(trader, _above());
        vm.warp(vm.getBlockTimestamp() + 3 hours);
        _dustBuy(trader);
        vm.expectRevert(StokerHook.AlreadyGraduated.selector);
        hook.graduate(id);
        assertEq(_graduatedAt(), graduatedAt, "the timestamp never changes");
        assertEq(_hold(), start, "nor the hold that graduated it");
    }

    /// `Graduated` is emitted once per coin: no swap after it, across the target or under it, emits a hold's
    /// event or Graduation again, so the Indexer reads one Graduation.
    function test_graduation_isEmittedOnce_andNothingAfterIt() public {
        _buyTo(trader, _above());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _dustBuy(trader);
        assertGt(_graduatedAt(), 0, "graduated");

        vm.recordLogs();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _sellAll(trader);
        _buyTo(trader, _above());
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _dustBuy(trader);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            bytes32 sig = logs[i].topics[0];
            assertTrue(sig != StokerHook.Graduated.selector, "Graduated again");
            assertTrue(sig != StokerHook.GraduationHoldStarted.selector, "a hold started after Graduation");
            assertTrue(sig != StokerHook.GraduationHoldCleared.selector, "a hold cleared after Graduation");
        }
    }

    /// The hold ran unbroken for the hour before this swap, so the coin graduated an hour after the hold
    /// began, whatever the swap that records it does to the price.
    function test_graduation_theFirstSwapAfterTheHourRecordsIt_evenWhenItLeavesThePriceUnder() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 2 hours);
        vm.expectEmit(true, false, false, true, address(hook));
        emit StokerHook.Graduated(id, start + 1 hours, start);
        _sellAll(trader);
        assertFalse(_atOrAbove(), "the swap left the price under the target");
        assertEq(_graduatedAt(), start + 1 hours);
    }

    function test_graduation_aLateCallRecordsTheHoursEnd() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 3 days);
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(_graduatedAt(), start + 1 hours, "neither the caller nor the delay moves it");
    }

    // ------------------------------------------------ the public call

    function test_graduate_twice_reverts() public {
        _buyTo(trader, _above());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.graduate(id);
        vm.expectRevert(StokerHook.AlreadyGraduated.selector);
        vm.prank(stranger);
        hook.graduate(id);
    }

    function test_graduate_withNoHold_reverts() public {
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, 0));
        hook.graduate(id);
    }

    function test_graduate_aPoolThatIsNotOurs_reverts() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert(StokerHook.NotRegistered.selector);
        hook.graduate(other.toId());
    }

    // ------------------------------------------------ the clock

    function test_hold_readsTheTimeAndNotTheBlockNumber() public {
        _buyTo(trader, _above());
        uint256 start = vm.getBlockTimestamp();
        vm.roll(block.number + 1_000_000);
        _dustBuy(trader);
        assertEq(_graduatedAt(), 0, "a million blocks in the same second");
        vm.warp(start + 1 hours);
        vm.roll(block.number - 999_999);
        _dustBuy(trader);
        assertEq(_graduatedAt(), start + 1 hours, "an hour, whatever the block number says");
    }
}

contract GraduationCoinIsCurrency0Test is GraduationCases {
    function _launchCase(uint256 firstBuy) internal virtual override returns (PoolKey memory k) {
        (, k) = _launch(false, firstBuy);
    }

    function _launchAnother(uint256 firstBuy) internal virtual override returns (PoolKey memory) {
        return _launchNamed(false, firstBuy);
    }

    function _native() internal pure override returns (bool) {
        return false;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 100 ether;
    }

    function _launchNamed(bool quoteIsCurrency0, uint256 firstBuy) internal returns (PoolKey memory) {
        StokerFactory.LaunchParams memory p = _params(quoteIsCurrency0, firstBuy);
        p.name = "Another Coin";
        p.salt = _saltFor(quoteIsCurrency0, creator, p.name, p.symbol);
        vm.startPrank(creator);
        quote.approve(address(factory), firstBuy);
        (address c,) = factory.launch(p);
        vm.stopPrank();
        return _keyFor(c);
    }
}

contract GraduationQuoteIsCurrency0Test is GraduationCoinIsCurrency0Test {
    function _launchCase(uint256 firstBuy) internal override returns (PoolKey memory k) {
        (, k) = _launch(true, firstBuy);
    }

    function _launchAnother(uint256 firstBuy) internal override returns (PoolKey memory) {
        return _launchNamed(true, firstBuy);
    }
}

contract GraduationNativeTest is GraduationCases {
    function _launchCase(uint256 firstBuy) internal override returns (PoolKey memory k) {
        if (!registry.listingOf(address(0)).listed) _listNative();
        (, k) = _launchNative(firstBuy, address(0));
    }

    function _launchAnother(uint256 firstBuy) internal override returns (PoolKey memory) {
        return _launchCase(firstBuy);
    }

    function _native() internal pure override returns (bool) {
        return true;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 7 ether;
    }
}
