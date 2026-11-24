// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {HoldAttacker} from "../utils/HoldAttacker.sol";
import {FlashReset} from "../utils/FlashReset.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";

/// Drives a locked Launch through random buys and sells (to the target's edge, a wei either side, as well as
/// by amounts), round trips across the target inside one unlock, warps of the clock, public calls to
/// graduate, and claims of the Creator Lock by the Creator and by others. It keeps its own model of the
/// Graduation Hold, built only from the prices it sees and its own clock (#244): each handler call is one
/// transaction, and a transaction's first swap judges the price the transaction before it left. Since the
/// review of #269 it also resets as that review's griefer did: a sell of coins it does not own and the buy
/// back, inside one unlock.
contract GraduationHandler is Test {
    GraduationInvariantBase internal immutable t;
    address[3] internal actors;
    HoldAttacker internal attacker;
    FlashReset internal griefer;

    // The model of the hold, from outside: the record as the hook should hold it.
    uint256 public modelHold;
    uint256 public modelGraduatedAt;
    uint256 public modelLastSwapAt;

    // Ghosts.
    uint256 public swaps;
    uint256 public holdsStarted;
    uint256 public graduationChanges; // a recorded Graduation whose time later differed
    uint256 public firstGraduatedAt;
    uint256 public claimedByCreator; // coins the Creator's claims delivered
    uint256 public claimMismatches; // a claim that paid other than what the schedule had released and not paid
    uint256 public othersClaims;
    uint256 public publicCallMismatches; // a public call to graduate whose outcome differed from the model's
    uint256 public lockLeaks; // the lock's balance fell other than by the Creator's claim

    constructor(GraduationInvariantBase t_) {
        t = t_;
        actors = [makeAddr("g0"), makeAddr("g1"), makeAddr("g2")];
        attacker = new HoldAttacker(IPoolManager(t.poolManager()), t.theHook());
        t.fund(address(attacker));
        griefer = new FlashReset(IPoolManager(t.poolManager()), t.theHook());
        t.fund(address(griefer));
    }

    // ------------------------------------------------ the model

    /// The record judged against a price that has stood since the model's last swap.
    function _judged(bool atOrAbove) internal view returns (uint256 hold, uint256 graduatedAt) {
        (hold, graduatedAt) = (modelHold, modelGraduatedAt);
        if (graduatedAt != 0) return (hold, graduatedAt);
        if (!atOrAbove) return (0, 0);
        if (hold == 0) hold = modelLastSwapAt;
        if (hold != 0 && vm.getBlockTimestamp() >= hold + 1 hours) graduatedAt = hold + 1 hours;
    }

    /// A transaction that swapped the pool went through: its first swap judged the price standing before it,
    /// read before the call as `aboveBefore`, and the price it left stands from now.
    function _transactionSwapped(bool aboveBefore) internal {
        uint256 before = modelHold;
        (modelHold, modelGraduatedAt) = _judged(aboveBefore);
        if (before == 0 && modelHold != 0) holdsStarted++;
        modelLastSwapAt = vm.getBlockTimestamp();
        swaps++;
    }

    /// Every action ends here: the Graduation once seen never changes, and the lock's coins leave only by
    /// the Creator's claim.
    function _check(uint256 lockBefore, bool byCreator) internal {
        uint256 g = t.graduatedAt();
        if (firstGraduatedAt == 0) firstGraduatedAt = g;
        else if (g != firstGraduatedAt) graduationChanges++;
        uint256 lockAfter = t.lockBalance();
        if (!byCreator && lockAfter != lockBefore) lockLeaks++;
    }

    // ------------------------------------------------ trading

    function buy(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        uint256 lb = t.lockBalance();
        t.fund(who);
        amount = bound(amount, t.quoteUnit() / 1_000, 2 * t.crossingBuy());
        bool aboveBefore = t.atOrAbove();
        try t.swapAs(who, true, true, amount, 0) {
            _transactionSwapped(aboveBefore);
        } catch {}
        _check(lb, false);
    }

    function sell(uint256 actorSeed, uint256 share) external {
        address who = actors[actorSeed % actors.length];
        uint256 lb = t.lockBalance();
        uint256 coins = t.coinBalance(who) * bound(share, 1, 100) / 100;
        if (coins == 0) return;
        bool aboveBefore = t.atOrAbove();
        try t.swapAs(who, false, true, coins, 0) {
            _transactionSwapped(aboveBefore);
        } catch {}
        _check(lb, false);
    }

    /// A buy or a sell to a limit at the target's edge: `edge` sqrt-price units from it, on either side, the
    /// coin as the specified side so the limit stops it lawfully. A limit behind the price is refused.
    function toTheEdge(uint256 actorSeed, bool buy_, uint256 edge, bool dearSide) external {
        address who = actors[actorSeed % actors.length];
        uint256 lb = t.lockBalance();
        t.fund(who);
        uint160 limit = t.edge(bound(edge, 0, 3), dearSide);
        uint256 amount = buy_ ? 9.5e11 ether : t.coinBalance(who);
        if (amount == 0) return;
        bool aboveBefore = t.atOrAbove();
        try t.swapAs(who, buy_, !buy_, amount, limit) {
            _transactionSwapped(aboveBefore);
        } catch {}
        _check(lb, false);
    }

    /// Across the target and straight back inside one unlock, as a flash loan would.
    function roundTrip(uint256 amount) external {
        uint256 lb = t.lockBalance();
        t.fund(address(attacker));
        amount = bound(amount, t.crossingBuy() / 2, 2 * t.crossingBuy());
        bool aboveBefore = t.atOrAbove();
        try attacker.roundTrip(t.theKey(), amount) {
            // Two swaps in one transaction: only the first judges, and the price between them counts for
            // nothing.
            _transactionSwapped(aboveBefore);
        } catch {}
        _check(lb, false);
    }

    /// The review of #269's reset: a sell of coins nobody holds, under the target, and the buy back, inside one
    /// unlock. Judged by the price the transaction leaves, it is a transaction like any other.
    function flashReset(uint256 coins) external {
        uint256 lb = t.lockBalance();
        t.fund(address(griefer));
        coins = bound(coins, 1 ether, 2e10 ether);
        bool aboveBefore = t.atOrAbove();
        try griefer.reset(t.theKey(), coins) {
            _transactionSwapped(aboveBefore);
        } catch {}
        _check(lb, false);
    }

    // ------------------------------------------------ the clock and the public call

    function warp(uint256 secs) external {
        uint256 lb = t.lockBalance();
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 2 hours));
        _check(lb, false);
    }

    function longWarp(uint256 secs) external {
        uint256 lb = t.lockBalance();
        vm.warp(vm.getBlockTimestamp() + bound(secs, 0, 4 days));
        _check(lb, false);
    }

    function graduate(uint256 actorSeed) external {
        uint256 lb = t.lockBalance();
        (uint256 hold, uint256 graduatedAt) = _judged(t.atOrAbove());
        bool shouldRecord = modelGraduatedAt == 0 && graduatedAt != 0;
        vm.prank(actors[actorSeed % actors.length]);
        try t.theHook().graduate(t.theId()) {
            if (shouldRecord) (modelHold, modelGraduatedAt) = (hold, graduatedAt);
            else publicCallMismatches++; // a public call the model says should have failed went through
        } catch {
            if (shouldRecord) publicCallMismatches++; // and one it says should have gone through failed
        }
        _check(lb, false);
    }

    // ------------------------------------------------ the Creator Lock

    function creatorClaim() external {
        uint256 lb = t.lockBalance();
        StokerCreatorLock lock = t.theLock();
        address creator = lock.creator();
        uint256 owedBySchedule = t.scheduled(modelGraduatedAt) - claimedByCreator;
        uint256 c0 = t.coinBalance(creator);
        vm.prank(creator);
        try lock.claim() returns (uint256 paid) {
            uint256 got = t.coinBalance(creator) - c0;
            claimedByCreator += got;
            if (paid != owedBySchedule || got != paid || lb - t.lockBalance() != paid) claimMismatches++;
        } catch {
            if (owedBySchedule != 0) claimMismatches++;
        }
        _check(lb, true);
    }

    function othersClaim(uint256 actorSeed) external {
        uint256 lb = t.lockBalance();
        address[5] memory others = [actors[0], actors[1], t.adminAddr(), t.factoryAddr(), address(attacker)];
        vm.prank(others[actorSeed % others.length]);
        try t.theLock().claim() {
            othersClaims++;
        } catch {}
        _check(lb, false);
    }
}

