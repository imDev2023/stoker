// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";
import {RevertingRecipient, TradingRecipient} from "../utils/Recipients.sol";

/// From the main session's adversarial review of PR #278 (#248), taken into the suite: what the reviewer
/// tried against the per-coin book of Creator Credits and the Destinations, each as a test that stays. (Its
/// two tests of the ladder key, the Admin naming itself the key and the gas of a raise, are in
/// `Ladder.t.sol` and `LadderHostile.t.sol`.)
contract DestinationsReviewTest is DestinationsLocalBase {
    /// Two coins name one Destination in the native asset. A Keeper's batch names the Destination twice, an
    /// owner that refuses, and an owner that trades the first coin from inside its own payment (booking a
    /// new Credit to the Destination while the call is under way). After all of it each coin is handed
    /// exactly its own book, the Destination is left holding nothing, and the claims back every Credit.
    function test_review_thePerCoinBook_survivesDuplicatesRefusalsAndATradeFromInsideAPayment() public {
        EarningsDestination d = EarningsDestination(payable(address(liquidityDestination)));
        PoolKey memory a = _launchTo(NATIVE_PAIR, address(d));
        PoolKey memory b = _launchTo(NATIVE_PAIR, address(d));
        _churn(a, 2);
        _churn(b, 1);

        RevertingRecipient refuser = new RevertingRecipient();
        PoolKey memory refusersCoin = _launchTo(NATIVE_PAIR, address(refuser));
        _churn(refusersCoin, 1);
        TradingRecipient tradingOwner = new TradingRecipient(hook, swapRouter, a);
        PoolKey memory tradersCoin = _launchTo(NATIVE_PAIR, address(tradingOwner));
        _churn(tradersCoin, 1);
        vm.deal(address(tradingOwner), 1 ether);

        uint256 creditedA0 = _credited(a);
        address[] memory owners = new address[](4);
        (owners[0], owners[1], owners[2], owners[3]) = (address(tradingOwner), address(d), address(refuser), address(d));
        // The trading owner pulls (it is the only way to be given a trade's gas), the Destination named twice.
        tradingOwner.pull(owners);
        assertTrue(tradingOwner.traded(), "a trade from inside its payment");
        assertGt(_credited(a), creditedA0, "the trade booked coin a's book while the call was under way");
        assertGt(_nativeCredit(address(d)), 0, "and a new Credit to the Destination, after its payment");
        assertGt(_nativeCredit(address(refuser)), 0, "the refuser stays owed");

        uint256 waitingA = d.waitingOf(a);
        uint256 waitingB = d.waitingOf(b);
        assertEq(waitingA + waitingB, address(d).balance + _nativeCredit(address(d)), "the books are what it holds");

        vm.prank(stranger);
        assertEq(d.applyEarnings(b), waitingB, "b is handed its own book");
        vm.prank(stranger);
        assertEq(d.applyEarnings(a), waitingA, "a is handed its own book, the late Credit among it");
        assertEq(d.appliedOf(a.toId()), _credited(a));
        assertEq(d.appliedOf(b.toId()), _credited(b));
        assertEq(address(d).balance, 0, "nothing left behind");
        assertEq(_nativeCredit(address(d)), 0);
        (, uint256 fundedA) = taxVault.fundedWaiting(a);
        (, uint256 fundedB) = taxVault.fundedWaiting(b);
        assertEq(fundedA, _credited(a), "a's Support Liquidity funded by a's earnings alone");
        assertEq(fundedB, _credited(b), "b's by b's alone");
        assertEq(_nativeClaims(), hook.totalCredits(NATIVE), "the claims back every Credit");
    }

    /// A trade may name a Destination contract as its referrer (the hook refuses only our five contracts).
    /// The Referrer Fee is booked to the Destination outside every coin's book, so no `applyEarnings` ever
    /// hands it on: it stays in the Destination for good. Nobody's earnings are short by it; the launch form
    /// and the front-ends name no Destination as a referrer.
    function test_review_aReferrerFeeNamedToADestinationIsStrandedThere() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(burnDestination));
        _churn(key, 1);
        _approveRouter(key, trader);
        uint160 limit = _isQuote0(key) ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        _swapWithData(key, trader, true, true, 10 ether, limit, _referral(address(burnDestination), 75));
        uint256 referrerFee = _feeOnGrossAt(10 ether, 75);
        assertGt(referrerFee, 0);

        vm.prank(stranger);
        uint256 applied = burnDestination.applyEarnings(key);
        assertEq(applied, _credited(key), "the coin's own earnings, whole, and nothing of the Referrer Fee");
        assertEq(burnDestination.waitingOf(key), 0);
        assertEq(quote.balanceOf(address(burnDestination)), referrerFee, "the Referrer Fee is left behind for good");
        vm.prank(stranger);
        vm.expectRevert(EarningsDestination.NothingToApply.selector);
        burnDestination.applyEarnings(key);
    }

    /// Each Destination's native receive, called by the hook with the Payout Call's 50,000 gas and the
    /// Destination's account cold, fits well inside it (30,549 as the review measured it, most of it the cold
    /// account and the value transfer).
    function test_review_aDestinationsReceiveFitsThePayoutGas() public {
        address[3] memory d = [address(burnDestination), address(liquidityDestination), address(holdersDestination)];
        vm.deal(address(hook), 1 ether);
        for (uint256 i; i < d.length; i++) {
            vm.cool(d[i]);
            vm.prank(address(hook));
            uint256 g0 = gasleft();
            (bool ok,) = d[i].call{value: 1, gas: 50_000}("");
            uint256 used = g0 - gasleft();
            assertTrue(ok, "accepted within the Payout Call's gas");
            emit log_named_uint("receive, cold, with the value transfer", used);
            assertLt(used, 40_000);
        }
    }
}
