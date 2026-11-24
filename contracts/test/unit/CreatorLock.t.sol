// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The Creator Lock on an EVM chain (#244, ADR 0024; Solana's is ADR 0023): up to a fifth of the supply held
/// out of the Seed Position in a contract of its own, terms fixed at launch, nothing released before
/// Graduation, the clock starting at Graduation and running at least seven days, and only the Creator's own
/// address claiming what the schedule has released. In every pairing; every top-level call is a transaction.
/// forge-config: default.isolate = true
abstract contract CreatorLockCases is LocalBase {
    uint16 internal constant A_FIFTH = 2_000;
    uint32 internal constant WEEK = 7 days;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_800_000_000);
        vm.deal(creator, 100 ether);
        vm.deal(trader, 1_000 ether);
    }

    // ------------------------------------------------ what each pairing fills in

    function _paramsCase(uint256 firstBuy, uint256 n) internal virtual returns (StokerFactory.LaunchParams memory);
    function _native() internal pure virtual returns (bool);
    function _crossingBuy() internal pure virtual returns (uint256);

    // ------------------------------------------------ launching with a lock

    uint256 internal _n;

    function _lockParams(uint16 bps, uint32 cliff, uint32 unlock, uint256 firstBuy)
        internal
        returns (StokerFactory.LaunchParams memory p)
    {
        p = _paramsCase(firstBuy, ++_n);
        p.creatorLockBps = bps;
        p.creatorLockCliff = cliff;
        p.creatorLockUnlock = unlock;
    }

    function _send(StokerFactory.LaunchParams memory p) internal returns (address coin, PoolId id) {
        vm.startPrank(creator);
        if (!_native() && p.firstBuy > 0) quote.approve(address(factory), p.firstBuy);
        (coin, id) = factory.launch{value: _native() ? p.firstBuy : 0}(p);
        vm.stopPrank();
        // Past the Opening Fee (#246), so the buys below trade as they would after a coin's first seconds.
        _pastOpening();
    }

    function _launchLocked(uint16 bps, uint32 cliff, uint32 unlock)
        internal
        returns (address coin, PoolId id, StokerCreatorLock lock)
    {
        (coin, id) = _send(_lockParams(bps, cliff, unlock, 0));
        lock = StokerCreatorLock(factory.creatorLockOf(id));
    }

    function _keyOf(address coin) internal view returns (PoolKey memory) {
        return _native() ? _nativeKey(coin) : _keyFor(coin);
    }

    /// Buys across the target with the trader, waits the hour and records Graduation; returns its time.
    function _graduate(address coin, PoolId id) internal returns (uint256 graduatedAt) {
        PoolKey memory key = _keyOf(coin);
        if (_native()) {
            _swapNative(key, trader, true, true, _crossingBuy(), 0);
        } else {
            _swap(key, trader, true, true, _crossingBuy());
        }
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.graduate(id);
        graduatedAt = hook.graduationOf(id).graduatedAt;
        assertGt(graduatedAt, 0, "graduated");
    }

    function _expectInvalid(uint16 bps, uint32 cliff, uint32 unlock) internal {
        StokerFactory.LaunchParams memory p = _lockParams(bps, cliff, unlock, 0);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.InvalidCreatorLock.selector, bps, cliff, unlock));
        vm.prank(creator);
        factory.launch(p);
    }

    // ------------------------------------------------ the launch

    function test_lock_aFifthSeedsFourFifths() public {
        StokerFactory.LaunchParams memory p = _lockParams(A_FIFTH, WEEK, 0, 0);
        vm.expectEmit(false, false, true, true, address(factory));
        emit StokerFactory.CreatorLocked(PoolId.wrap(0), address(0), creator, SUPPLY / 5, WEEK, 0);
        (address coin, PoolId id) = _send(p);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        IERC20 c = IERC20(coin);

        assertEq(c.balanceOf(address(lock)), SUPPLY / 5, "a fifth held by the lock");
        assertEq(c.balanceOf(address(pm)) + c.balanceOf(address(lock)), c.totalSupply(), "every coin accounted");
        assertLe(c.balanceOf(address(pm)), SUPPLY * 4 / 5, "four fifths seeded");
        assertLe(SUPPLY - c.totalSupply(), 1e12, "only the seed's rounding dust burned");
        assertEq(c.balanceOf(address(factory)), 0, "the factory keeps none");

        // The terms are the launch's, fixed in the lock.
        assertEq(lock.creator(), creator);
        assertEq(address(lock.coin()), coin);
        assertEq(PoolId.unwrap(lock.poolId()), PoolId.unwrap(id));
        assertEq(address(lock.hook()), address(hook));
        assertEq(lock.amount(), SUPPLY / 5);
        assertEq(lock.cliff(), WEEK);
        assertEq(lock.unlock(), 0);

        // The same launch with no lock seeds five fifths: the seed is four fifths of its liquidity.
        (address plain,) = _send(_lockParams(0, 0, 0, 0));
        assertEq(factory.creatorLockOf(_keyOf(plain).toId()), address(0), "no lock, no contract");
        assertApproxEqRel(
            uint256(_seedLiquidity(_keyOf(coin))) * 5, uint256(_seedLiquidity(_keyOf(plain))) * 4, 1e9, "liquidity"
        );
    }

    function test_lock_withAFirstBuy_theCreatorGetsBoth() public {
        uint256 firstBuy = _native() ? 0.1 ether : 1 ether;
        (address coin, PoolId id) = _send(_lockParams(1_000, 0, 30 days, firstBuy));
        IERC20 c = IERC20(coin);
        assertGt(c.balanceOf(creator), 0, "the First Buy's coins");
        assertEq(c.balanceOf(factory.creatorLockOf(id)), SUPPLY / 10, "a tenth locked apart from them");
        assertEq(c.balanceOf(address(pm)) + c.balanceOf(creator) + SUPPLY / 10, c.totalSupply());
    }

    function test_lock_aboveAFifth_reverts() public {
        _expectInvalid(A_FIFTH + 1, WEEK, 0);
    }

    function test_lock_shorterThanSevenDays_reverts() public {
        _expectInvalid(A_FIFTH, WEEK - 1, 0);
        _expectInvalid(A_FIFTH, 0, WEEK - 1);
        _expectInvalid(A_FIFTH, 3 days, 4 days - 1);
        _expectInvalid(500, 0, 0);
    }

    function test_lock_sevenDaysExactly_launches() public {
        (,, StokerCreatorLock a) = _launchLocked(A_FIFTH, WEEK, 0);
        (,, StokerCreatorLock b) = _launchLocked(A_FIFTH, 0, WEEK);
        (,, StokerCreatorLock c) = _launchLocked(1, 3 days, 4 days);
        assertTrue(address(a) != address(0) && address(b) != address(0) && address(c) != address(0));
    }

    function test_lock_aPartOverFourYears_reverts() public {
        uint32 fourYears = 4 * 365 days;
        _expectInvalid(A_FIFTH, fourYears + 1, 0);
        _expectInvalid(A_FIFTH, WEEK, fourYears + 1);
        (,, StokerCreatorLock lock) = _launchLocked(A_FIFTH, fourYears, fourYears);
        assertEq(lock.cliff() + lock.unlock(), 2 * uint256(fourYears));
    }

    function test_noLock_withACliffOrAnUnlockTime_reverts() public {
        _expectInvalid(0, WEEK, 0);
        _expectInvalid(0, 0, WEEK);
    }

    // ------------------------------------------------ nothing before Graduation

    function test_claim_beforeGraduation_reverts_evenAsTheHoldRuns() public {
        (address coin, PoolId id, StokerCreatorLock lock) = _launchLocked(A_FIFTH, 0, WEEK);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert(StokerCreatorLock.NotGraduated.selector);
        vm.prank(creator);
        lock.claim();

        PoolKey memory key = _keyOf(coin);
        if (_native()) _swapNative(key, trader, true, true, _crossingBuy(), 0);
        else _swap(key, trader, true, true, _crossingBuy());
        assertGt(hook.graduationNow(id).holdSince, 0, "the hold runs");
        vm.warp(vm.getBlockTimestamp() + 59 minutes);
        assertEq(lock.released(), 0);
        vm.expectRevert(StokerCreatorLock.NotGraduated.selector);
        vm.prank(creator);
        lock.claim();

        // The hour has passed but nobody has recorded it: Graduation is what the hook has recorded.
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        vm.expectRevert(StokerCreatorLock.NotGraduated.selector);
        vm.prank(creator);
        lock.claim();
    }

    // ------------------------------------------------ the schedule

    /// "All at once": a cliff of the whole time.
    function test_claim_allAtOnce_afterTheCliff() public {
        (address coin, PoolId id, StokerCreatorLock lock) = _launchLocked(A_FIFTH, WEEK, 0);
        uint256 g = _graduate(coin, id);

        vm.warp(g + WEEK - 1);
        assertEq(lock.claimable(), 0);
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        vm.prank(creator);
        lock.claim();

        vm.warp(g + WEEK);
        vm.expectEmit(true, false, false, true, address(lock));
        emit StokerCreatorLock.Claimed(creator, SUPPLY / 5);
        vm.prank(creator);
        assertEq(lock.claim(), SUPPLY / 5);
        assertEq(IERC20(coin).balanceOf(creator), SUPPLY / 5, "the whole lock, to the Creator");
        assertEq(IERC20(coin).balanceOf(address(lock)), 0);

        vm.warp(g + 365 days);
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        vm.prank(creator);
        lock.claim();
    }

    /// "Gradually after 7 days": a cliff, then a straight line to the end, rounded down.
    function test_claim_gradually_afterTheCliff_exactlyWhatTheScheduleReleased() public {
        uint32 unlock = 23 days;
        (address coin, PoolId id, StokerCreatorLock lock) = _launchLocked(A_FIFTH, WEEK, unlock);
        uint256 g = _graduate(coin, id);
        uint256 amount = SUPPLY / 5;
        IERC20 c = IERC20(coin);

        vm.warp(g + WEEK);
        assertEq(lock.released(), 0, "nothing at the cliff's end");
        vm.expectRevert(StokerCreatorLock.NothingToClaim.selector);
        vm.prank(creator);
        lock.claim();

        vm.warp(g + WEEK + 5 days);
        uint256 first = amount * 5 days / unlock;
        vm.prank(creator);
        assertEq(lock.claim(), first);
        assertEq(c.balanceOf(creator), first);

        vm.warp(g + WEEK + 17 days + 3);
        uint256 second = amount * (17 days + 3) / unlock - first;
        assertEq(lock.claimable(), second);
        vm.prank(creator);
        lock.claim();
        assertEq(c.balanceOf(creator), first + second);

        vm.warp(g + WEEK + unlock);
        vm.prank(creator);
        lock.claim();
        assertEq(c.balanceOf(creator), amount, "all of it at the end, and no more");
        assertEq(lock.claimed(), amount);
        assertEq(c.balanceOf(address(lock)), 0);
    }

    /// The clock starts at Graduation, an hour after the hold began, however late someone records it.
    function test_claim_aLateRecordedGraduation_startsTheClockAtTheHoursEnd() public {
        (address coin, PoolId id, StokerCreatorLock lock) = _launchLocked(A_FIFTH, WEEK, 0);
        PoolKey memory key = _keyOf(coin);
        if (_native()) _swapNative(key, trader, true, true, _crossingBuy(), 0);
        else _swap(key, trader, true, true, _crossingBuy());
        uint256 holdSince = hook.graduationNow(id).holdSince;

        vm.warp(holdSince + 1 hours + WEEK);
        vm.prank(stranger);
        hook.graduate(id);
        vm.prank(creator);
        assertEq(lock.claim(), SUPPLY / 5, "a week after Graduation, recorded a week late");
    }

    function testFuzz_claim_paysExactlyTheSchedule(uint32 cliff, uint32 unlock, uint32 at1, uint32 at2) public {
        cliff = uint32(bound(cliff, 0, 60 days));
        unlock = uint32(bound(unlock, cliff >= WEEK ? 0 : WEEK - cliff, 60 days));
        (address coin, PoolId id, StokerCreatorLock lock) = _launchLocked(A_FIFTH, cliff, unlock);
        uint256 g = _graduate(coin, id);
        uint256 amount = SUPPLY / 5;
        uint256 t1 = g + bound(at1, 0, 130 days);
        uint256 t2 = t1 + bound(at2, 0, 130 days);

        vm.warp(t1);
        assertEq(lock.released(), _released(amount, g, cliff, unlock, t1), "released at t1");
        uint256 paid = _claimIfAny(lock);
        vm.warp(t2);
        assertEq(lock.released(), _released(amount, g, cliff, unlock, t2), "released at t2");
        paid += _claimIfAny(lock);
        assertEq(paid, _released(amount, g, cliff, unlock, t2), "paid what was released, no more");
        assertEq(IERC20(coin).balanceOf(creator), paid);
        assertEq(IERC20(coin).balanceOf(address(lock)), amount - paid);
    }

    function _released(uint256 amount, uint256 g, uint256 cliff, uint256 unlock, uint256 t)
        internal
        pure
        returns (uint256)
    {
        if (t < g + cliff) return 0;
        if (unlock == 0 || t >= g + cliff + unlock) return amount;
        return amount * (t - g - cliff) / unlock;
    }

    function _claimIfAny(StokerCreatorLock lock) internal returns (uint256) {
        if (lock.claimable() == 0) return 0;
        vm.prank(creator);
        return lock.claim();
    }

    // ------------------------------------------------ only the Creator

    function test_claim_byAnyoneButTheCreator_reverts() public {
        StokerFactory.LaunchParams memory p = _lockParams(A_FIFTH, WEEK, 0, 0);
        address destination = makeAddr("destination");
        p.creatorDestination = destination;
        (address coin, PoolId id) = _send(p);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        uint256 g = _graduate(coin, id);
        vm.warp(g + WEEK);

        // The Admin, the Creator's Destination, a stranger and our own contracts: no key of ours, nor anyone
        // else, reaches the locked coins.
        address[6] memory others = [platform, destination, stranger, address(factory), address(hook), trader];
        for (uint256 i; i < others.length; i++) {
            vm.expectRevert(StokerCreatorLock.NotCreator.selector);
            vm.prank(others[i]);
            lock.claim();
        }
        assertEq(IERC20(coin).balanceOf(address(lock)), SUPPLY / 5, "untouched");

        vm.prank(creator);
        lock.claim();
        assertEq(IERC20(coin).balanceOf(creator), SUPPLY / 5, "to the Creator's own address, not the Destination");
        assertEq(IERC20(coin).balanceOf(destination), 0);
    }

    /// Each lock reads its own coin's Graduation.
    function test_claim_readsItsOwnCoinsGraduation() public {
        (address coinA, PoolId idA, StokerCreatorLock lockA) = _launchLocked(A_FIFTH, WEEK, 0);
        (,, StokerCreatorLock lockB) = _launchLocked(A_FIFTH, WEEK, 0);
        uint256 g = _graduate(coinA, idA);
        vm.warp(g + WEEK);
        vm.prank(creator);
        lockA.claim();
        vm.expectRevert(StokerCreatorLock.NotGraduated.selector);
        vm.prank(creator);
        lockB.claim();
    }
}

contract CreatorLockCoinIsCurrency0Test is CreatorLockCases {
    function _quoteIs0() internal pure virtual returns (bool) {
        return false;
    }

    function _paramsCase(uint256 firstBuy, uint256 n)
        internal
        view
        override
        returns (StokerFactory.LaunchParams memory p)
    {
        p = _params(_quoteIs0(), firstBuy);
        p.name = string.concat("Locked ", vm.toString(n));
        p.salt = _saltFor(_quoteIs0(), creator, p.name, p.symbol);
    }

    function _native() internal pure override returns (bool) {
        return false;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 100 ether;
    }
}

contract CreatorLockQuoteIsCurrency0Test is CreatorLockCoinIsCurrency0Test {
    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }
}

contract CreatorLockNativeTest is CreatorLockCases {
    function setUp() public override {
        super.setUp();
        _listNative();
    }

    function _paramsCase(uint256 firstBuy, uint256) internal override returns (StokerFactory.LaunchParams memory) {
        return _nativeParams(firstBuy, address(0));
    }

    function _native() internal pure override returns (bool) {
        return true;
    }

    function _crossingBuy() internal pure override returns (uint256) {
        return 7 ether;
    }
}
