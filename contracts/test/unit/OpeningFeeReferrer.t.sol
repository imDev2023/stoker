// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {MockQuote} from "../utils/MockQuote.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The Opening Fee and a Referrer Fee (#246, from the review of PR #274): inside the window a Referrer Fee
/// takes only the room the Platform Fee, the tax and the Opening Fee leave under the start figure, so naming a
/// referrer never lowers the Opening Fee and a buyer naming itself gets back only what it paid on top. The
/// Quote Asset here is a fresh mock listed at the registry's highest Referrer Fee cap (5.00%), which a
/// Listing may carry; the fixture's own listing uses 1.00%.
contract OpeningFeeReferrerTest is TaxLocalBase, OpeningFeeHelpers {
    uint16 internal constant CAP = 500;
    address internal sniper = makeAddr("sniper");

    function setUp() public override {
        super.setUp();
        MockQuote q = new MockQuote();
        mockQuote = q;
        quote = IERC20(address(q));
        vm.prank(platform);
        registry.list(address(q), START_TICK, GRADUATION_MULTIPLE, CAP);
        q.mint(creator, 1_000 ether);
        q.mint(trader, 1_000_000 ether);
        q.mint(sniper, 1_000_000 ether);
    }

    // ---------------------------------------------------------------- no self-referral rebate

    /// The review's case: a buyer that names itself at the cap must never get the same coins cheaper, and
    /// the coin's Support Liquidity must never receive less because a referrer was named (ADR 0026 and #246:
    /// "no Credit of the Creator, a referrer or the platform grows by it"). Before the fix, at the launch's
    /// own second on 10 of the Quote Asset, the Opening Fee fell from 9.80 to 9.30 and the buyer was paid
    /// back 0.50.
    function test_opening_selfReferralNeverTurnsTheOpeningFeeIntoACredit() public {
        // Same coins in both trades: an exact-in buy at the launch's own second (99% either way, the same net),
        // and exact-out buys at 0, 10 and 19 seconds.
        uint256[4] memory at = [uint256(0), 0, 10, 19];
        for (uint256 i; i < 4; i++) {
            {
                bool exactIn = i == 0;
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(0, 0, 0);
                vm.warp(_launchedAt(key) + at[i]);
                uint256 amount = exactIn ? 10 ether : 1e10 ether;

                uint256 inner = vm.snapshotState();
                referrer = makeAddr("referrer");
                Seen memory plain = _tradeAndSee(key, true, exactIn, amount, 0);
                uint256 coinsPlain = _coinOfKey(key).balanceOf(trader);
                vm.revertToState(inner);

                referrer = trader; // the buyer names itself
                Seen memory self = _tradeAndSee(key, true, exactIn, amount, CAP);
                uint256 coinsSelf = _coinOfKey(key).balanceOf(trader);

                // The buyer then pulls its own Credit.
                address[] memory owners = new address[](1);
                owners[0] = trader;
                uint256 balBefore = quote.balanceOf(trader);
                hook.payout(_quoteOfKey(key), owners);
                uint256 rebate = quote.balanceOf(trader) - balBefore;

                emit log_named_uint("elapsed", at[i]);
                emit log_named_uint("exactIn", exactIn ? 1 : 0);
                emit log_named_uint("paid, no referrer", plain.quoteIn);
                emit log_named_uint("paid, self-referred", self.quoteIn);
                emit log_named_uint("rebate pulled by the buyer", rebate);
                emit log_named_uint("Opening Fee, no referrer", plain.opening);
                emit log_named_uint("Opening Fee, self-referred", self.opening);

                emit log_named_uint("net cost, self-referred", self.quoteIn - rebate);
                assertApproxEqAbs(coinsSelf, coinsPlain, coinsPlain / 1e12 + 1, "the same coins either way");
                assertEq(rebate, self.referrerCredit, "the buyer was paid its own Referrer Fee");
                // Naming oneself must never make the same coins cheaper, and what the coin's Support Liquidity
                // receives must not fall because the buyer named a referrer.
                assertGe(self.quoteIn - rebate, plain.quoteIn, "self-referral made the same coins cheaper");
                assertGe(self.opening, plain.opening, "self-referral moved Opening Fee into the buyer's own Credit");
                vm.revertToState(snap);
            }
        }
    }

    // ---------------------------------------------------------------- exact-in and exact-out cost the same

    /// For the same coins at the same second, an exact-out buy never costs materially less than an exact-in
    /// buy, with any referrer and on every type: a buyer cannot choose the swap type to pay less Opening Fee.
    function testFuzz_opening_exactOutNeverCheaperThanExactIn(uint256 amount, uint256 elapsed, uint256 lt, uint256 r)
        public
    {
        amount = bound(amount, 1e9, 50 ether);
        elapsed = bound(elapsed, 0, OPENING_FEE_DURATION);
        lt = bound(lt, 0, 2);
        uint256 referrerBps = bound(r, 0, CAP);
        PoolKey memory key = _launchOpen(0, lt, 0);
        vm.warp(_launchedAt(key) + elapsed);

        uint256 snap = vm.snapshotState();
        Seen memory ein = _tradeAndSee(key, true, true, amount, referrerBps);
        uint256 coins = _coinOfKey(key).balanceOf(trader);
        vm.revertToState(snap);
        Seen memory eout = _tradeAndSee(key, true, false, coins, referrerBps);
        assertEq(_coinOfKey(key).balanceOf(trader), coins, "the same coins");
        // The pool's own rounding gives the exact-out buyer at most one wei of net back, which the fees
        // multiply by at most 10_000 / (10_000 - 9_900) = 100, and the exact-in buy's own rounding up.
        assertLe(eout.quoteIn, ein.quoteIn, "exact out never costs more for the same coins");
        assertGe(eout.quoteIn + 201, ein.quoteIn, "exact out never materially cheaper");
        assertGe(eout.opening + 201, ein.opening, "nor less Opening Fee");
    }

    // ---------------------------------------------------------------- dust cannot round it away

    /// A buy split into many small buys in one second pays at least the Opening Fee of the whole buy.
    function test_opening_splittingIntoDustNeverPaysLess() public {
        for (uint256 e; e < 2; e++) {
            bool exactIn = e == 0;
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(0, 1, 0);
            vm.warp(_launchedAt(key) + 7);
            uint256 piece = exactIn ? 1_013 : 41_000_000_000_017; // odd sizes, so every piece rounds
            uint256 n = 300;
            uint256 inner = vm.snapshotState();
            Seen memory whole = _tradeAndSee(key, true, exactIn, piece * n, CAP);
            uint256 coinsWhole = _coinOfKey(key).balanceOf(trader);
            vm.revertToState(inner);
            uint256 openingSplit;
            uint256 takenSplit;
            uint256 paidSplit;
            for (uint256 i; i < n; i++) {
                Seen memory s = _tradeAndSee(key, true, exactIn, piece, CAP);
                openingSplit += s.opening;
                takenSplit += _taken(s);
                paidSplit += s.quoteIn;
            }
            uint256 coinsSplit = _coinOfKey(key).balanceOf(trader);
            emit log_named_uint("whole: Opening Fee", whole.opening);
            emit log_named_uint("split: Opening Fee", openingSplit);
            emit log_named_uint("whole: all fees", _taken(whole));
            emit log_named_uint("split: all fees", takenSplit);
            assertGe(takenSplit, _taken(whole), "split buys pay at least the whole buy's fees");
            // The standing fees' own roundings may take a few wei per buy from the Opening Fee's rest.
            assertGe(openingSplit + 3 * n, whole.opening, "and about its Opening Fee");
            if (exactIn) assertLe(coinsSplit, coinsWhole, "and get no more coins");
            else assertGe(paidSplit, whole.quoteIn, "and pay no less for the same coins");
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- what naming a referrer costs

    /// For any exact-in buy at any second, in every type and both orders, naming a referrer at any rate up to
    /// the cap leaves the Platform Fee, the tax and the Opening Fee the same to the wei, takes exactly the
    /// referrer's Credit more from the buy, pays the rate the rule allows under the start figure, and the fees
    /// together never pass the start figure of the payment.
    function testFuzz_opening_namingAReferrerCostsExactlyItsFee(
        uint256 kind,
        uint256 lt,
        uint256 amount,
        uint256 elapsed,
        uint256 r
    ) public {
        kind = bound(kind, 0, 1);
        lt = bound(lt, 0, 2);
        amount = bound(amount, 1e6, 50 ether);
        elapsed = bound(elapsed, 0, OPENING_FEE_DURATION + 2);
        uint256 referrerBps = bound(r, 1, CAP);
        PoolKey memory key = _launchOpen(kind, lt, 0);
        vm.warp(_launchedAt(key) + elapsed);
        uint256 snap = vm.snapshotState();
        Seen memory plain = _tradeAndSee(key, true, true, amount, 0);
        vm.revertToState(snap);
        Seen memory named = _tradeAndSee(key, true, true, amount, referrerBps);
        _checkBuy(named, true, elapsed, referrerBps, _taxBpsOf(key));
        assertEq(named.opening, plain.opening, "the Opening Fee is the same to the wei");
        assertEq(named.creatorCredit + named.platformCredit, plain.creatorCredit + plain.platformCredit, "fee");
        assertEq(named.tax, plain.tax, "the tax");
        assertEq(_taken(named) - _taken(plain), named.referrerCredit, "naming costs exactly the referrer's fee");
        assertLe(_taken(named), _rateOfGross(amount, OPENING_FEE_START_BPS), "never past the start figure");
    }

    /// The Referrer Fee inside the window: nothing at the launch's own second, growing as the schedule falls,
    /// whole once the room under the start figure holds it, and whole after the window.
    function test_opening_theReferrerFeeGrowsIntoTheRoomTheScheduleLeaves() public {
        uint256 last;
        for (uint256 at; at <= OPENING_FEE_DURATION; at++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(0, 0, 0);
            vm.warp(_launchedAt(key) + at);
            Seen memory s = _tradeAndSee(key, true, true, 10 ether, CAP);
            _checkBuy(s, true, at, CAP, 0);
            if (at == 0) assertEq(s.referrerCredit, 0, "nothing at the launch's own second");
            assertGe(s.referrerCredit, last, "never falls as the schedule does");
            last = s.referrerCredit;
            uint256 opening = _openingRateAt(at, PLATFORM_FEE_BPS);
            if (OPENING_FEE_START_BPS - PLATFORM_FEE_BPS - opening >= CAP) {
                assertEq(s.referrerCredit, _rateOfGross(10 ether, CAP), "whole once it fits");
            }
            vm.revertToState(snap);
        }
    }
}
