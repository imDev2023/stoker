// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BooksHandler, BooksInvariantBase, BooksInvariantTest, NativeBooksInvariantTest} from "./Books.invariant.t.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";

/// What the ladder's handler reads of the campaign's coin, beside the books' own window.
interface ILadderWindow {
    function hookAddr() external view returns (address);
    function poolId() external view returns (PoolId);
    function tierNow() external view returns (uint8);
    function shareNow() external view returns (uint16);
    function creditedNow() external view returns (uint256);
    function graduated() external view returns (bool);
    function crossingAmount() external view returns (uint256);
}

/// The books' handler with the Creator Ladder's key added (#248): beside every trade, Payout Call, refusal
/// and privileged call of the books' campaigns, a buy crosses the coin's Graduation Target and a later call
/// records Graduation once the hour has run, the ladder key of the moment raises the coin's tier (or asks
/// for a tier it may not have, or for any tier before Graduation), everyone else tries to, and trades are
/// measured against the share of the tier the coin holds when they are made.
contract LadderHandler is BooksHandler {
    ILadderWindow internal immutable w;

    uint8 public lastTier = 1; // the tier the handler last saw
    uint256 public raises; // raises that went through
    uint256 public tierFalls; // a tier seen lower than one seen before
    uint256 public unauthorizedRaises; // a raise by anyone but the ladder key of the moment
    uint256 public wrongRaises; // a raise the key should have been refused, or a refusal it should not
    uint256 public raisesBeforeGraduation; // a tier that moved while the coin had not graduated
    uint256 public graduations; // calls that recorded the coin's Graduation
    uint256 public creditedMoves; // a raise, tried or made, after which the coin's book of Creator Credits differed
    uint256 public tieredSwaps; // swaps measured against their tier's share
    uint256 public shareMismatches; // such a swap whose Creator's Credit was not the tier's share of the fee
    uint256[4] public swapsAtTier;

    constructor(BooksInvariantBase t_, PoolKey memory key_) BooksHandler(t_, key_) {
        w = ILadderWindow(address(t_));
    }

    /// A buy across the coin's Graduation Target, counted with the books' own trades. The hold then runs,
    /// unless a later sell leaves the price under the target again.
    function crossTarget(uint256 actorSeed) external {
        _trade(actorSeed, true, true, w.crossingAmount(), 0, 0);
    }

    /// An hour on, the call anyone can make records Graduation if the price has stood. Each handler call is a
    /// transaction of its own, as the hold needs: the crossing buy and this call are never one.
    function recordGraduation() external {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        try StokerHook(payable(w.hookAddr())).graduate(w.poolId()) {
            graduations++;
        } catch {}
    }

    /// The ladder key of the moment asks for a tier from 0 to 4: one above the coin's goes through once the
    /// coin has graduated, and any other, and every one before Graduation, is refused. Counted with the
    /// privileged calls, which must move nothing but the tier.
    function raise(uint8 tier) external {
        address holder = t.holderOf(StokerKeys.Role.LadderKey);
        if (holder == address(0)) return;
        tier = uint8(bound(tier, 0, 4));
        uint8 before = w.tierNow();
        uint256 credited = w.creditedNow();
        bool graduated = w.graduated();
        _privileged(holder, w.hookAddr(), abi.encodeCall(StokerHook.raiseTier, (w.poolId(), tier)));
        if (!graduated && w.tierNow() != before) raisesBeforeGraduation++;
        bool allowed = graduated && holder != t.currentAdmin() && tier > before && tier <= 3;
        if (allowed ? w.tierNow() != tier : w.tierNow() != before) wrongRaises++;
        _note(before, credited);
    }

    /// Anyone else tries: an actor (who may hold another server key, or have held this one), or the Admin.
    function othersRaise(uint256 whoSeed, uint8 tier) external {
        address who = whoSeed % 5 == 4 ? t.currentAdmin() : actors[whoSeed % actors.length];
        bool isKey = who == t.holderOf(StokerKeys.Role.LadderKey);
        tier = uint8(bound(tier, 0, 4));
        uint8 before = w.tierNow();
        uint256 credited = w.creditedNow();
        bool graduated = w.graduated();
        _privileged(who, w.hookAddr(), abi.encodeCall(StokerHook.raiseTier, (w.poolId(), tier)));
        if (w.tierNow() != before && !isKey) unauthorizedRaises++;
        if (w.tierNow() != before && (!graduated || who == t.currentAdmin())) raisesBeforeGraduation++;
        _note(before, credited);
    }

    function _note(uint8 before, uint256 credited) internal {
        uint8 tier = w.tierNow();
        if (tier < before || tier < lastTier) tierFalls++;
        if (tier > before) raises++;
        if (w.creditedNow() != credited) creditedMoves++;
        lastTier = tier;
    }

    /// A trade naming no referrer, measured against the tier the coin holds: the Creator's Credit grows by the
    /// tier's share of the fee, the platform's by the rest, and the coin's own book by the Creator's part.
    function tradeAtTier(uint256 actorSeed, bool buy, bool exactIn, uint256 amount) external {
        address owner = t.creditOwner();
        address admin = t.currentAdmin();
        uint256 claims = t.hookClaims();
        uint256 creatorBefore = t.creditOf(owner);
        uint256 platformBefore = t.creditOf(admin);
        uint256 credited = w.creditedNow();
        uint16 share = w.shareNow();
        _trade(actorSeed, buy, exactIn, amount, 0, 0);
        uint256 taken = t.hookClaims() - claims;
        if (taken == 0) return; // the swap did not go through
        tieredSwaps++;
        swapsAtTier[w.tierNow()]++;
        uint256 creatorCredit = t.creditOf(owner) - creatorBefore;
        if (
            creatorCredit != taken * share / 10_000 || t.creditOf(admin) - platformBefore != taken - creatorCredit
                || w.creditedNow() - credited != creatorCredit
        ) shareMismatches++;
    }
}

