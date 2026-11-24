// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Distributor} from "../../src/Distributor.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {DistributorLocalBase} from "../utils/DistributorLocalBase.sol";

/// A Stock Token stand-in whose issuer can pause it: every transfer reverts while the pause is on, as the
/// real ones do while the token or the whole registry is paused.
contract PausableStock is ERC20 {
    error EnforcedPause();

    bool public paused;

    constructor() ERC20("Pausable Stock", "PAUSE") {}

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert EnforcedPause();
        super._update(from, to, value);
    }
}

/// An asset that delivers one unit less than it is told to move (a transfer fee), which the Listing rule
/// bars and the Distributor refuses anyway.
contract ShortStock is ERC20 {
    constructor() ERC20("Short Stock", "SHORT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && value > 0) {
            super._update(from, address(0xdead), 1);
            value -= 1;
        }
        super._update(from, to, value);
    }
}

/// An asset that refuses a transfer by returning false rather than reverting.
contract FalseStock is ERC20 {
    bool public refusing;

    constructor() ERC20("False Stock", "FALSE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRefusing(bool refusing_) external {
        refusing = refusing_;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (refusing) return false;
        return super.transfer(to, value);
    }
}

/// The Distributor (#247, ADR 0029): Round Roots posted by the round key alone, the Round Delay, the Guard's
/// cancel, claims anyone may submit that always pay the holder, each payment on its own, and a coin's
/// rounds never paying beyond that coin's own pot. The native asset's payments are in
/// `DistributorNative.t.sol`, the invariants in `test/invariant/Distributor.invariant.t.sol`.
contract DistributorTest is DistributorLocalBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    // ------------------------------------------------------------------ who may post

    function test_post_onlyTheRoundKey() public {
        _fund(coinA, stock, 100);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _build(coinA, stock, h, a);

        address ladder = makeAddr("ladderKey");
        address keeper = makeAddr("keeper");
        vm.startPrank(platform);
        keys.proposeKey(StokerKeys.Role.LadderKey, ladder);
        keys.proposeKey(StokerKeys.Role.Keeper, keeper);
        vm.stopPrank();
        vm.prank(ladder);
        keys.acceptKey(StokerKeys.Role.LadderKey);
        vm.prank(keeper);
        keys.acceptKey(StokerKeys.Role.Keeper);

        address[5] memory others = [stranger, platform, ladder, keeper, address(taxVault)];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(Distributor.NotRoundKey.selector);
            distributor.postRoot(b.round, coinA, stock, b.root, b.total);
        }
        vm.prank(roundKey);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
        assertEq(distributor.roundCount(), 1);
    }

    /// The Guard can only cancel: even an Admin that made itself the round key cannot post.
    function test_post_theGuardCannotPost_evenHoldingTheRoundKey() public {
        _fund(coinA, stock, 100);
        _setRoundKey(platform);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(platform);
        vm.expectRevert(Distributor.GuardCannotPost.selector);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
    }

    /// The round key is read at the moment of the call: a revoke stops it at once, and a replacement
    /// takes effect the moment the new holder accepts.
    function test_post_aRevokedOrReplacedRoundKeyCannotPost() public {
        _fund(coinA, stock, 300);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _build(coinA, stock, h, a);

        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.RoundKey);
        vm.prank(roundKey);
        vm.expectRevert(Distributor.NotRoundKey.selector);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);

        address next = makeAddr("nextRoundKey");
        _setRoundKey(next);
        vm.prank(roundKey);
        vm.expectRevert(Distributor.NotRoundKey.selector);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
        vm.prank(next);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);

        // Proposed but not yet accepted: the holder of the moment still posts, the proposed one cannot.
        address third = makeAddr("thirdRoundKey");
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.RoundKey, third);
        b = _build(coinA, stock, h, a);
        vm.prank(third);
        vm.expectRevert(Distributor.NotRoundKey.selector);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
        vm.prank(next);
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
    }

    function test_post_theRoundNumberIsTheNextOne() public {
        _fund(coinA, stock, 100);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.WrongRound.selector, 2, 1));
        distributor.postRoot(2, coinA, stock, b.root, b.total);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.WrongRound.selector, 0, 1));
        distributor.postRoot(0, coinA, stock, b.root, b.total);
    }

    function test_post_refusesAnEmptyRoot() public {
        _fund(coinA, stock, 100);
        vm.startPrank(roundKey);
        vm.expectRevert(Distributor.InvalidRoot.selector);
        distributor.postRoot(1, coinA, stock, bytes32(0), 100);
        vm.expectRevert(Distributor.InvalidRoot.selector);
        distributor.postRoot(1, coinA, stock, keccak256("root"), 0);
        vm.expectRevert(Distributor.InvalidRoot.selector);
        distributor.postRoot(1, address(0), stock, keccak256("root"), 100);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the pot

    /// A root can never owe more than its coin's pot holds unreserved: one beyond it is refused, one at it
    /// is taken, and once taken nothing is left for another.
    function test_pot_aRootBeyondThePotCannotBePosted() public {
        _fund(coinA, stock, 1_000);
        (address[] memory h, uint256[] memory a) = _pair(alice, 600, bob, 401);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 1_001, 1_000));
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);

        (h, a) = _pair(alice, 600, bob, 400);
        b = _post(coinA, stock, h, a);
        assertEq(distributor.availableOf(coinA, stock), 0);
        assertEq(distributor.reservedOf(coinA, stock), 1_000);

        (h, a) = _single(carol, 1);
        Built memory more = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 1, 0));
        distributor.postRoot(more.round, coinA, stock, more.root, more.total);

        // A false root's total cannot reach past what its own tree owes either: claims stop at the total.
        _warpPastDelay(b.round);
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 600);
        assertEq(IERC20(address(mockQuote)).balanceOf(bob), 400);
        assertEq(distributor.potOf(coinA, stock), 0);
    }

    /// A root for a coin with nothing in its pot pays nothing: it cannot even be posted.
    function test_pot_aCoinWithNothingInItsPotPaysNothing() public {
        (address[] memory h, uint256[] memory a) = _single(alice, 1);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 1, 0));
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
    }

    /// One coin's round never pays from another coin's pot, nor from the same coin's pot in another asset.
    function test_pot_oneCoinsRoundNeverPaysFromAnothers() public {
        _fund(coinB, stock, 1_000_000);
        _fund(coinA, Currency.wrap(coinA), 1_000_000);
        _fund(coinA, stock, 10);

        (address[] memory h, uint256[] memory a) = _single(alice, 11);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 11, 10));
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);

        (h, a) = _single(alice, 10);
        b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 10);
        assertEq(distributor.potOf(coinA, stock), 0);
        assertEq(distributor.potOf(coinB, stock), 1_000_000, "the other coin's pot is untouched");
        assertEq(distributor.potOf(coinA, Currency.wrap(coinA)), 1_000_000, "the coin's other asset is untouched");
    }

    // ------------------------------------------------------------------ the Round Delay

    function test_delay_aClaimInsideTheDelayReverts_andSucceedsAfter() public {
        _fund(coinA, stock, 100);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _post(coinA, stock, h, a);
        uint256 payableAt = block.timestamp + 24 hours;
        assertEq(_payableAt(b.round), payableAt);

        vm.warp(payableAt - 1);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundDelay.selector, b.round, payableAt));
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 0);

        vm.warp(payableAt);
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);
    }

    // ------------------------------------------------------------------ the Guard

    /// The Guard cancels inside the delay: the root's claims never pay, and what it reserved is free in
    /// the coin's pot for a root posted again.
    function test_guard_cancelsInsideTheDelay_andItsClaimsNeverPay() public {
        _fund(coinA, stock, 100);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _post(coinA, stock, h, a);

        vm.warp(block.timestamp + 23 hours);
        vm.expectEmit(address(distributor));
        emit Distributor.RootCancelled(b.round, 100);
        vm.prank(platform);
        distributor.cancelRoot(b.round);
        assertTrue(distributor.roundOf(b.round).cancelled);
        assertEq(distributor.availableOf(coinA, stock), 100, "back in the pot");
        assertEq(distributor.potOf(coinA, stock), 100);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundCancelled.selector, b.round));
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 0);

        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundCancelled.selector, b.round));
        distributor.cancelRoot(b.round);

        // The round computed and posted again pays.
        Built memory again = _post(coinA, stock, h, a);
        _warpPastDelay(again.round);
        distributor.claim(_claims(again));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);
    }

    function test_guard_cannotCancelOnceTheDelayIsOver() public {
        _fund(coinA, stock, 100);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);
        vm.prank(platform);
        vm.expectRevert(abi.encodeWithSelector(Distributor.DelayOver.selector, b.round));
        distributor.cancelRoot(b.round);
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);
    }

    /// Only the Admin of the moment cancels: not the round key, not a stranger, not a previous Admin.
    function test_guard_isTheAdminOfTheMoment_andNobodyElse() public {
        _fund(coinA, stock, 100);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory b = _post(coinA, stock, h, a);

        address[3] memory others = [roundKey, stranger, address(taxVault)];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(Distributor.NotGuard.selector);
            distributor.cancelRoot(b.round);
        }

        address nextAdmin = makeAddr("nextAdmin");
        vm.prank(platform);
        keys.proposeAdmin(nextAdmin);
        vm.prank(nextAdmin);
        keys.acceptAdmin();
        vm.prank(platform);
        vm.expectRevert(Distributor.NotGuard.selector);
        distributor.cancelRoot(b.round);
        vm.prank(nextAdmin);
        distributor.cancelRoot(b.round);

        vm.prank(nextAdmin);
        vm.expectRevert(abi.encodeWithSelector(Distributor.UnknownRound.selector, 9));
        distributor.cancelRoot(9);
    }

    // ------------------------------------------------------------------ claims

    /// Anyone submits a batch; each holder receives exactly their own amount, and the caller nothing.
    function test_claim_aStrangerPaysEachHolderTheirOwn() public {
        (address[] memory h, uint256[] memory a) = _holders("holder", 7, 1 ether);
        _fund(coinA, stock, 28 ether);
        Built memory b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);

        vm.expectEmit(address(distributor));
        emit Distributor.Claimed(b.round, h[0], stock, a[0]);
        vm.prank(stranger);
        distributor.claim(_claims(b));
        for (uint256 i; i < h.length; i++) {
            assertEq(IERC20(address(mockQuote)).balanceOf(h[i]), a[i], "each holder their own");
            assertTrue(distributor.isClaimed(b.round, h[i]));
        }
        assertEq(IERC20(address(mockQuote)).balanceOf(stranger), 0, "never the caller");
        assertEq(distributor.potOf(coinA, stock), 0);
        assertEq(distributor.reservedOf(coinA, stock), 0);
        assertEq(distributor.roundOf(b.round).paid, 28 ether);
    }

    /// A claim is paid once: again in a later batch it is passed over, and twice in one batch it is paid
    /// once, so a holder's own claim landing first cannot make the Keeper's batch revert.
    function test_claim_cannotBePaidTwice() public {
        _fund(coinA, stock, 300);
        (address[] memory h, uint256[] memory a) = _pair(alice, 100, bob, 200);
        Built memory b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);

        Distributor.Claim[] memory dup = new Distributor.Claim[](3);
        (dup[0], dup[1], dup[2]) = (_claimAt(b, 0), _claimAt(b, 0), _claimAt(b, 0));
        distributor.claim(dup);
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);

        distributor.claim(_claims(b));
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100, "alice once");
        assertEq(IERC20(address(mockQuote)).balanceOf(bob), 200, "bob once");
        assertEq(IERC20(address(mockQuote)).balanceOf(address(distributor)), 0);
        assertEq(distributor.roundOf(b.round).paid, 300);
    }

    /// A holder's claims for several rounds are paid in one call, added together in one payment.
    function test_claim_severalRoundsInOneCall_addedTogether() public {
        _fund(coinA, stock, 1_000);
        _fund(coinB, stock, 1_000);
        Built[3] memory rounds;
        (address[] memory h, uint256[] memory a) = _pair(alice, 100, bob, 1);
        rounds[0] = _post(coinA, stock, h, a);
        (h, a) = _pair(bob, 2, alice, 200);
        rounds[1] = _post(coinA, stock, h, a);
        (h, a) = _single(alice, 300);
        rounds[2] = _post(coinB, stock, h, a);
        _warpPastDelay(rounds[2].round);

        Distributor.Claim[] memory mine = new Distributor.Claim[](3);
        mine[0] = _claimAt(rounds[0], 0);
        mine[1] = _claimAt(rounds[1], 1);
        mine[2] = _claimAt(rounds[2], 0);
        vm.recordLogs();
        vm.prank(alice);
        distributor.claim(mine);
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 600);
        assertEq(_transfersTo(alice), 1, "one payment for the three rounds");
        for (uint256 i; i < 3; i++) {
            assertTrue(distributor.isClaimed(rounds[i].round, alice));
        }
        assertEq(distributor.potOf(coinA, stock), 700);
        assertEq(distributor.potOf(coinB, stock), 700);
    }

    /// A proof for any other amount, holder, round, coin, contract or chain does not verify.
    function test_claim_aProofCannotBeReplayed() public {
        _fund(coinA, stock, 1_000);
        _fund(coinB, stock, 1_000);
        (address[] memory h, uint256[] memory a) = _pair(alice, 100, bob, 200);
        Built memory b = _post(coinA, stock, h, a);
        // The same root posted again, as a second round of the same coin and as a round of another coin.
        vm.startPrank(roundKey);
        distributor.postRoot(2, coinA, stock, b.root, b.total);
        distributor.postRoot(3, coinB, stock, b.root, b.total);
        vm.stopPrank();
        _warpPastDelay(3);

        Distributor.Claim memory c = _claimAt(b, 0);
        c.amount = 101;
        _expectInvalid(c);
        c = _claimAt(b, 0);
        c.holder = bob;
        _expectInvalid(c);
        c = _claimAt(b, 0);
        c.round = 2;
        _expectInvalid(c);
        c.round = 3;
        _expectInvalid(c);

        // Another chain: the leaf carries the chain id.
        // Read through an external call: under via IR a second `block.chainid` may reuse the first (gotcha 10).
        uint256 chainId = this.chainIdNow();
        vm.chainId(chainId + 1);
        _expectInvalid(_claimAt(b, 0));
        vm.chainId(chainId);

        // Another Distributor with the same round posted: the leaf carries the contract.
        Distributor other = new Distributor(keys, address(taxVault));
        _fundAs(other, address(taxVault), coinA, stock, 300);
        vm.prank(roundKey);
        other.postRoot(1, coinA, stock, b.root, b.total);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Distributor.InvalidProof.selector, 1, alice));
        other.claim(_one(_claimAt(b, 0)));

        // The genuine claim still pays, once.
        distributor.claim(_one(_claimAt(b, 0)));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);
    }

    function test_claim_theLeafIsTheEnginesLeaf() public view {
        assertEq(distributor.leafOf(7, coinA, alice, 123), _leaf(distributor, coinA, 7, alice, 123));
    }

    function test_claim_anUnknownRoundReverts() public {
        Distributor.Claim memory c;
        c.round = 1;
        c.holder = alice;
        vm.expectRevert(abi.encodeWithSelector(Distributor.UnknownRound.selector, 1));
        distributor.claim(_one(c));
        c.round = 0;
        vm.expectRevert(abi.encodeWithSelector(Distributor.UnknownRound.selector, 0));
        distributor.claim(_one(c));
    }

    /// A round whose tree owes more than the total it was posted with (the round key's own mistake) pays
    /// up to its total and never past it.
    function test_claim_neverPastTheRoundsTotal() public {
        _fund(coinA, stock, 1_000);
        (address[] memory h, uint256[] memory a) = _pair(alice, 100, bob, 200);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        distributor.postRoot(b.round, coinA, stock, b.root, 250);
        _warpPastDelay(b.round);
        distributor.claim(_one(_claimAt(b, 1)));
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundTotalExceeded.selector, b.round));
        distributor.claim(_one(_claimAt(b, 0)));
        assertEq(distributor.roundOf(b.round).paid, 200);
        assertEq(distributor.potOf(coinA, stock), 800);
        assertEq(distributor.availableOf(coinA, stock), 750);
    }

    /// One holder the Stock Token blocks stays owed; the others in the same batch are paid; once unblocked
    /// the blocked holder is paid, once.
    function test_claim_aBlockedHolderStaysOwed_andTheOthersArePaid() public {
        (address[] memory h, uint256[] memory a) = _holders("holder", 5, 10);
        _fund(coinA, stock, 150);
        Built memory b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);
        mockQuote.setBlocked(h[2], true);

        vm.expectEmit(address(distributor));
        emit Distributor.ClaimRefused(b.round, h[2], stock, a[2]);
        vm.prank(stranger);
        distributor.claim(_claims(b));
        for (uint256 i; i < h.length; i++) {
            assertEq(IERC20(address(mockQuote)).balanceOf(h[i]), i == 2 ? 0 : a[i]);
        }
        assertFalse(distributor.isClaimed(b.round, h[2]), "still owed");
        assertEq(distributor.potOf(coinA, stock), a[2]);
        assertEq(distributor.reservedOf(coinA, stock), a[2]);

        mockQuote.setBlocked(h[2], false);
        distributor.claim(_claims(b));
        assertEq(IERC20(address(mockQuote)).balanceOf(h[2]), a[2]);
        assertEq(distributor.potOf(coinA, stock), 0);
    }

    /// While the issuer's pause is on nothing is paid and every holder stays owed; after it, all are paid.
    function test_claim_nothingIsPaidWhileTheIssuersPauseIsOn() public {
        PausableStock p = new PausableStock();
        Currency asset = Currency.wrap(address(p));
        (address[] memory h, uint256[] memory a) = _holders("holder", 3, 10);
        _fund(coinA, asset, 60);
        Built memory b = _post(coinA, asset, h, a);
        _warpPastDelay(b.round);

        p.setPaused(true);
        distributor.claim(_claims(b));
        for (uint256 i; i < h.length; i++) {
            assertEq(p.balanceOf(h[i]), 0);
            assertFalse(distributor.isClaimed(b.round, h[i]));
        }
        assertEq(distributor.potOf(coinA, asset), 60);

        p.setPaused(false);
        distributor.claim(_claims(b));
        for (uint256 i; i < h.length; i++) {
            assertEq(p.balanceOf(h[i]), a[i]);
        }
    }

    /// A refused merged payment leaves every round in it owed, and pays them all once accepted.
    function test_claim_aRefusedMergedPaymentLeavesEveryRoundOwed() public {
        _fund(coinA, stock, 300);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory r1 = _post(coinA, stock, h, a);
        (h, a) = _single(alice, 200);
        Built memory r2 = _post(coinA, stock, h, a);
        _warpPastDelay(r2.round);
        Distributor.Claim[] memory both = new Distributor.Claim[](2);
        (both[0], both[1]) = (_claimAt(r1, 0), _claimAt(r2, 0));

        mockQuote.setBlocked(alice, true);
        distributor.claim(both);
        assertFalse(distributor.isClaimed(r1.round, alice));
        assertFalse(distributor.isClaimed(r2.round, alice));
        assertEq(distributor.roundOf(r1.round).paid, 0);
        assertEq(distributor.roundOf(r2.round).paid, 0);
        assertEq(distributor.reservedOf(coinA, stock), 300);

        mockQuote.setBlocked(alice, false);
        distributor.claim(both);
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 300);
    }

    /// A holder's claims in two assets, side by side in one batch, are paid each in its own asset and
    /// never added together.
    function test_claim_aHoldersClaimsInTwoAssetsArePaidApart() public {
        Currency eth = Currency.wrap(address(0));
        _fund(coinA, stock, 100);
        _fund(coinA, eth, 1 ether);
        (address[] memory h, uint256[] memory a) = _single(alice, 100);
        Built memory inStock = _post(coinA, stock, h, a);
        (h, a) = _single(alice, 1 ether);
        Built memory inEth = _post(coinA, eth, h, a);
        _warpPastDelay(inEth.round);
        Distributor.Claim[] memory both = new Distributor.Claim[](2);
        (both[0], both[1]) = (_claimAt(inStock, 0), _claimAt(inEth, 0));
        distributor.claim(both);
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);
        assertEq(alice.balance, 1 ether);
        assertEq(distributor.potOf(coinA, stock), 0);
        assertEq(distributor.potOf(coinA, eth), 0);
    }

    /// An asset that answers a transfer with false has refused it: the holder stays owed, and is paid once
    /// it is accepted.
    function test_claim_anAssetReturningFalseLeavesTheHolderOwed() public {
        FalseStock f = new FalseStock();
        Currency asset = Currency.wrap(address(f));
        _fund(coinA, asset, 100);
        (address[] memory h, uint256[] memory a) = _pair(alice, 40, bob, 60);
        Built memory b = _post(coinA, asset, h, a);
        _warpPastDelay(b.round);
        f.setRefusing(true);
        distributor.claim(_claims(b));
        assertEq(f.balanceOf(alice), 0);
        assertFalse(distributor.isClaimed(b.round, alice));
        assertEq(distributor.potOf(coinA, asset), 100);
        f.setRefusing(false);
        distributor.claim(_claims(b));
        assertEq(f.balanceOf(alice), 40);
        assertEq(f.balanceOf(bob), 60);
    }

    /// A round may pay in the coin itself (a Payout Asset of the coin), from that coin's own pot of coins.
    function test_claim_aRoundPaidInTheCoin() public {
        Currency coinAsset = Currency.wrap(coinA);
        _fund(coinA, coinAsset, 5e18);
        (address[] memory h, uint256[] memory a) = _pair(alice, 2e18, bob, 3e18);
        Built memory b = _post(coinA, coinAsset, h, a);
        _warpPastDelay(b.round);
        distributor.claim(_claims(b));
        assertEq(IERC20(coinA).balanceOf(alice), 2e18);
        assertEq(IERC20(coinA).balanceOf(bob), 3e18);
    }

    // ------------------------------------------------------------------ deposits

    function test_deposit_onlyTheTaxVault() public {
        deal(address(mockQuote), stranger, 100);
        vm.startPrank(stranger);
        IERC20(address(mockQuote)).approve(address(distributor), 100);
        vm.expectRevert(Distributor.NotTaxVault.selector);
        distributor.deposit(coinA, stock, 100);
        vm.deal(stranger, 1 ether);
        vm.expectRevert(Distributor.NotTaxVault.selector);
        distributor.deposit{value: 1 ether}(coinA, Currency.wrap(address(0)), 1 ether);
        vm.stopPrank();
        assertEq(distributor.potOf(coinA, stock), 0);
    }

    function test_deposit_raisesThatCoinsPotAlone() public {
        deal(address(mockQuote), address(taxVault), 70);
        vm.startPrank(address(taxVault));
        IERC20(address(mockQuote)).approve(address(distributor), 70);
        vm.expectEmit(address(distributor));
        emit Distributor.Deposited(coinA, stock, 70);
        distributor.deposit(coinA, stock, 70);
        vm.stopPrank();
        assertEq(distributor.potOf(coinA, stock), 70);
        assertEq(distributor.potOf(coinB, stock), 0);
        assertEq(IERC20(address(mockQuote)).balanceOf(address(distributor)), 70);
        assertEq(IERC20(address(mockQuote)).allowance(address(taxVault), address(distributor)), 0);
    }

    function test_deposit_theValueMustBeTheNativeAmountExactly() public {
        Currency native = Currency.wrap(address(0));
        vm.deal(address(taxVault), 10 ether);
        vm.startPrank(address(taxVault));
        vm.expectRevert(abi.encodeWithSelector(Distributor.ValueMismatch.selector, 2 ether, 1 ether));
        distributor.deposit{value: 1 ether}(coinA, native, 2 ether);
        vm.expectRevert(abi.encodeWithSelector(Distributor.ValueMismatch.selector, 0, 1 ether));
        distributor.deposit{value: 1 ether}(coinA, stock, 0);
        distributor.deposit{value: 1 ether}(coinA, native, 1 ether);
        vm.stopPrank();
        assertEq(distributor.potOf(coinA, native), 1 ether);
        assertEq(address(distributor).balance, 1 ether);
    }

    /// An asset that delivers less than the amount is refused, so a pot never counts more than it holds.
    function test_deposit_aShortTransferIsRefused() public {
        ShortStock s = new ShortStock();
        s.mint(address(taxVault), 100);
        vm.startPrank(address(taxVault));
        s.approve(address(distributor), 100);
        vm.expectRevert(Distributor.DepositShort.selector);
        distributor.deposit(coinA, Currency.wrap(address(s)), 100);
        vm.stopPrank();
    }

    function test_deposit_plainValueIsRefused() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(distributor).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------ helpers

    function chainIdNow() external view returns (uint256) {
        return block.chainid;
    }

    function _expectInvalid(Distributor.Claim memory c) internal {
        vm.expectRevert(abi.encodeWithSelector(Distributor.InvalidProof.selector, c.round, c.holder));
        distributor.claim(_one(c));
    }

    function _transfersTo(address who) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].topics.length == 3 && logs[i].topics[0] == sig
                    && address(uint160(uint256(logs[i].topics[2]))) == who
            ) {
                n++;
            }
        }
    }
}
