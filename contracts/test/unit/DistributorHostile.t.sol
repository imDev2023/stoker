// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Distributor} from "../../src/Distributor.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {DistributorLocalBase} from "../utils/DistributorLocalBase.sol";

/// An asset whose `transferFrom` says yes and moves nothing while it lies.
contract LyingStock is ERC20 {
    bool public lying;

    constructor() ERC20("Lying Stock", "LIE") {}

    function setLying(bool lying_) external {
        lying = lying_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (lying) return true;
        return super.transferFrom(from, to, value);
    }
}

/// An asset whose transfers are expensive (each writes six fresh storage slots), standing in for a Stock
/// Token whose compliance checks cost more gas than a plain ERC-20's.
contract HeavyStock is ERC20 {
    uint256 internal constant SLOTS = 6;
    uint256 internal _nonce;
    mapping(uint256 => uint256) internal _scratch;

    constructor() ERC20("Heavy Stock", "HEAVY") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0)) {
            uint256 n = _nonce;
            for (uint256 i; i < SLOTS; i++) {
                _scratch[n + i] = 1;
            }
            _nonce = n + SLOTS;
        }
        super._update(from, to, value);
    }
}

/// The Distributor against a stolen round key and hostile assets and callers (#247), from the independent
/// review of PR #270: the Guard stops every false root a stolen key posted in one call, a false root cannot
/// take another round's reservation, nothing but a deposit raises a pot, and no caller's gas budget makes a
/// payment look refused.
contract DistributorHostileTest is DistributorLocalBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal thief = makeAddr("thief");

    // ------------------------------------------------------------------ a stolen round key

    /// A stolen round key posts one false root for every Reward Launch's pot, each taking it whole and
    /// paying the thief. The Admin revokes the key and the Guard cancels them all in one call: two
    /// signatures, whatever the number of Launches, and none of them ever pays.
    function test_hostile_theGuardStopsAStolenKeysRootsInOneCall() public {
        uint256 n = 300;
        _setRoundKey(thief);
        uint256 first = distributor.roundCount() + 1;
        address[] memory coins = new address[](n);
        for (uint256 i; i < n; i++) {
            coins[i] = makeAddr(string.concat("rewardLaunch", vm.toString(i)));
            _postFalseRoot(coins[i]);
        }
        uint256 last = distributor.roundCount();

        // The alarm fires late in the delay: the Admin revokes the key, then the Guard cancels the range.
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.RoundKey);
        vm.cool(address(distributor));
        vm.cool(address(keys));
        vm.prank(platform);
        uint256 cancelled = distributor.cancelRoots(first, last);
        Vm.Gas memory g = vm.lastCallGas();
        assertEq(cancelled, n);
        emit log_named_uint("gas per round cancelled, of 300 in one call", g.gasTotalUsed / n);
        // Each cancel writes its pot's available figure back from zero, a false root having reserved it all:
        // about 34,000 a round, so 300 take about 10M gas and some 900 fit Arbitrum's 32M a transaction.
        // Bounded so a dearer cancel fails here.
        assertLt(g.gasTotalUsed / n, 40_000);

        vm.warp(vm.getBlockTimestamp() + 30 days);
        for (uint256 i; i < n; i++) {
            assertTrue(distributor.roundOf(first + i).cancelled);
            (address[] memory h, uint256[] memory a) = _single(thief, 1e18);
            Built memory b = _buildFor(distributor, first + i, coins[i], stock, h, a);
            vm.expectRevert(abi.encodeWithSelector(Distributor.RoundCancelled.selector, first + i));
            distributor.claim(_claims(b));
            assertEq(distributor.availableOf(coins[i], stock), 1e18, "the pot is whole and free again");
        }
        assertEq(IERC20(address(mockQuote)).balanceOf(thief), 0);
    }

    /// The range cancel passes over a round already cancelled and a round past its delay instead of
    /// reverting, so one stale round never blocks the rest; it cancels only inside the delay, and the
    /// round past it pays as posted.
    function test_hostile_aRangeCancelPassesOverStaleRounds() public {
        address coin0 = makeAddr("c0");
        _postFalseRoot(coin0); // round 1, which will be past its delay
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        address coin1 = makeAddr("c1");
        address coin2 = makeAddr("c2");
        address coin3 = makeAddr("c3");
        _postFalseRoot(coin1); // round 2, cancelled one by one first
        _postFalseRoot(coin2); // round 3
        _postFalseRoot(coin3); // round 4
        vm.prank(platform);
        distributor.cancelRoot(2);
        vm.warp(vm.getBlockTimestamp() + 13 hours); // round 1 is past its delay; 3 and 4 are not

        vm.prank(platform);
        uint256 cancelled = distributor.cancelRoots(1, 99);
        assertEq(cancelled, 2, "rounds 3 and 4");
        assertFalse(distributor.roundOf(1).cancelled, "past its delay: passed over");
        assertTrue(distributor.roundOf(2).cancelled);
        assertTrue(distributor.roundOf(3).cancelled);
        assertTrue(distributor.roundOf(4).cancelled);

        // Nothing left to cancel: the call passes over everything and cancels nothing.
        vm.prank(platform);
        assertEq(distributor.cancelRoots(1, 4), 0);

        (address[] memory h, uint256[] memory a) = _single(thief, 1e18);
        distributor.claim(_claims(_buildFor(distributor, 1, coin0, stock, h, a)));
        assertEq(IERC20(address(mockQuote)).balanceOf(thief), 1e18, "a root the Guard did not stop in time pays");
    }

    /// Only the Admin of the moment cancels a range: not the round key, a stranger, the Tax Vault or a
    /// previous Admin; and an empty or backwards range is refused by name.
    function test_hostile_onlyTheGuardCancelsARange() public {
        _postFalseRoot(makeAddr("c0"));
        address[3] memory others = [roundKey, stranger, address(taxVault)];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(Distributor.NotGuard.selector);
            distributor.cancelRoots(1, 1);
        }
        address nextAdmin = makeAddr("nextAdmin");
        vm.prank(platform);
        keys.proposeAdmin(nextAdmin);
        vm.prank(nextAdmin);
        keys.acceptAdmin();
        vm.prank(platform);
        vm.expectRevert(Distributor.NotGuard.selector);
        distributor.cancelRoots(1, 1);

        vm.startPrank(nextAdmin);
        vm.expectRevert(abi.encodeWithSelector(Distributor.InvalidRange.selector, 0, 1));
        distributor.cancelRoots(0, 1);
        vm.expectRevert(abi.encodeWithSelector(Distributor.InvalidRange.selector, 2, 1));
        distributor.cancelRoots(2, 1);
        assertEq(distributor.cancelRoots(1, 1), 1);
        vm.stopPrank();
    }

    /// A false root whose tree owes twice its total stops at its total, while an honest round of the same
    /// coin, posted before it, is paid in full.
    function test_hostile_aFalseRootCannotEatAnHonestRoundOfTheSameCoin() public {
        _fund(coinA, stock, 1_000);
        (address[] memory h, uint256[] memory a) = _pair(alice, 300, bob, 200);
        Built memory honest = _post(coinA, stock, h, a);
        (h, a) = _pair(carol, 500, thief, 500);
        Built memory falseRound = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        distributor.postRoot(falseRound.round, coinA, stock, falseRound.root, 500);
        _warpPastDelay(falseRound.round);

        distributor.claim(_one(_claimAt(falseRound, 1)));
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundTotalExceeded.selector, falseRound.round));
        distributor.claim(_one(_claimAt(falseRound, 0)));

        distributor.claim(_claims(honest));
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 300);
        assertEq(IERC20(address(mockQuote)).balanceOf(bob), 200);
        assertEq(IERC20(address(mockQuote)).balanceOf(thief), 500);
        assertEq(IERC20(address(mockQuote)).balanceOf(carol), 0);
        assertEq(distributor.potOf(coinA, stock), 0);
    }

    // ------------------------------------------------------------------ the pot

    /// An asset that answers `transferFrom` with true and moves nothing cannot raise a pot.
    function test_hostile_aDepositThatMovesNothingIsRefused() public {
        LyingStock l = new LyingStock();
        Currency asset = Currency.wrap(address(l));
        deal(address(l), address(taxVault), 100);
        l.setLying(true);
        vm.startPrank(address(taxVault));
        l.approve(address(distributor), 100);
        vm.expectRevert(Distributor.DepositShort.selector);
        distributor.deposit(coinA, asset, 100);
        vm.stopPrank();
        assertEq(distributor.potOf(coinA, asset), 0);
        assertEq(distributor.availableOf(coinA, asset), 0);
    }

    /// Assets arriving outside a deposit (a direct ERC-20 transfer, native asset forced in by a selfdestruct)
    /// raise no pot, so no root can be posted against them; they belong to no pot, for good.
    function test_hostile_assetsArrivingOutsideADepositRaiseNoPot() public {
        Currency eth = Currency.wrap(address(0));
        deal(address(mockQuote), stranger, 1_000);
        vm.prank(stranger);
        IERC20(address(mockQuote)).transfer(address(distributor), 1_000);
        vm.deal(address(distributor), 5 ether);

        assertEq(distributor.potOf(coinA, stock), 0);
        assertEq(distributor.potOf(coinA, eth), 0);
        (address[] memory h, uint256[] memory a) = _single(alice, 1_000);
        Built memory b = _build(coinA, stock, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 1_000, 0));
        distributor.postRoot(b.round, coinA, stock, b.root, b.total);
        (h, a) = _single(alice, 5 ether);
        b = _build(coinA, eth, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 5 ether, 0));
        distributor.postRoot(b.round, coinA, eth, b.root, b.total);
    }

    // ------------------------------------------------------------------ claims

    /// A blocked holder named twice in one batch, with another holder between, is refused twice and every
    /// figure is back where it was; the holder between is paid once; once unblocked, paid once.
    function test_hostile_aBlockedHolderNamedTwiceInOneBatchStaysOwedOnce() public {
        _fund(coinA, stock, 300);
        (address[] memory h, uint256[] memory a) = _pair(alice, 100, bob, 200);
        Built memory b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);
        mockQuote.setBlocked(alice, true);
        Distributor.Claim[] memory c = new Distributor.Claim[](3);
        (c[0], c[1], c[2]) = (_claimAt(b, 0), _claimAt(b, 1), _claimAt(b, 0));
        vm.expectEmit(address(distributor));
        emit Distributor.ClaimRefused(b.round, alice, stock, 100);
        vm.expectEmit(address(distributor));
        emit Distributor.Claimed(b.round, bob, stock, 200);
        vm.expectEmit(address(distributor));
        emit Distributor.ClaimRefused(b.round, alice, stock, 100);
        distributor.claim(c);
        assertFalse(distributor.isClaimed(b.round, alice));
        assertEq(distributor.roundOf(b.round).paid, 200);
        assertEq(distributor.potOf(coinA, stock), 100);
        assertEq(distributor.reservedOf(coinA, stock), 100);
        assertEq(IERC20(address(mockQuote)).balanceOf(address(distributor)), 100);
        mockQuote.setBlocked(alice, false);
        distributor.claim(c);
        assertEq(IERC20(address(mockQuote)).balanceOf(alice), 100);
        assertEq(IERC20(address(mockQuote)).balanceOf(bob), 200);
        assertEq(distributor.potOf(coinA, stock), 0);
    }

    /// The call "an ERC-20 payment carries no gas floor", tested: across every gas budget a stranger cannot
    /// make an expensive asset's payment fail for want of gas and still have the call go through, since the
    /// sixty-fourth left after the asset runs out cannot pay for the refusal's own writes.
    function test_hostile_noGasBudgetFalselyRefusesAnErc20Payment() public {
        HeavyStock heavy = new HeavyStock();
        Currency asset = Currency.wrap(address(heavy));
        _fund(coinA, asset, 300);
        (address[] memory h, uint256[] memory a) = _pair(alice, 100, bob, 200);
        Built memory b = _post(coinA, asset, h, a);
        _warpPastDelay(b.round);
        Distributor.Claim[] memory c = _claims(b);

        uint256 paidAt;
        for (uint256 g = 40_000; g < 700_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(stranger);
            try distributor.claim{gas: g}(c) {
                assertTrue(distributor.isClaimed(b.round, alice), "alice refused for want of gas");
                assertTrue(distributor.isClaimed(b.round, bob), "bob refused for want of gas");
                if (paidAt == 0) paidAt = g;
            } catch {}
            vm.revertToState(snap);
        }
        assertGt(paidAt, 0, "some budget pays");
    }

    /// The same, for the mock Stock Token and a batch of eight.
    function test_hostile_noGasBudgetFalselyRefusesAStockTokenPayment() public {
        (address[] memory h, uint256[] memory a) = _holders("holder", 8, 10);
        _fund(coinA, stock, 360);
        Built memory b = _post(coinA, stock, h, a);
        _warpPastDelay(b.round);
        Distributor.Claim[] memory c = _claims(b);
        uint256 paidAt;
        for (uint256 g = 30_000; g < 600_000; g += 1_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(stranger);
            try distributor.claim{gas: g}(c) {
                for (uint256 i; i < h.length; i++) {
                    assertTrue(distributor.isClaimed(b.round, h[i]), "refused for want of gas");
                }
                if (paidAt == 0) paidAt = g;
            } catch {}
            vm.revertToState(snap);
        }
        assertGt(paidAt, 0, "some budget pays");
    }

    // ------------------------------------------------------------------ helpers

    /// Fills `coin`'s pot with 1e18 of the Stock Token and posts, as the round key of the moment, a root
    /// that pays it all to the thief.
    function _postFalseRoot(address coin) internal {
        _fund(coin, stock, 1e18);
        (address[] memory h, uint256[] memory a) = _single(thief, 1e18);
        Built memory b = _build(coin, stock, h, a);
        vm.prank(keys.holderOf(StokerKeys.Role.RoundKey));
        distributor.postRoot(b.round, coin, stock, b.root, b.total);
    }
}