/// The ladder's invariants, over either of the books' campaigns (#248): a coin's tier never falls; nobody
/// but the ladder key of the moment raises it, never the Admin and never before the coin has graduated, and
/// it raises only upward and only to the top; the Credits of
/// every swap still sum to the fee taken at every tier (the books' own invariant, now with raises among the
/// calls), the Creator's part being the tier's share; and no raise, tried or made, touches a pool, a Seed
/// Position, a Credit or the coin's terms (the books' own invariant, with the raise among the privileged
/// calls) or the coin's own book of Creator Credits.
abstract contract LadderInvariants is BooksInvariantBase {
    LadderHandler internal ladder;

    function setUp() public virtual override {
        super.setUp();
        excludeContract(address(handler));
        ladder = new LadderHandler(this, key);
        handler = ladder;
        targetContract(address(ladder));
        // A ladder key from the start, so raises begin before the campaign replaces it.
        address first = makeAddr("firstLadderKey");
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.LadderKey, first);
        vm.prank(first);
        keys.acceptKey(StokerKeys.Role.LadderKey);
    }

    function hookAddr() external view returns (address) {
        return address(hook);
    }

    function poolId() external view returns (PoolId) {
        return key.toId();
    }

    function tierNow() external view returns (uint8) {
        return hook.creatorTierOf(key.toId());
    }

    function shareNow() external view returns (uint16) {
        return hook.creatorShareOf(key.toId());
    }

    function creditedNow() external view returns (uint256) {
        return hook.creatorCreditedOf(key.toId());
    }

    function graduated() external view returns (bool) {
        return hook.graduationOf(key.toId()).graduatedAt != 0;
    }

    /// A buy that carries the coin across its Graduation Target with room to spare, under the handler's own
    /// bound on a trade.
    function crossingAmount() external view returns (uint256) {
        return 120 * quoteUnit();
    }

    function invariant_aCoinsTierNeverFalls() public view {
        assertEq(ladder.tierFalls(), 0, "a tier fell");
        uint8 tier = hook.creatorTierOf(key.toId());
        assertEq(tier, ladder.lastTier(), "the tier moved outside a raise");
        assertGe(tier, 1);
        assertLe(tier, 3, "past the top");
    }

    function invariant_onlyTheLadderKeyRaises_andOnlyUpward() public view {
        assertEq(ladder.unauthorizedRaises(), 0, "a raise by another caller");
        assertEq(ladder.raisesBeforeGraduation(), 0, "a raise before Graduation, or by the Admin");
        if (hook.graduationOf(key.toId()).graduatedAt == 0) {
            assertEq(hook.creatorTierOf(key.toId()), 1, "a coin that has not graduated holds the first tier");
        }
        assertEq(ladder.wrongRaises(), 0, "a raise the key may not make, or a refusal of one it may");
    }

    function invariant_theCreatorIsCreditedItsTiersShare() public view {
        assertEq(ladder.shareMismatches(), 0, "a Credit that was not its tier's share of the fee");
        uint16 share = hook.creatorShareOf(key.toId());
        uint8 tier = hook.creatorTierOf(key.toId());
        assertEq(share, tier == 1 ? CREATOR_SHARE_BPS : tier == 2 ? SECOND_TIER_SHARE_BPS : TOP_TIER_SHARE_BPS);
    }

    function invariant_aRaiseMovesNoCredit() public view {
        assertEq(ladder.creditedMoves(), 0, "a raise moved the coin's book of Creator Credits");
    }
}

