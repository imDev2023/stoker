// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The Opening Fee beside Graduation and the Creator Lock (#246 with #244), in all three pool kinds: on a coin
/// with a Creator Lock the seed is the supply less the lock, and the First Buy, a snipe's Opening Fee and its
/// Support Liquidity behave as on any coin; a buy inside the window that crosses the Graduation Target pays
/// the Opening Fee and starts the hold by #244's rule, judged by the next transaction.
/// The hold judges the price each transaction leaves, so every top-level call here is a transaction of its own.
/// forge-config: default.isolate = true
contract OpeningFeeGraduationTest is TaxLocalBase, OpeningFeeHelpers {
    using StateLibrary for IPoolManager;

    uint16 internal constant LOCK_BPS = 2_000;

    function setUp() public override {
        super.setUp();
        vm.warp(1_800_000_000);
        mockQuote.mint(stranger, 1_000 ether);
        vm.deal(stranger, 10 ether);
    }

    // ---------------------------------------------------------------- a Creator Lock and the window

    function _launchLocked(uint256 kind, uint256 firstBuy) internal returns (PoolKey memory key) {
        _tradeInOpening = true;
        StokerFactory.LaunchParams memory p = _typedParams(
            kind == 2 ? address(0) : address(quote),
            kind == 1,
            firstBuy,
            StokerHook.LaunchType.Standard,
            0,
            0,
            0,
            StokerHook.PayoutAsset.QuoteAsset
        );
        p.creatorLockBps = LOCK_BPS;
        p.creatorLockCliff = 7 days;
        (, key) = _launchWith(p);
    }

    function _lockedCoinBehavesTheSame(uint256 kind) internal {
        uint256 firstBuy = kind == 2 ? 0.1 ether : 1 ether;
        uint256 claims0 = pm.balanceOf(address(hook), (kind == 2 ? NATIVE : _quoteCurrency()).toId());
        PoolKey memory key = _launchLocked(kind, firstBuy);
        IERC20 coin = _coinOfKey(key);
        address lock = factory.creatorLockOf(key.toId());

        // The seed is the supply less the lock: the lock holds its fifth, and every other coin is in the pool
        // or with the Creator, the seed's rounding dust burned.
        assertEq(coin.balanceOf(lock), SUPPLY * LOCK_BPS / 10_000, "the lock holds its share");
        assertEq(
            coin.balanceOf(address(pm)) + coin.balanceOf(creator) + coin.balanceOf(lock),
            coin.totalSupply(),
            "the pool, the Creator and the lock hold every coin"
        );
        assertLe(SUPPLY - coin.totalSupply(), 1e18, "only the seed's rounding dust burned");

        // The First Buy, in the launch's own second, pays the Platform Fee alone.
        assertEq(hook.openingFeeBooked(key.toId()), 0, "no Opening Fee on the First Buy");
        assertEq(_hookClaimsOf(key) - claims0, _rateOfGross(firstBuy, PLATFORM_FEE_BPS), "its Platform Fee");

        // A snipe in the launch's own second pays the rule's Opening Fee, all of it waiting as Support
        // Liquidity, which is placed after the window as on any coin.
        Seen memory s = _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
        _checkBuy(s, true, 0, 0, 0);
        assertGt(s.opening, 0, "the snipe paid an Opening Fee");
        (, uint256 supportPart,,) = taxVault.waiting(key);
        assertEq(supportPart, s.opening, "all of it waits as Support Liquidity");
        vm.warp(_launchedAt(key) + OPENING_FEE_DURATION);
        uint160 price = _sqrtPrice(key);
        (Support memory sup, uint256 added) = _addSupport(key);
        assertGt(added, 0, "a piece placed");
        assertEq(_sqrtPrice(key), price, "the price unmoved");
        (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, sup);
        assertApproxEqAbs(quoteHeld, added, 2, "Quote Asset alone");
        assertEq(coinsHeld, 0, "no coin");
        assertEq(coin.balanceOf(lock), SUPPLY * LOCK_BPS / 10_000, "and the lock is untouched");
    }

    function test_opening_aCoinWithACreatorLock_coinIsCurrency0() public {
        _lockedCoinBehavesTheSame(0);
    }

    function test_opening_aCoinWithACreatorLock_coinIsCurrency1() public {
        _lockedCoinBehavesTheSame(1);
    }

    function test_opening_aCoinWithACreatorLock_native() public {
        _lockedCoinBehavesTheSame(2);
    }

    // ---------------------------------------------------------------- a buy across the Graduation Target

    /// A buy at three seconds, with the coin as its specified side and the Graduation Target as its price
    /// limit, so it stops on the target: it pays the Opening Fee by the rule, and the hold starts from its
    /// transaction, recorded by the next transaction to swap the pool.
    function _buyAcrossTheTarget(uint256 kind) internal {
        PoolKey memory key = _launchOpen(kind, 0, 0);
        PoolId id = key.toId();
        uint160 target = hook.termsOf(id).graduationSqrtPriceX96;
        vm.warp(_launchedAt(key) + 3);
        uint256 t0 = vm.getBlockTimestamp();

        Seen memory before = _snapshot(key, trader);
        if (_native(key)) {
            _swapNativeWithData(key, trader, true, false, 9.5e11 ether, trader.balance, target, "");
        } else {
            _approveRouter(key, trader);
            _swapWithData(key, trader, true, false, 9.5e11 ether, target, "");
        }
        Seen memory s = _since(key, before);
        assertEq(_sqrtPrice(key), target, "the buy stopped on the Graduation Target");
        _checkBuy(s, false, 3, 0, 0);
        assertGt(s.opening, 0, "and paid the Opening Fee");

        // #244's rule: the hold runs from the transaction that left the price there, judged by the next.
        assertEq(hook.graduationNow(id).holdSince, t0, "the hold runs from the crossing's transaction");
        assertEq(hook.graduationOf(id).holdSince, 0, "not yet recorded: the next transaction judges it");
        vm.warp(t0 + 5 minutes);
        _tradeAs(stranger, key, true, true, _native(key) ? 1e9 : 1e12, 0);
        assertEq(hook.graduationOf(id).holdSince, t0, "recorded from the crossing's transaction");
        assertEq(hook.graduationOf(id).graduatedAt, 0, "and nothing has graduated inside the hour");
    }

    /// What changed in the books since `before`, the trader's Quote Asset in `quoteIn`.
    function _since(PoolKey memory key, Seen memory before) internal view returns (Seen memory s) {
        Seen memory afterwards = _snapshot(key, trader);
        s.quoteIn = before.quoteIn - afterwards.quoteIn;
        s.creatorCredit = afterwards.creatorCredit - before.creatorCredit;
        s.platformCredit = afterwards.platformCredit - before.platformCredit;
        s.referrerCredit = afterwards.referrerCredit - before.referrerCredit;
        s.tax = afterwards.tax - before.tax;
        s.opening = afterwards.opening - before.opening;
        assertEq(afterwards.vaultClaims - before.vaultClaims, s.tax + s.opening, "the vault's claims");
    }

    function test_opening_aBuyAcrossTheGraduationTarget_coinIsCurrency0() public {
        _buyAcrossTheTarget(0);
    }

    function test_opening_aBuyAcrossTheGraduationTarget_coinIsCurrency1() public {
        _buyAcrossTheTarget(1);
    }

    function test_opening_aBuyAcrossTheGraduationTarget_native() public {
        _buyAcrossTheTarget(2);
    }
}