/// Invariants of Graduation and the Creator Lock (#244, ADR 0024): Graduation is what the model of the hold
/// says (so never inside the hour, and never by a round trip), once recorded it never changes, and the lock's
/// coins leave only to the Creator and only by the schedule.
abstract contract GraduationInvariantBase is LocalBase {
    using StateLibrary for IPoolManager;

    uint16 internal constant LOCK_BPS = 2_000;
    uint32 internal constant LOCK_CLIFF = 1 days;
    uint32 internal constant LOCK_UNLOCK = 6 days;

    PoolKey internal key;
    PoolId internal id;
    address internal coin;
    StokerCreatorLock internal lock;
    GraduationHandler internal handler;

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        StokerFactory.LaunchParams memory p = _paramsCase();
        p.creatorLockBps = LOCK_BPS;
        p.creatorLockCliff = LOCK_CLIFF;
        p.creatorLockUnlock = LOCK_UNLOCK;
        vm.prank(creator);
        PoolId pid;
        (coin, pid) = factory.launch(p);
        key = native() ? _nativeKey(coin) : _keyFor(coin);
        id = key.toId();
        lock = StokerCreatorLock(factory.creatorLockOf(id));
        handler = new GraduationHandler(this);
        targetContract(address(handler));
    }

    // ------------------------------------------------ what each pairing fills in

    function _paramsCase() internal virtual returns (StokerFactory.LaunchParams memory);
    function native() public pure virtual returns (bool);
    function quoteUnit() public pure virtual returns (uint256);
    function crossingBuy() public pure virtual returns (uint256);
    function fund(address who) external virtual;

    // ------------------------------------------------ the invariants

    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap went through");
    }

    /// The hook's record is exactly the model's: a hold runs from the transaction that left the price at or
    /// above the target, ends with one that left it under, and an unbroken hour graduates the coin at the
    /// hour's end. So Graduation is never recorded inside the hour, nor by a round trip, and a flash reset
    /// changes nothing.
    function invariant_graduationIsTheHoldsHour() public view {
        StokerHook.Graduation memory g = hook.graduationOf(id);
        assertEq(g.graduatedAt, handler.modelGraduatedAt(), "Graduation, against the model");
        assertEq(g.holdSince, handler.modelHold(), "the hold, against the model");
        assertEq(g.lastSwapAt, handler.modelLastSwapAt(), "the last transaction to swap the pool");
        assertEq(handler.publicCallMismatches(), 0, "a public call that should have failed went through, or not");
        if (g.graduatedAt != 0) {
            assertEq(g.graduatedAt, uint256(g.holdSince) + 1 hours, "an hour after the hold began");
            assertLe(g.graduatedAt, vm.getBlockTimestamp(), "never ahead of the clock");
        }
    }

    function invariant_graduationIsNeverUndone() public view {
        assertEq(handler.graduationChanges(), 0, "a recorded Graduation changed");
        if (handler.firstGraduatedAt() != 0) assertEq(graduatedAt(), handler.firstGraduatedAt());
    }

    /// The lock's coins leave only to the Creator, only by the Creator's claim, and only as the schedule
    /// releases them from Graduation.
    function invariant_theLocksCoinsLeaveOnlyToTheCreatorByTheSchedule() public view {
        assertEq(handler.othersClaims(), 0, "someone else claimed");
        assertEq(handler.lockLeaks(), 0, "the lock's balance fell without the Creator's claim");
        assertEq(handler.claimMismatches(), 0, "a claim paid other than the schedule");
        assertEq(lock.claimed(), handler.claimedByCreator(), "claimed, as delivered to the Creator");
        assertEq(lockBalance() + handler.claimedByCreator(), lock.amount(), "every locked coin accounted");
        assertLe(handler.claimedByCreator(), scheduled(handler.modelGraduatedAt()), "never ahead of the schedule");
        if (handler.modelGraduatedAt() == 0) assertEq(handler.claimedByCreator(), 0, "nothing before Graduation");
    }

    // ------------------------------------------------ the handler's window onto the fixture

    function poolManager() external view returns (address) {
        return address(pm);
    }

    function theHook() external view returns (StokerHook) {
        return hook;
    }

    function theKey() external view returns (PoolKey memory) {
        return key;
    }

    function theId() external view returns (PoolId) {
        return id;
    }

    function theLock() external view returns (StokerCreatorLock) {
        return lock;
    }

    function adminAddr() external view returns (address) {
        return keys.admin();
    }

    function factoryAddr() external view returns (address) {
        return address(factory);
    }

    function graduatedAt() public view returns (uint256) {
        return hook.graduationOf(id).graduatedAt;
    }

    function lockBalance() public view returns (uint256) {
        return IERC20(coin).balanceOf(address(lock));
    }

    function coinBalance(address who) public view returns (uint256) {
        return IERC20(coin).balanceOf(who);
    }

    /// What the schedule has released by now from a Graduation at `g`, worked out here, not read.
    function scheduled(uint256 g) public view returns (uint256) {
        if (g == 0) return 0;
        uint256 now_ = vm.getBlockTimestamp();
        uint256 start = g + LOCK_CLIFF;
        uint256 amount = lock.amount();
        if (now_ < start) return 0;
        if (now_ >= start + LOCK_UNLOCK) return amount;
        return amount * (now_ - start) / LOCK_UNLOCK;
    }

    function _coinIs0() internal view returns (bool) {
        return Currency.unwrap(key.currency0) == coin;
    }

    function atOrAbovePrice(uint160 p) public view returns (bool) {
        uint160 target = hook.termsOf(id).graduationSqrtPriceX96;
        return _coinIs0() ? p >= target : p <= target;
    }

    function atOrAbove() public view returns (bool) {
        (uint160 p,,,) = pm.getSlot0(id);
        return atOrAbovePrice(p);
    }

    /// The target moved `by` units of sqrt price toward the coin's dear side, or its cheap side.
    function edge(uint256 by, bool dearSide) external view returns (uint160) {
        uint160 target = hook.termsOf(id).graduationSqrtPriceX96;
        uint160 b = uint160(by);
        return (_coinIs0() == dearSide) ? target + b : target - b;
    }

    /// A swap from `who`, the coin approved; `limit` zero for none.
    function swapAs(address who, bool buy, bool exactIn, uint256 amount, uint160 limit) external {
        bool zeroForOne = native() ? buy : buy == _isQuote0(key);
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.startPrank(who);
        IERC20(coin).approve(address(swapRouter), type(uint256).max);
        if (!native()) quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
        if (native()) _swapNativeWithData(key, who, buy, exactIn, amount, who.balance, limit, "");
        else _swapWithData(key, who, buy, exactIn, amount, limit, "");
    }
}

