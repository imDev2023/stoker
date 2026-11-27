// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";

/// The Destinations beside Graduation and the Creator Lock (#248 with #244): on a coin that has graduated
/// and whose Creator holds a fifth of the supply in a Creator Lock, each Destination's earnings do what they
/// do on any coin, and touch neither the lock nor the record of Graduation. The burn burns what it buys and
/// not a coin of the lock's; the liquidity adds Support Liquidity with no coin bought; the holders are paid
/// by a Round Root of the earnings' own; the ladder key then raises the graduated coin, and the next swap
/// credits its Destination the second tier's share; and the Creator claims the whole lock after its cliff.
/// The hold judges the price each transaction leaves, so every top-level call here is a transaction of its own.
/// forge-config: default.isolate = true
contract DestinationsGraduatedTest is DestinationsLocalBase {
    uint16 internal constant A_FIFTH = 2_000;
    uint32 internal constant WEEK = 7 days;

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
    }

    struct Coin {
        PoolKey key;
        PoolId id;
        IERC20 coin;
        StokerCreatorLock lock;
        uint256 locked;
        uint256 graduatedAt;
    }

    /// A standard Launch with a Creator Lock of a fifth naming `destination`, traded across its Graduation
    /// Target, held for the hour and graduated.
    function _graduatedWithALock(uint256 kind, address destination) internal returns (Coin memory c) {
        StokerFactory.LaunchParams memory p = _typedParams(
            kind == NATIVE_PAIR ? address(0) : address(quote),
            kind == QUOTE_FIRST,
            0,
            StokerHook.LaunchType.Standard,
            0,
            0,
            0,
            StokerHook.PayoutAsset.QuoteAsset
        );
        p.creatorDestination = destination;
        p.creatorLockBps = A_FIFTH;
        p.creatorLockCliff = WEEK;
        (, c.key) = _launchWith(p);
        c.id = c.key.toId();
        c.coin = _coinOfKey(c.key);
        c.lock = StokerCreatorLock(factory.creatorLockOf(c.id));
        c.locked = c.coin.balanceOf(address(c.lock));
        assertEq(c.locked, SUPPLY / 5, "a fifth held by the lock");

        _trade(c.key, trader, true, true, kind == NATIVE_PAIR ? 7 ether : 100 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.graduate(c.id);
        c.graduatedAt = hook.graduationOf(c.id).graduatedAt;
        assertGt(c.graduatedAt, 0, "graduated");
        assertGt(_credited(c.key), 0, "the crossing buy credited the Destination");
    }

    /// What must be as it was after a Destination's work: the lock's coins, its claim, and Graduation.
    function _lockAndGraduationUntouched(Coin memory c) internal view {
        assertEq(c.coin.balanceOf(address(c.lock)), c.locked, "the lock holds its fifth");
        assertEq(c.lock.claimed(), 0, "nothing was claimed from it");
        assertEq(hook.graduationOf(c.id).graduatedAt, c.graduatedAt, "Graduation is as it was recorded");
    }

    /// The ladder key raises the graduated coin (as it would once its Active Days are counted), the next swap
    /// credits its Destination the second tier's share, and after the cliff the Creator claims the whole lock.
    function _thenARaise_andTheLockIsClaimed(Coin memory c, EarningsDestination d) internal {
        _raise(c.key, 2);
        assertEq(hook.graduationOf(c.id).graduatedAt, c.graduatedAt, "a raise leaves Graduation as it was");
        uint256 credited = _credited(c.key);
        uint256 claims = _hookClaimsOf(c.key);
        _trade(c.key, trader, false, true, c.coin.balanceOf(trader) / 10);
        uint256 fee = _hookClaimsOf(c.key) - claims;
        assertGt(fee, 0);
        assertEq(_credited(c.key) - credited, fee * SECOND_TIER_SHARE_BPS / 10_000, "the second tier's share");
        assertEq(d.waitingOf(c.key), _credited(c.key) - d.appliedOf(c.id), "and it waits for the Destination");

        // The cliff's end, unless the test's waits have already passed it: the clock never runs back.
        if (vm.getBlockTimestamp() < c.graduatedAt + WEEK) vm.warp(c.graduatedAt + WEEK);
        uint256 before = c.coin.balanceOf(creator);
        vm.prank(creator);
        c.lock.claim();
        assertEq(c.coin.balanceOf(creator) - before, c.locked, "the Creator claimed the whole lock");
        assertEq(c.coin.balanceOf(address(c.lock)), 0);
    }

    function _apply(EarningsDestination d, Coin memory c) internal returns (uint256 applied) {
        uint256 credited = _credited(c.key);
        vm.prank(stranger);
        applied = d.applyEarnings(c.key);
        assertEq(applied, credited, "exactly the coin's own earnings");
        _lockAndGraduationUntouched(c);
    }

    // ---------------------------------------------------------------- the burn

    function _burn(uint256 kind) internal {
        Coin memory c = _graduatedWithALock(kind, address(burnDestination));
        _apply(burnDestination, c);
        _letThePriceStand();
        uint256 supply = c.coin.totalSupply();
        uint256 burnedInAll;
        for (uint256 i; i < 20; i++) {
            (uint256 waiting,) = taxVault.fundedWaiting(c.key);
            if (waiting == 0) break;
            vm.prank(stranger);
            (, uint256 burned) = taxVault.burn(c.key);
            burnedInAll += burned;
            _letThePriceStand();
        }
        assertGt(burnedInAll, 0);
        assertEq(supply - c.coin.totalSupply(), burnedInAll, "the supply fell by exactly what was bought");
        // Not a coin of the lock's was burned: it holds its fifth, of a smaller supply.
        _lockAndGraduationUntouched(c);
        assertEq(c.coin.balanceOf(address(taxVault)), 0);
        _thenARaise_andTheLockIsClaimed(c, burnDestination);
    }

    function test_graduatedWithALock_theBurn_quoteFirst() public {
        _burn(QUOTE_FIRST);
    }

    function test_graduatedWithALock_theBurn_coinFirst() public {
        _burn(COIN_FIRST);
    }

    function test_graduatedWithALock_theBurn_native() public {
        _burn(NATIVE_PAIR);
    }

    // ---------------------------------------------------------------- the liquidity

    function _liquidity(uint256 kind) internal {
        Coin memory c = _graduatedWithALock(kind, address(liquidityDestination));
        uint256 applied = _apply(liquidityDestination, c);
        _letThePriceStand();
        uint160 price = _sqrtPrice(c.key);
        uint256 supply = c.coin.totalSupply();
        uint256 inPool = c.coin.balanceOf(address(pm));
        uint256 addedInAll;
        for (uint256 i; i < 20; i++) {
            (, uint256 waiting) = taxVault.fundedWaiting(c.key);
            if (waiting <= 2) break;
            (Support memory s, uint256 added) = _addSupport(c.key);
            (, uint256 coinsHeld) = _supportHoldings(c.key, s);
            assertEq(coinsHeld, 0, "Quote Asset alone");
            addedInAll += added;
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
        }
        assertGt(addedInAll, 0, "Support Liquidity grew");
        assertLe(addedInAll, applied);
        assertEq(_sqrtPrice(c.key), price, "the price did not move");
        assertEq(c.coin.totalSupply(), supply, "no coin was burned");
        assertEq(c.coin.balanceOf(address(pm)), inPool, "no coin was bought");
        _lockAndGraduationUntouched(c);
        _thenARaise_andTheLockIsClaimed(c, liquidityDestination);
    }

    function test_graduatedWithALock_theLiquidity_quoteFirst() public {
        _liquidity(QUOTE_FIRST);
    }

    function test_graduatedWithALock_theLiquidity_coinFirst() public {
        _liquidity(COIN_FIRST);
    }

    function test_graduatedWithALock_theLiquidity_native() public {
        _liquidity(NATIVE_PAIR);
    }

    // ---------------------------------------------------------------- the holders

    function _holders(uint256 kind) internal {
        Coin memory c = _graduatedWithALock(kind, address(holdersDestination));
        uint256 applied = _apply(holdersDestination, c);
        Currency asset = _quoteOfKey(c.key);
        assertEq(distributor.earningsPotOf(address(c.coin), asset), applied, "the coin's earnings pot");

        // The Reward Engine leaves a Creator Lock out of a root (#255): it can claim nothing. Two holders.
        address alice = makeAddr(string.concat("alice", vm.toString(kind)));
        address bob = makeAddr(string.concat("bob", vm.toString(kind)));
        (address[] memory holders, uint256[] memory amounts) = _pair(alice, applied / 4, bob, applied - applied / 4);
        Built memory round = _build(address(c.coin), asset, holders, amounts);
        vm.prank(roundKey);
        distributor.postEarningsRoot(round.round, address(c.coin), asset, round.root, round.total);
        _warpPastDelay(round.round);
        vm.prank(stranger);
        distributor.claim{gas: 1_000_000}(_claims(round));
        assertEq(_balance(asset, alice), applied / 4, "her Holder Dividend");
        assertEq(_balance(asset, bob), applied - applied / 4, "his");
        assertEq(distributor.earningsPotOf(address(c.coin), asset), 0);
        _lockAndGraduationUntouched(c);
        _thenARaise_andTheLockIsClaimed(c, holdersDestination);
    }

    function test_graduatedWithALock_theHolders_quoteFirst() public {
        _holders(QUOTE_FIRST);
    }

    function test_graduatedWithALock_theHolders_coinFirst() public {
        _holders(COIN_FIRST);
    }

    function test_graduatedWithALock_theHolders_native() public {
        _holders(NATIVE_PAIR);
    }
}
