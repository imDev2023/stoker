// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LadderTestBase} from "./Ladder.t.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";

/// The ladder key treated as stolen (#248). It sits on a server (ADR 0030), so its worst case is what
/// matters: a thief can raise every coin to the top tier, one call a coin, and can do nothing else. What
/// that costs is the platform's part of the Platform Fee on the coins raised, from 50% of it to 30%, paid to
/// those coins' Creators from then on; no trader pays more, no Credit already booked moves, and nothing
/// reaches a pool. The Admin's revoke stops the key at once, so the loss is bounded to the coins that
/// existed and were raised before it: a raise is never undone, by anyone.
contract LadderHostileTest is LadderTestBase {
    function test_hostile_aStolenLadderKeyRaisesEveryCoin_andNothingElse_andTheRevokeBoundsIt() public {
        address thief = ladderKey; // the key itself, in the wrong hands
        uint256 coins = 12;
        PoolKey[] memory keys_ = new PoolKey[](coins);
        bytes32[] memory before = new bytes32[](coins);
        for (uint256 i; i < coins; i++) {
            keys_[i] = _coin(i % 3);
            _churn(keys_[i], 1);
        }
        // Once every coin has traded: Credits are booked by address and asset, across coins.
        for (uint256 i; i < coins; i++) {
            before[i] = _everythingButTheTier(keys_[i]);
        }
        uint256 thiefQuote = quote.balanceOf(thief);
        uint256 thiefNative = thief.balance;

        // All but the last two, raised to the top in one call each.
        for (uint256 i; i < coins - 2; i++) {
            vm.prank(thief);
            hook.raiseTier(keys_[i].toId(), 3);
        }
        // Nothing but the tier moved, on any coin: no pool, no Seed Position, no Credit, no terms.
        for (uint256 i; i < coins; i++) {
            assertEq(_everythingButTheTier(keys_[i]), before[i], "only the tier");
        }
        assertEq(quote.balanceOf(thief), thiefQuote, "the key reaches no funds");
        assertEq(thief.balance, thiefNative);

        // The Admin revokes: the key stops at once, and the two coins it had not reached stay on the first.
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.LadderKey);
        for (uint256 i; i < coins; i++) {
            vm.prank(thief);
            vm.expectRevert(StokerHook.NotLadderKey.selector);
            hook.raiseTier(keys_[i].toId(), 3);
        }
        PoolKey memory later = _coin(0);
        vm.prank(thief);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(later.toId(), 2);
        assertEq(hook.creatorTierOf(keys_[coins - 1].toId()), 1);
        assertEq(hook.creatorTierOf(keys_[coins - 2].toId()), 1);
        assertEq(hook.creatorTierOf(later.toId()), 1);

        // What it cost: on a raised coin the platform's part of each later fee is 30% and no longer 50%, and
        // the trader pays what they paid before. On a coin it did not reach, nothing changed.
        // Two coins of the same pool kind, one raised and one it had not reached.
        Measured memory raised = _measured(keys_[coins - 2 - 3], 0);
        assertEq(raised.platformCredit, raised.taken - raised.taken * TOP_TIER_SHARE_BPS / 10_000);
        assertEq(raised.platformCredit * 10, raised.taken * 3, "30% of the fee, where it was 50%");
        Measured memory untouched = _measured(keys_[coins - 2], 0);
        assertEq(untouched.platformCredit, untouched.taken - untouched.taken * CREATOR_SHARE_BPS / 10_000);
        assertEq(raised.taken, untouched.taken, "the same fee on the same buy, raised or not");

        // A raise is never undone: not by a new key the Admin appoints, and the Admin has no call of its own.
        address fresh = makeAddr("freshLadderKey");
        _setKey(StokerKeys.Role.LadderKey, fresh);
        vm.prank(fresh);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.InvalidTier.selector, uint8(3), uint8(1)));
        hook.raiseTier(keys_[0].toId(), 1);
        vm.prank(platform);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(keys_[0].toId(), 1);
        assertEq(hook.creatorTierOf(keys_[0].toId()), 3);
        // The new key works at once on the coins the thief had not reached.
        vm.prank(fresh);
        hook.raiseTier(later.toId(), 2);
        assertEq(hook.creatorTierOf(later.toId()), 2);
    }
}
