// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {FlashReset} from "../utils/FlashReset.sol";

/// The independent review of PR #269 (main session, 2026-11-24), adopted into the suite (#244). Its two flash
/// resets proved that, judged swap by swap, anyone with no coins could restart the hour; judged by the price
/// each transaction leaves, they now prove the reset does nothing. Every top-level call is a transaction.
/// forge-config: default.isolate = true
abstract contract HoldReviewCases is LocalBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant ALL_THE_COINS = 9.5e11 ether;

    PoolKey internal key;
    PoolId internal id;
    address internal coin;
    uint256 internal _n;

    function _native() internal pure virtual returns (bool);
    function _quoteIs0() internal pure virtual returns (bool);
    function _crossingBuy() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_800_000_000);
        vm.deal(trader, 1_000 ether);
        vm.deal(stranger, 1_000 ether);
        vm.deal(creator, 100 ether);
        if (_native()) _listNative();
        (coin, key) = _launchWith(0, 0, 0, 0);
        id = key.toId();
        _approveAll(trader);
        _approveAll(stranger);
        _approveAll(creator);
    }

    // ------------------------------------------------ fixture

    function _launchWith(uint256 firstBuy, uint16 bps, uint32 cliff, uint32 unlock)
        internal
        returns (address c, PoolKey memory k)
    {
        StokerFactory.LaunchParams memory p;
        if (_native()) {
            p = _nativeParams(firstBuy, address(0));
        } else {
            p = _params(_quoteIs0(), firstBuy);
            p.name = string.concat("Review ", vm.toString(++_n));
            p.salt = _saltFor(_quoteIs0(), creator, p.name, p.symbol);
        }
        p.creatorLockBps = bps;
        p.creatorLockCliff = cliff;
        p.creatorLockUnlock = unlock;
        vm.startPrank(creator);
        if (!_native() && firstBuy > 0) quote.approve(address(factory), firstBuy);
        (c,) = factory.launch{value: _native() ? firstBuy : 0}(p);
        vm.stopPrank();
        k = _native() ? _nativeKey(c) : _keyFor(c);
    }

    function _approveAll(address who) internal {
        vm.startPrank(who);
        IERC20(coin).approve(address(swapRouter), type(uint256).max);
        if (!_native()) quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _coinIs0() internal view returns (bool) {
        return !hook.termsOf(id).quoteIsCurrency0;
    }

    function _target() internal view returns (uint160) {
        return hook.termsOf(id).graduationSqrtPriceX96;
    }

    function _price() internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(id);
    }

    function _above() internal view returns (uint160) {
        uint160 t = _target();
        return _coinIs0() ? t + t / 100 : t - t / 100;
    }

    function _atOrAbove() internal view returns (bool) {
        return _coinIs0() ? _price() >= _target() : _price() <= _target();
    }

    /// The hold as the price stands now; `_recorded` is the hold as last judged.
    function _hold() internal view returns (uint256) {
        return hook.graduationNow(id).holdSince;
    }

    function _recorded() internal view returns (uint256) {
        return hook.graduationOf(id).holdSince;
    }

    function _graduatedAt() internal view returns (uint256) {
        return hook.graduationOf(id).graduatedAt;
    }

    function _quoteBal(address who) internal view returns (uint256) {
        return _native() ? who.balance : quote.balanceOf(who);
    }

    function _coinBal(address who) internal view returns (uint256) {
        return IERC20(coin).balanceOf(who);
    }

    function _noLimit(bool buy) internal view returns (uint160) {
        bool zeroForOne = buy == !_coinIs0();
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _swapTo(address who, bool buy, bool exactIn, uint256 amount, uint160 limit) internal {
        if (_native()) _swapNativeWithData(key, who, buy, exactIn, amount, who.balance, limit, "");
        else _swapWithData(key, who, buy, exactIn, amount, limit, "");
    }

    // ------------------------------------------------ 1. every swap type judges

    /// A pool's first swap in a transaction judges the price the last transaction left, whatever its type:
    /// exact-in buy and exact-out sell (the Quote Asset specified, fees in beforeSwap), exact-out buy and
    /// exact-in sell (the coin specified, `_beforeSwap`'s early return). Each type is shown changing the
    /// recorded hold, so moving `_judgeHold` below the early return, or into any one fee branch, fails here.
    function test_review_everySwapTypeJudgesThePriceLeftBefore() public {
        uint256 t0 = vm.getBlockTimestamp();
        _swapTo(trader, true, false, ALL_THE_COINS, _above()); // leaves the price above, at t0
        assertEq(_recorded(), 0);

        vm.warp(t0 + 10 minutes);
        _swapTo(trader, true, true, 1e12, _noLimit(true));
        assertEq(_recorded(), t0, "an exact-in buy judged the price left above");

        vm.warp(t0 + 20 minutes);
        _swapTo(trader, false, true, _coinBal(trader), _noLimit(false)); // leaves it under
        uint256 t3 = t0 + 30 minutes;
        vm.warp(t3);
        _swapTo(trader, true, false, ALL_THE_COINS, _above()); // leaves it above, at t3
        assertEq(_recorded(), 0, "an exact-out buy judged the price left under");

        vm.warp(t0 + 40 minutes);
        _swapTo(trader, false, true, 1 ether, _noLimit(false));
        assertEq(_recorded(), t3, "an exact-in sell judged the price left above");

        vm.warp(t0 + 50 minutes);
        // Nine tenths of the coins: under the target, and above the start, where an exact-out sell can be filled.
        _swapTo(trader, false, true, _coinBal(trader) * 9 / 10, _noLimit(false)); // leaves it under
        assertFalse(_atOrAbove(), "under the target");
        vm.warp(t0 + 60 minutes);
        _swapTo(trader, false, false, 1e9, _noLimit(false));
        assertEq(_recorded(), 0, "an exact-out sell judged the price left under");
    }

    // ------------------------------------------------ 2. a flash reset, with no coins, resets nothing

    /// The review's finding: inside one unlock a contract with no coins sold coins it did not own, taking the
    /// price under the target, and bought them back, restarting the hour for the round trip's fees. Judged by
    /// the price a transaction leaves, the reset changes nothing: the hold runs on, and the coin graduates on
    /// the hour, recorded by the griefer's own transaction.
    function test_review_aFlashResetWithNoCoinsNoLongerResetsTheHour() public {
        _swapTo(trader, true, false, ALL_THE_COINS, _above());
        uint256 start = vm.getBlockTimestamp();
        assertEq(_hold(), start);

        FlashReset griefer = new FlashReset(pm, hook);
        if (_native()) vm.deal(address(griefer), 1 ether);
        else mockQuote.mint(address(griefer), 1 ether);
        assertEq(_coinBal(address(griefer)), 0, "the griefer holds no coins");

        // The fewest coins that take the price just under the target, doubled for margin.
        uint128 liq = pm.getLiquidity(id);
        uint256 coins = _coinIs0()
            ? SqrtPriceMath.getAmount0Delta(_target(), _price(), liq, true)
            : SqrtPriceMath.getAmount1Delta(_price(), _target(), liq, true);
        coins *= 2;

        for (uint256 i = 1; i <= 5; i++) {
            uint256 at = start + i * 59 minutes;
            vm.warp(at);
            griefer.reset(key, coins);
            assertTrue(_coinIs0() ? griefer.priceMidway() < _target() : griefer.priceMidway() > _target());
            assertEq(_coinBal(address(griefer)), 0, "still no coins");
            assertEq(_hold(), start, "the hold runs on from its start");
            assertEq(_graduatedAt(), at >= start + 1 hours ? start + 1 hours : 0, "graduated on the hour");
        }
    }

    /// At exactly the target, a dust flash round trip does nothing either.
    function test_review_atTheTarget_aDustFlashResetDoesNothing() public {
        _swapTo(trader, true, false, ALL_THE_COINS, _target());
        uint256 start = vm.getBlockTimestamp();
        assertEq(_price(), _target());
        FlashReset griefer = new FlashReset(pm, hook);
        if (_native()) vm.deal(address(griefer), 1 ether);
        else mockQuote.mint(address(griefer), 1 ether);
        vm.warp(start + 59 minutes);
        griefer.reset(key, 1 ether); // one whole coin of 1e12
        assertEq(_hold(), start, "the hold runs on");
        vm.warp(start + 1 hours);
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(_graduatedAt(), start + 1 hours);
    }

    // ------------------------------------------------ 3. the Creator's own First Buy graduates the coin

    /// ADR 0024 accepts that "a Creator with capital can still fake it in an hour". Measured here: with a
    /// fifth locked, a First Buy across the target, an hour, and a sell of every coin, the Creator's net
    /// cost is about 1% of the First Buy (half of each fee returns as their own Credit), nobody holds coins
    /// to sell into the hold (a flash reset no longer breaks it, test 2), and seven days later a fifth of
    /// the supply is theirs.
    function test_review_creatorGraduatesTheirOwnCoinThroughTheFirstBuy_andTakesTheLock() public {
        uint256 q0 = _quoteBal(creator);
        uint256 launchedAt = vm.getBlockTimestamp();
        (address c, PoolKey memory k) = _launchWith(_crossingBuy(), 2_000, 7 days, 0);
        (key, id, coin) = (k, k.toId(), c);
        _approveAll(creator);
        assertEq(_hold(), launchedAt, "the First Buy started the hold");

        vm.warp(launchedAt + 1 hours);
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(_graduatedAt(), launchedAt + 1 hours);

        _swapTo(creator, false, true, _coinBal(creator), _noLimit(false));
        uint256 credit = _native() ? _nativeCredit(creator) : _credit(creator);
        uint256 loss = q0 - _quoteBal(creator) - credit;
        emit log_named_uint("first buy", _crossingBuy());
        emit log_named_uint("creator net loss incl. own credits", loss);
        assertLt(loss, _crossingBuy() * 105 / 10_000, "about 1% of the First Buy");

        vm.warp(launchedAt + 1 hours + 7 days);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        vm.prank(creator);
        lock.claim();
        assertEq(_coinBal(creator), SUPPLY / 5, "a fifth of the supply");
    }

    // ------------------------------------------------ 4. the empty region under the start price

    /// Under the start price the pool has no liquidity, so a dust sell moves the price to the edge of the
    /// range for free. It starts no hold, and buying back across the target from there costs what it costs
    /// from the open: the empty region gives no cheap way to or above the target.
    function test_review_theEmptyRegionUnderTheStartGivesNothing() public {
        uint256 snap = vm.snapshotState();
        uint256 c0 = _coinBal(trader);
        _swapTo(trader, true, true, _crossingBuy(), _noLimit(true));
        uint256 coinsFromOpen = _coinBal(trader) - c0;
        uint160 priceFromOpen = _price();
        vm.revertToState(snap);

        // A coin from elsewhere sold at the open: no liquidity under the start, so the price runs to the limit.
        uint160 open = _price();
        deal(coin, stranger, 1 ether);
        _swapTo(stranger, false, true, 1 ether, _noLimit(false));
        uint160 far = _price();
        assertTrue(_coinIs0() ? far < open / 1000 : far > open * 1000, "moved far into the empty region");
        assertEq(_hold(), 0);

        c0 = _coinBal(trader);
        _swapTo(trader, true, true, _crossingBuy(), _noLimit(true));
        assertApproxEqRel(_coinBal(trader) - c0, coinsFromOpen, 1e12, "same coins as from the open");
        assertApproxEqRel(_price(), priceFromOpen, 1e12, "same price as from the open");
    }

    // ------------------------------------------------ 5. the Graduation Target's rounding

    /// The target never stands for a lower coin price than start times multiple, and is the tightest such
    /// sqrt price: (pool price is currency1 per currency0)
    ///   coin0: t^2 >= o^2 m and (t-1)^2 < o^2 m
    ///   quote0: coin price is 1/p, so o^2 >= t^2 m and o^2 < (t+1)^2 m
    function test_review_theTargetIsTheTightestSafeRounding() public view {
        uint256 t = _target();
        uint256 m = hook.termsOf(id).graduationMultiple;
        uint256 o = TickMath.getSqrtPriceAtTick(_coinIs0() ? hook.termsOf(id).startTick : -hook.termsOf(id).startTick);
        if (_coinIs0()) {
            assertGe(FullMath.mulDiv(t, t, o), o * m, "t^2 >= o^2 m");
            assertLt(FullMath.mulDiv(t - 1, t - 1, o), o * m, "(t-1)^2 < o^2 m");
        } else {
            assertGe(FullMath.mulDiv(o, o, t), t * m, "o^2 >= t^2 m");
            // Not the tightest: the Q96 root rounded up and then the floor division leave t about 2e4 units
            // (about 6e-30 relative) low, so the target is a hair dearer than start times multiple. Safe.
            uint256 k = t / 1e27 + 1;
            assertLt(FullMath.mulDiv(o, o, t + k), (t + k) * m, "within 1e-27 of the tightest");
        }
    }

    // ------------------------------------------------ 6. the lock's schedule at its edges

    function _graduateNow() internal returns (uint256 g) {
        _swapTo(trader, true, false, ALL_THE_COINS, _above());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.graduate(id);
        g = _graduatedAt();
    }

    function test_review_lockScheduleAtItsEdges() public {
        uint32 cliff = 7 days;
        uint32 unlock = 30 days;
        (address c, PoolKey memory k) = _launchWith(0, 2_000, cliff, unlock);
        (key, id, coin) = (k, k.toId(), c);
        _approveAll(trader);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        uint256 amount = SUPPLY / 5;
        assertEq(lock.amount(), amount);
        assertEq(_coinBal(address(lock)), amount);

        uint256 g = _graduateNow();
        uint256 c0 = _coinBal(creator);

        vm.warp(g + cliff - 1);
        vm.prank(creator);
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        lock.claim();

        vm.warp(g + cliff);
        vm.prank(creator);
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        lock.claim();

        vm.warp(g + cliff + 1);
        vm.prank(creator);
        assertEq(lock.claim(), amount / unlock, "one second's worth");

        vm.warp(g + cliff + unlock - 1);
        vm.prank(creator);
        lock.claim();
        assertEq(_coinBal(creator) - c0, amount * (unlock - 1) / unlock, "all but the last second");

        vm.warp(g + cliff + unlock);
        vm.prank(creator);
        lock.claim();
        assertEq(_coinBal(creator) - c0, amount, "exactly the lock");
        assertEq(_coinBal(address(lock)), 0);

        vm.warp(g + 10 * 365 days);
        vm.prank(creator);
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        lock.claim();
    }

    /// With no unlock time everything is released at exactly the cliff's end (kills `<` -> `<=`).
    function test_review_lockAllAtOnce_atExactlyTheCliffsEnd() public {
        (address c, PoolKey memory k) = _launchWith(0, 2_000, 7 days, 0);
        (key, id, coin) = (k, k.toId(), c);
        _approveAll(trader);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        uint256 g = _graduateNow();
        vm.warp(g + 7 days);
        vm.prank(creator);
        assertEq(lock.claim(), SUPPLY / 5);
    }

    /// Coins anyone sends the lock never raise what the Creator can claim, and nobody else gets them.
    function test_review_lockDonationNeverClaimable() public {
        (address c, PoolKey memory k) = _launchWith(0, 2_000, 7 days, 0);
        (key, id, coin) = (k, k.toId(), c);
        _approveAll(trader);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        uint256 g = _graduateNow();
        uint256 extra = _coinBal(trader);
        vm.prank(trader);
        IERC20(coin).transfer(address(lock), extra);
        vm.warp(g + 7 days);
        vm.prank(creator);
        assertEq(lock.claim(), SUPPLY / 5, "the lock, not the balance");
        vm.prank(creator);
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        lock.claim();
        assertEq(_coinBal(address(lock)), extra, "stuck for good");
    }
}

contract HoldReviewCoinIsCurrency0Test is HoldReviewCases {
    function _native() internal pure override returns (bool) {
        return false;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return false;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 100 ether;
    }
}

contract HoldReviewQuoteIsCurrency0Test is HoldReviewCases {
    function _native() internal pure override returns (bool) {
        return false;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 100 ether;
    }
}

contract HoldReviewNativeTest is HoldReviewCases {
    function _native() internal pure override returns (bool) {
        return true;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 7 ether;
    }
}