contract GraduationCoinIsCurrency0InvariantTest is GraduationInvariantBase {
    function _quoteIs0() internal pure virtual returns (bool) {
        return false;
    }

    function _paramsCase() internal view override returns (StokerFactory.LaunchParams memory) {
        return _params(_quoteIs0(), 0);
    }

    function native() public pure override returns (bool) {
        return false;
    }

    function quoteUnit() public pure override returns (uint256) {
        return 1 ether;
    }

    function crossingBuy() public pure override returns (uint256) {
        return 80 ether;
    }

    function fund(address who) external override {
        if (quote.balanceOf(who) < 1_000 ether) mockQuote.mint(who, 10_000 ether);
    }
}

contract GraduationQuoteIsCurrency0InvariantTest is GraduationCoinIsCurrency0InvariantTest {
    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }
}

contract GraduationNativeInvariantTest is GraduationInvariantBase {
    function _paramsCase() internal override returns (StokerFactory.LaunchParams memory) {
        _listNative();
        return _nativeParams(0, address(0));
    }

    function native() public pure override returns (bool) {
        return true;
    }

    function quoteUnit() public pure override returns (uint256) {
        return 0.1 ether;
    }

    function crossingBuy() public pure override returns (uint256) {
        return 5 ether;
    }

    function fund(address who) external override {
        if (who.balance < 1_000 ether) vm.deal(who, 10_000 ether);
    }
}
