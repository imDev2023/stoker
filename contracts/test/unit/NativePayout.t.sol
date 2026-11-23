// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {
    RevertingRecipient,
    GasBurningRecipient,
    ReturnBombRecipient,
    ReentrantPayoutRecipient,
    ReentrantSwapRecipient,
    SyncingRecipient,
    HeavyRecipient,
    CountingRecipient
} from "../utils/Recipients.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// A Payout Call pays a Credit in the native asset without ever handing control to a recipient inside
/// someone's swap or inside the PoolManager's unlock, and a recipient that refuses, re-enters or burns its
/// gas keeps its Credit owed, to itself, while the others in the same call are paid (#242, ADR 0025).
contract NativePayoutTest is LocalBase {
    PoolKey internal key; // the EOA Creator's coin
    address[] internal hostile;

    function setUp() public override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);

        (, key) = _launchNative(0.1 ether, address(0));
        _swapNative(key, trader, true, true, 1 ether, 0);

        hostile.push(address(new RevertingRecipient()));
        hostile.push(address(new GasBurningRecipient()));
        hostile.push(address(new ReturnBombRecipient()));
        hostile.push(address(new ReentrantPayoutRecipient(hook, false)));
        hostile.push(address(new ReentrantSwapRecipient(pm, key, false)));
        // Each hostile contract is the Creator Earnings Destination of a coin of its own, and is credited.
        for (uint256 i; i < hostile.length; i++) {
            _creditThrough(hostile[i]);
        }
    }

    /// Launches a coin paired with the native asset whose Destination is `who`, and trades it so that
    /// `who` holds a native Credit.
    function _creditThrough(address who) internal returns (PoolKey memory k) {
        (, k) = _launchNative(0.01 ether, who);
        _swapNative(k, trader, true, true, 0.5 ether, 0);
        assertGt(_nativeCredit(who), 0);
    }

    function _owners() internal view returns (address[] memory o) {
        o = new address[](hostile.length + 2);
        o[0] = creator;
        for (uint256 i; i < hostile.length; i++) {
            o[i + 1] = hostile[i];
        }
        o[o.length - 1] = platform;
    }

    function test_native_payout_ordinaryWalletPaid_hostileRecipientsStayOwed() public {
        uint256 creatorCredit = _nativeCredit(creator);
        uint256 platformCredit = _nativeCredit(platform);
        uint256[] memory owed = new uint256[](hostile.length);
        uint256 hostileOwed;
        for (uint256 i; i < hostile.length; i++) {
            owed[i] = _nativeCredit(hostile[i]);
            hostileOwed += owed[i];
        }
        uint256 creatorBefore = creator.balance;
        uint256 strangerBefore = stranger.balance;

        // Every refusal is said in an event, to the address that refused.
        for (uint256 i; i < hostile.length; i++) {
            vm.expectEmit(true, true, false, true, address(hook));
            emit StokerHook.CreditRefused(hostile[i], NATIVE, owed[i]);
        }
        vm.prank(stranger);
        hook.payout(NATIVE, _owners());

        assertEq(creator.balance - creatorBefore, creatorCredit, "the ordinary wallet paid in full");
        assertEq(platform.balance, platformCredit, "the platform paid in full");
        assertEq(stranger.balance, strangerBefore, "the caller gains nothing");
        for (uint256 i; i < hostile.length; i++) {
            assertEq(_nativeCredit(hostile[i]), owed[i], "a hostile recipient's Credit stays owed to it");
            assertEq(hostile[i].balance, 0, "and it received nothing");
        }
        assertEq(_nativeCredit(creator), 0);
        assertEq(_nativeCredit(platform), 0);
        assertEq(_nativeClaims(), hostileOwed, "the claims back exactly what is still owed");
        assertEq(hook.totalCredits(NATIVE), hostileOwed);
        assertEq(address(hook).balance, 0, "the hook keeps no native asset between calls");
    }

    function test_native_payout_reentryFindsTheLockedPoolManagerAndTheGuard() public {
        // Lenient re-entering recipients record what their re-entry met, and accept: a second Payout Call
        // is refused by the guard, and the PoolManager is locked while the payment is made, so neither a
        // swap nor a take can be made from inside it. Each is paid once, exactly its Credit.
        ReentrantPayoutRecipient again = new ReentrantPayoutRecipient(hook, true);
        ReentrantSwapRecipient direct = new ReentrantSwapRecipient(pm, key, true);
        _creditThrough(address(again));
        _creditThrough(address(direct));
        uint256 owedAgain = _nativeCredit(address(again));
        uint256 owedDirect = _nativeCredit(address(direct));
        address[] memory two = new address[](2);
        two[0] = address(again);
        two[1] = address(direct);
        vm.prank(stranger);
        hook.payout(NATIVE, two);

        assertEq(again.met(), StokerHook.PayoutReentered.selector, "the second Payout Call met the guard");
        assertEq(direct.swapMet(), IPoolManager.ManagerLocked.selector, "the swap met a locked PoolManager");
        assertEq(direct.takeMet(), IPoolManager.ManagerLocked.selector, "the take met a locked PoolManager");
        assertEq(address(again).balance, owedAgain, "paid once, exactly its Credit");
        assertEq(address(direct).balance, owedDirect, "paid once, exactly its Credit");

        // Strict ones refuse for what their re-entry met, and stay owed.
        for (uint256 i = 3; i < 5; i++) {
            address[] memory one = new address[](1);
            one[0] = hostile[i];
            uint256 owed = _nativeCredit(hostile[i]);
            hook.payout(NATIVE, one);
            assertEq(_nativeCredit(hostile[i]), owed, "refused, still owed");
            assertEq(hostile[i].balance, 0);
        }
        assertEq(_nativeClaims(), hook.totalCredits(NATIVE));
    }

    function test_native_payout_recipientThatSyncsTheManagerCannotStopTheReturn() public {
        // A recipient that accepts and leaves the PoolManager synced to an ERC-20, beside one that refuses:
        // the refused Credit's return into the PoolManager still settles, and both outcomes stand.
        SyncingRecipient syncer = new SyncingRecipient(pm, Currency.wrap(address(quote)));
        _creditThrough(address(syncer));
        uint256 paid = _nativeCredit(address(syncer));
        uint256 refused = _nativeCredit(hostile[0]);
        address[] memory two = new address[](2);
        two[0] = address(syncer);
        two[1] = hostile[0];
        hook.payout(NATIVE, two);
        assertEq(address(syncer).balance, paid, "the syncing recipient paid");
        assertEq(_nativeCredit(hostile[0]), refused, "the refusing one still owed");
        assertEq(_nativeClaims(), hook.totalCredits(NATIVE));
    }

    function test_native_payout_refusedCreditIsPaidOnceAccepted() public {
        // A refusal is no forfeit: the Credit waits for its owner, and trading goes on meanwhile.
        CountingRecipient later = new CountingRecipient();
        PoolKey memory k = _creditThrough(address(later));
        uint256 owed = _nativeCredit(address(later));
        vm.etch(address(later), address(new RevertingRecipient()).code);
        address[] memory one = new address[](1);
        one[0] = address(later);
        hook.payout(NATIVE, one);
        assertEq(_nativeCredit(address(later)), owed, "refused");
        _swapNative(k, trader, true, true, 0.5 ether, 0);
        uint256 more = _nativeCredit(address(later));
        assertGt(more, owed, "still credited while refusing");

        vm.etch(address(later), address(new CountingRecipient()).code);
        hook.payout(NATIVE, one);
        assertEq(address(later).balance, more, "paid in full once it accepts");
        assertEq(_nativeCredit(address(later)), 0);
    }

    function test_native_payout_heavyWalletIsPaidWhenItPullsItsOwn() public {
        // A wallet whose receive needs more than the gas a payment to someone else carries is refused by
        // a stranger's call and keeps its Credit; pulling its own, it is given all the gas and is paid.
        HeavyRecipient heavy = new HeavyRecipient();
        _creditThrough(address(heavy));
        uint256 owed = _nativeCredit(address(heavy));
        address[] memory one = new address[](1);
        one[0] = address(heavy);
        vm.prank(stranger);
        hook.payout(NATIVE, one);
        assertEq(_nativeCredit(address(heavy)), owed, "refused within the cap");
        heavy.pull(hook);
        assertEq(address(heavy).balance, owed, "paid when it pulls its own");
        assertEq(_nativeCredit(address(heavy)), 0);
    }

    function test_native_payout_tooLittleGasRevertsTheCallInsteadOfRefusing() public {
        // A caller cannot starve a recipient into a refusal: with too little gas for the payment's full
        // allowance the whole call reverts and every Credit stays as it was.
        address[] memory one = new address[](1);
        one[0] = creator;
        uint256 owed = _nativeCredit(creator);
        vm.prank(stranger);
        vm.expectRevert(StokerHook.PayoutGasTooLow.selector);
        hook.payout{gas: 120_000}(NATIVE, one);
        assertEq(_nativeCredit(creator), owed);
        hook.payout(NATIVE, one);
        assertEq(_nativeCredit(creator), 0);
    }

    function test_native_payout_nothingOwedPaysNothing() public {
        address[] memory one = new address[](1);
        one[0] = stranger;
        uint256 claims = _nativeClaims();
        hook.payout(NATIVE, one);
        assertEq(stranger.balance, 0);
        assertEq(_nativeClaims(), claims);
    }

    function test_native_payout_duplicateOwnerPaidOnce() public {
        address[] memory twice = new address[](2);
        twice[0] = creator;
        twice[1] = creator;
        uint256 owed = _nativeCredit(creator);
        uint256 before = creator.balance;
        hook.payout(NATIVE, twice);
        assertEq(creator.balance - before, owed);
    }

    function test_native_payout_capIsPublished() public view {
        assertEq(hook.NATIVE_PAYOUT_GAS(), 50_000, "the gas a payment to someone else carries");
    }
}
