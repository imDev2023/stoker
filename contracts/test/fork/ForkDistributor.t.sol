// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Distributor} from "../../src/Distributor.sol";
import {ForkDistributorBase} from "./ForkDistributorBase.sol";
import {ISafeProxyFactory, ISafeSetup} from "./ForkNative.t.sol";
import {RevertingRecipient, GasBurningRecipient, ReturnBombRecipient, CountingRecipient} from "../utils/Recipients.sol";
import {ReentrantClaimRecipient} from "../utils/ClaimRecipients.sol";

/// The Distributor against NVDA, a real Stock Token with its issuer's blocklist and pause, and native ETH,
/// on Robinhood Chain's real chain state (#247).
contract ForkDistributorTest is ForkDistributorBase {
    error IsPaused();

    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    /// A claim against a root posted less than 24 hours ago reverts, and the same claim succeeds after it.
    function test_fork_aClaimInsideTheDelayReverts_andSucceedsAfter() public {
        _fund(coinA, NVDA_ASSET, 5 ether);
        (address[] memory h, uint256[] memory a) = _single(alice, 5 ether);
        Built memory b = _post(coinA, NVDA_ASSET, h, a);
        uint256 payableAt = _payableAt(b.round);
        assertEq(payableAt, block.timestamp + 24 hours);

        vm.warp(payableAt - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundDelay.selector, b.round, payableAt));
        distributor.claim(_claims(b));

        vm.warp(payableAt);
        vm.prank(keeper);
        distributor.claim(_claims(b));
        assertEq(IERC20(NVDA).balanceOf(alice), 5 ether);
    }

    /// A root whose total exceeds the holders' part of that coin's tax cannot pay beyond it, and one coin's
    /// round never pays from another coin's tax.
    function test_fork_aRootBeyondItsCoinsPotCannotPay_andCoinsAreApart() public {
        _fund(coinA, NVDA_ASSET, 10 ether);
        _fund(coinB, NVDA_ASSET, 1_000 ether);

        // Beyond coin A's pot, with coin B's far larger pot beside it: refused.
        (address[] memory h, uint256[] memory a) = _pair(alice, 6 ether, keeper, 4 ether + 1);
        Built memory b = _build(coinA, NVDA_ASSET, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 10 ether + 1, 10 ether));
        distributor.postRoot(b.round, coinA, NVDA_ASSET, b.root, b.total);

        // A coin with nothing in its pot: refused.
        b = _build(coinN, NVDA_ASSET, h, a);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 10 ether + 1, 0));
        distributor.postRoot(b.round, coinN, NVDA_ASSET, b.root, b.total);

        // At the pot: every holder paid, and the pot of coin B untouched.
        (h, a) = _pair(alice, 6 ether, keeper, 4 ether);
        b = _post(coinA, NVDA_ASSET, h, a);
        _warpPastDelay(b.round);
        distributor.claim(_claims(b));
        assertEq(IERC20(NVDA).balanceOf(alice), 6 ether);
        assertEq(IERC20(NVDA).balanceOf(keeper), 4 ether);
        assertEq(distributor.potOf(coinA, NVDA_ASSET), 0);
        assertEq(distributor.potOf(coinB, NVDA_ASSET), 1_000 ether);
        assertEq(IERC20(NVDA).balanceOf(address(distributor)), 1_000 ether);
    }

    /// A stranger submits 50 holders' claims in one call and each receives their own amount; with one holder
    /// blocked by the Stock Token's registry, the other 49 are paid and the blocked one stays owed, and is
    /// paid once unblocked.
    function test_fork_aStrangerPushesFiftyClaims_oneBlockedStaysOwed() public {
        (address[] memory h, uint256[] memory a) = _holders("holder", 50, 0.01 ether);
        _fund(coinB, NVDA_ASSET, 12.75 ether);
        Built memory b = _post(coinB, NVDA_ASSET, h, a);
        _warpPastDelay(b.round);
        _block(h[17]);

        vm.expectEmit(address(distributor));
        emit Distributor.ClaimRefused(b.round, h[17], NVDA_ASSET, a[17]);
        vm.prank(stranger);
        distributor.claim(_claims(b));
        for (uint256 i; i < 50; i++) {
            assertEq(IERC20(NVDA).balanceOf(h[i]), i == 17 ? 0 : a[i], "each their own");
        }
        assertFalse(distributor.isClaimed(b.round, h[17]), "the blocked holder stays owed");
        assertEq(distributor.potOf(coinB, NVDA_ASSET), a[17]);
        assertEq(IERC20(NVDA).balanceOf(stranger), 0);

        vm.clearMockedCalls();
        vm.prank(stranger);
        distributor.claim(_claims(b));
        assertEq(IERC20(NVDA).balanceOf(h[17]), a[17], "paid once unblocked");
        assertEq(IERC20(NVDA).balanceOf(address(distributor)), 0);
    }

    /// While the issuer's pause is on, NVDA pays nobody and every holder stays owed; after it, all are paid.
    function test_fork_nothingIsPaidWhileTheIssuersPauseIsOn() public {
        (address[] memory h, uint256[] memory a) = _holders("holder", 3, 1 ether);
        _fund(coinA, NVDA_ASSET, 6 ether);
        Built memory b = _post(coinA, NVDA_ASSET, h, a);
        _warpPastDelay(b.round);

        _pauseRegistry();
        // The pause is in force: NVDA refuses even a transfer of nothing.
        vm.expectRevert(IsPaused.selector);
        IERC20(NVDA).transfer(alice, 0);
        distributor.claim(_claims(b));
        for (uint256 i; i < 3; i++) {
            assertEq(IERC20(NVDA).balanceOf(h[i]), 0);
            assertFalse(distributor.isClaimed(b.round, h[i]));
        }
        assertEq(distributor.potOf(coinA, NVDA_ASSET), 6 ether);

        vm.clearMockedCalls();
        distributor.claim(_claims(b));
        for (uint256 i; i < 3; i++) {
            assertEq(IERC20(NVDA).balanceOf(h[i]), a[i]);
        }
    }

    /// A round paid in the coin itself, for each kind of coin: the coin as currency1 and as currency0 of an
    /// NVDA pool, and a coin paired with native ETH.
    function test_fork_roundsPaidInTheCoin_everyOrder() public {
        address[3] memory coins = [coinA, coinB, coinN];
        for (uint256 i; i < 3; i++) {
            Currency asset = Currency.wrap(coins[i]);
            _fund(coins[i], asset, 3e24);
            (address[] memory h, uint256[] memory a) = _pair(alice, 1e24, keeper, 2e24);
            Built memory b = _post(coins[i], asset, h, a);
            _warpPastDelay(b.round);
            vm.prank(stranger);
            distributor.claim(_claims(b));
            assertEq(IERC20(coins[i]).balanceOf(alice), 1e24);
            assertEq(IERC20(coins[i]).balanceOf(keeper), 2e24);
            assertEq(distributor.potOf(coins[i], asset), 0);
        }
    }

    /// A round in native ETH under the Keeper's gas: an ordinary wallet and a Safe 1.4.1 are paid while
    /// holders that revert, burn their gas, return a bomb or re-enter stay owed.
    function test_fork_native_walletAndSafePaid_hostileHoldersStayOwed() public {
        ReentrantClaimRecipient reentrant = new ReentrantClaimRecipient(distributor, false);
        CountingRecipient wallet = new CountingRecipient();
        address[] memory h = new address[](6);
        (h[0], h[1], h[2], h[3], h[4], h[5]) =
        (
            address(wallet),
            _safe(),
            address(new RevertingRecipient()),
            address(new GasBurningRecipient()),
            address(new ReturnBombRecipient()),
            address(reentrant)
        );
        uint256[] memory a = new uint256[](6);
        for (uint256 i; i < 6; i++) {
            a[i] = 0.001 ether * (i + 1);
        }
        _fund(coinN, ETH, 0.021 ether);
        Built memory b = _post(coinN, ETH, h, a);
        reentrant.arm(_claimAt(b, 5));
        _warpPastDelay(b.round);

        vm.prank(keeper);
        distributor.claim{gas: KEEPER_GAS}(_claims(b));
        assertEq(wallet.received(), a[0]);
        assertEq(h[1].balance, a[1], "the Safe is paid within the allowance");
        for (uint256 i = 2; i < 6; i++) {
            assertEq(h[i].balance, 0);
            assertFalse(distributor.isClaimed(b.round, h[i]));
        }
        assertEq(address(distributor).balance, a[2] + a[3] + a[4] + a[5]);
    }

    function _safe() internal returns (address safe) {
        address[] memory owners = new address[](1);
        owners[0] = makeAddr("safeOwner");
        bytes memory init = abi.encodeCall(
            ISafeSetup.setup,
            (owners, 1, address(0), "", 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory(0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67)
            .createProxyWithNonce(0x29fcB43b46531BcA003ddC8FCB67FFE91900C762, init, 247);
    }
}