/// The ladder over a coin paired with an ERC-20, its Creator blocked at times.
contract LadderBooksInvariantTest is BooksInvariantTest, LadderInvariants {
    function setUp() public override(BooksInvariantBase, LadderInvariants) {
        LadderInvariants.setUp();
    }

    /// The handler does what the campaign relies on: driven by hand it is refused before Graduation, crosses
    /// the target, records Graduation, raises, refuses, and measures swaps on every tier, so the invariants
    /// above are not held by a handler that never reaches a raise. Every call here is a transaction of its
    /// own, as each handler call of a campaign is.
    /// forge-config: default.isolate = true
    function test_ladderCampaign_theHandlerRaisesAndMeasuresAtEveryTier() public {
        ladder.tradeAtTier(0, true, true, 5 ether);
        ladder.raise(2);
        ladder.raise(3);
        assertEq(ladder.raises(), 0, "no raise before Graduation");
        ladder.crossTarget(1);
        ladder.recordGraduation();
        assertEq(ladder.graduations(), 1, "the hold ran and Graduation was recorded");
        ladder.othersRaise(0, 2);
        ladder.othersRaise(4, 3);
        assertEq(hook.creatorTierOf(key.toId()), 1, "nobody else raised it");
        ladder.raise(0);
        ladder.raise(1);
        ladder.raise(4);
        assertEq(ladder.raises(), 0, "the key was refused what it may not have");
        ladder.raise(2);
        ladder.tradeAtTier(1, true, true, 5 ether);
        ladder.raise(1);
        ladder.raise(3);
        ladder.tradeAtTier(1, false, true, 1e9 ether);
        ladder.raise(2);
        assertEq(ladder.raises(), 2);
        assertEq(ladder.lastTier(), 3);
        assertEq(ladder.swapsAtTier(1), 1);
        assertEq(ladder.swapsAtTier(2), 1);
        assertEq(ladder.swapsAtTier(3), 1);
        assertEq(ladder.tieredSwaps(), 3);
        assertGt(ladder.privilegedCalls(), 0);
        invariant_aCoinsTierNeverFalls();
        invariant_onlyTheLadderKeyRaises_andOnlyUpward();
        invariant_theCreatorIsCreditedItsTiersShare();
        invariant_aRaiseMovesNoCredit();
        invariant_noPrivilegedCallTouchesAPoolASeedOrACredit();
        invariant_creditsOfEverySwapSumToTheFeeTaken();
    }
}

/// The ladder over a coin paired with the native asset, its Creator's Destination refusing at times.
contract NativeLadderBooksInvariantTest is NativeBooksInvariantTest, LadderInvariants {
    function setUp() public override(BooksInvariantBase, LadderInvariants) {
        LadderInvariants.setUp();
    }
}
