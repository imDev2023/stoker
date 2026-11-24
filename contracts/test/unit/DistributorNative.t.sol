// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {Distributor} from "../../src/Distributor.sol";
import {DistributorLocalBase} from "../utils/DistributorLocalBase.sol";
import {
    RevertingRecipient,
    GasBurningRecipient,
    ReturnBombRecipient,
    ExactingRecipient,
    CountingRecipient
} from "../utils/Recipients.sol";
import {ReentrantClaimRecipient, HeavyHolder, SwitchableHolder} from "../utils/ClaimRecipients.sol";

/// A round in the native asset (#247): paid as the hook pays native Credits (#242), by a gas-capped call
/// that copies no return data, behind a guard on re-entry, with a floor that reverts the whole batch
/// rather than starve a holder, a refusal kept owed, and all the gas forwarded only to a holder claiming
/// for themselves. Every batch here is sent with a Keeper's 1,000,000 gas, since Foundry's near-unlimited
/// test gas would hide a holder that burns the batch's.
contract DistributorNativeTest is DistributorLocalBase {
    Currency internal constant ETH = Currency.wrap(address(0));
    uint256 internal constant KEEPER_GAS = 1_000_000;

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    /// Ordinary holders are paid while holders that revert, burn their gas, return a bomb or re-enter
    /// stay owed, each refusal an event, all in one batch under the Keeper's gas.
    function test_native_hostileHoldersStayOwed_theOthersArePaid() public {
        CountingRecipient wallet = new CountingRecipient();
        ReentrantClaimRecipient reentrant = new ReentrantClaimRecipient(distributor, false);
        address[] memory h = new address[](6);
        (h[0], h[1], h[2], h[3], h[4], h[5]) =
        (
            alice,
            address(new RevertingRecipient()),
            address(new GasBurningRecipient()),
            address(new ReturnBombRecipient()),
            address(reentrant),
            address(wallet)
        );
        uint256[] memory a = new uint256[](6);
        for (uint256 i; i < 6; i++) {
            a[i] = (i + 1) * 1 ether;
        }
        _fund(coinA, ETH, 21 ether);
        Built memory b = _post(coinA, ETH, h, a);
        reentrant.arm(_claimAt(b, 4));
        _warpPastDelay(b.round);

        for (uint256 i = 1; i <= 4; i++) {
            vm.expectEmit(address(distributor));
            emit Distributor.ClaimRefused(b.round, h[i], ETH, a[i]);
        }
        vm.prank(keeper);
        distributor.claim{gas: KEEPER_GAS}(_claims(b));

        assertEq(alice.balance, 1 ether);
        assertEq(wallet.received(), 6 ether);
        for (uint256 i = 1; i <= 4; i++) {
            assertEq(h[i].balance, 0, "refused");
            assertFalse(distributor.isClaimed(b.round, h[i]), "still owed");
        }
        assertEq(keeper.balance, 0, "never the caller");
        assertEq(distributor.potOf(coinA, ETH), 14 ether);
        assertEq(address(distributor).balance, 14 ether, "the refused amounts stay, backing the pot");
    }

    /// A lenient re-entrant records that its second claim met the guard, accepts, and is paid once.
    function test_native_reentryMeetsTheGuard_andIsPaidOnce() public {
        ReentrantClaimRecipient lenient = new ReentrantClaimRecipient(distributor, true);
        (address[] memory h, uint256[] memory a) = _single(address(lenient), 1 ether);
        _fund(coinA, ETH, 1 ether);
        Built memory b = _post(coinA, ETH, h, a);
        lenient.arm(_claimAt(b, 0));
        _warpPastDelay(b.round);
        distributor.claim{gas: KEEPER_GAS}(_claims(b));
        assertEq(lenient.met(), Distributor.ClaimReentered.selector);
        assertEq(address(lenient).balance, 1 ether);
        assertTrue(distributor.isClaimed(b.round, address(lenient)));
    }

    /// A refused holder is paid once it accepts.
    function test_native_aRefusedHolderIsPaidOnceItAccepts() public {
        SwitchableHolder holder = new SwitchableHolder();
        (address[] memory h, uint256[] memory a) = _single(address(holder), 1 ether);
        _fund(coinA, ETH, 1 ether);
        Built memory b = _post(coinA, ETH, h, a);
        _warpPastDelay(b.round);
        distributor.claim{gas: KEEPER_GAS}(_claims(b));
        assertEq(address(holder).balance, 0);
        holder.accept();
        distributor.claim{gas: KEEPER_GAS}(_claims(b));
        assertEq(address(holder).balance, 1 ether);
        assertEq(address(distributor).balance, 0);
    }

    /// A wallet that needs more gas than a pushed payment carries is refused when pushed and paid in full
    /// when it claims for itself, with all the gas it brings.
    function test_native_aHeavyWalletIsPaidWhenItClaimsItsOwn() public {
        HeavyHolder heavy = new HeavyHolder();
        (address[] memory h, uint256[] memory a) = _single(address(heavy), 1 ether);
        _fund(coinA, ETH, 1 ether);
        Built memory b = _post(coinA, ETH, h, a);
        _warpPastDelay(b.round);
        vm.prank(keeper);
        distributor.claim{gas: KEEPER_GAS}(_claims(b));
        assertEq(address(heavy).balance, 0, "pushed: refused");
        heavy.claimOwn{gas: KEEPER_GAS}(distributor, _claims(b));
        assertEq(address(heavy).balance, 1 ether, "its own claim: paid");
    }

    /// A caller that brings too little gas for a payment's full allowance reverts the whole batch rather
    /// than starve a holder into a refusal; every claim stays as it was.
    function test_native_tooLittleGasRevertsTheWholeBatch() public {
        (address[] memory h, uint256[] memory a) = _holders("holder", 3, 1 ether);
        _fund(coinA, ETH, 6 ether);
        Built memory b = _post(coinA, ETH, h, a);
        _warpPastDelay(b.round);
        Distributor.Claim[] memory c = _claims(b);
        vm.prank(keeper);
        vm.expectRevert(Distributor.ClaimGasTooLow.selector);
        distributor.claim{gas: 90_000}(c);
        for (uint256 i; i < h.length; i++) {
            assertEq(h[i].balance, 0);
            assertFalse(distributor.isClaimed(b.round, h[i]));
        }
        assertEq(distributor.potOf(coinA, ETH), 6 ether);
    }

    /// Across every gas budget around the floor, a holder that needs the whole allowance a pushed payment
    /// carries is either paid in full or the call reverts whole: no budget starves it into a refusal.
    function test_native_noGasBudgetStarvesAHolderIntoARefusal() public {
        // What a pushed payment carries, less what the receive's first opcodes spend before it reads gas.
        ExactingRecipient exacting = new ExactingRecipient(distributor.NATIVE_CLAIM_GAS() - 200);
        (address[] memory h, uint256[] memory a) = _single(address(exacting), 1 ether);
        _fund(coinA, ETH, 1 ether);
        Built memory b = _post(coinA, ETH, h, a);
        _warpPastDelay(b.round);
        Distributor.Claim[] memory c = _claims(b);

        uint256 paidAt;
        for (uint256 g = 60_000; g < 200_000; g += 500) {
            uint256 snap = vm.snapshotState();
            vm.prank(keeper);
            try distributor.claim{gas: g}(c) {
                assertTrue(distributor.isClaimed(b.round, address(exacting)), "starved into a refusal");
                assertEq(address(exacting).balance, 1 ether);
                if (paidAt == 0) paidAt = g;
            } catch (bytes memory reason) {
                assertEq(bytes4(reason), Distributor.ClaimGasTooLow.selector, "reverts by name");
            }
            vm.revertToState(snap);
        }
        assertGt(paidAt, 0, "some budget pays");
    }

    /// The same holder twice in one batch is paid once.
    function test_native_duplicatesArePaidOnce() public {
        (address[] memory h, uint256[] memory a) = _single(alice, 1 ether);
        _fund(coinA, ETH, 2 ether);
        Built memory b = _post(coinA, ETH, h, a);
        _warpPastDelay(b.round);
        Distributor.Claim[] memory c = new Distributor.Claim[](2);
        (c[0], c[1]) = (_claimAt(b, 0), _claimAt(b, 0));
        distributor.claim{gas: KEEPER_GAS}(c);
        distributor.claim{gas: KEEPER_GAS}(c);
        assertEq(alice.balance, 1 ether);
        assertEq(address(distributor).balance, 1 ether);
    }
}
