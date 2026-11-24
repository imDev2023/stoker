// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ForkDestinationsBase} from "./ForkDestinationsBase.sol";
import {Distributor} from "../../src/Distributor.sol";

/// The holders' Destination on the real PoolManager (#248): on a Reward Launch that also pays its holders
/// its Creator's earnings, the earnings are claimable through a Round Root of their own after the Round
/// Delay and never mix with the coin's Reward Tax. Paid in a real Stock Token and in native ETH.
contract ForkDestinationHoldersTest is ForkDestinationsBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _dividends(uint256 kind) internal {
        PoolKey memory key = _launchRewardTo(kind, address(holdersDestination), 0, 0);
        address coin = address(_coinOfKey(key));
        Currency asset = _asset(key);
        _earnThrough(key);
        uint256 credited = _credited(key);
        uint256 tax = _taxBooked(key);
        assertGt(credited, 0, _kindName(kind));
        assertGt(tax, credited, "a 3% tax beside half of a 1% fee");

        // Each reaches the Distributor by its own way, into its own pot.
        uint256 held = _balance(asset, address(distributor));
        assertEq(_applyBy(stranger, holdersDestination, key), credited);
        vm.prank(stranger);
        taxVault.passHoldersPart(key);
        assertEq(distributor.earningsPotOf(coin, asset), credited, "the Creator's earnings");
        assertEq(distributor.potOf(coin, asset), tax, "the Reward Tax's holders' part");
        assertEq(_balance(asset, address(distributor)) - held, credited + tax);

        // An earnings root for more than the earnings pot is refused, though the tax pot beside it could
        // cover it.
        (address[] memory holders, uint256[] memory amounts) = _pair(alice, credited, bob, 1);
        Built memory tooMuch = _build(coin, asset, holders, amounts);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, credited + 1, credited));
        distributor.postEarningsRoot(tooMuch.round, coin, asset, tooMuch.root, tooMuch.total);

        // A Round Root of the earnings' own, for the whole pot.
        (holders, amounts) = _pair(alice, credited / 3, bob, credited - credited / 3);
        Built memory round = _build(coin, asset, holders, amounts);
        vm.prank(roundKey);
        distributor.postEarningsRoot(round.round, coin, asset, round.root, round.total);
        assertEq(uint8(distributor.roundOf(round.round).source), uint8(Distributor.Source.Earnings));
        assertEq(distributor.earningsAvailableOf(coin, asset), 0);
        assertEq(distributor.availableOf(coin, asset), tax, "nothing of the tax was reserved");

        // Nothing pays inside the Round Delay; after it a stranger's call pays each holder.
        vm.warp(_payableAt(round.round) - 1);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundDelay.selector, round.round, _payableAt(round.round)));
        distributor.claim(_claims(round));
        vm.warp(_payableAt(round.round));
        uint256 aliceBefore = _balance(asset, alice);
        uint256 bobBefore = _balance(asset, bob);
        vm.prank(stranger);
        distributor.claim{gas: KEEPER_GAS}(_claims(round));
        assertEq(_balance(asset, alice) - aliceBefore, credited / 3, "her Holder Dividend");
        assertEq(_balance(asset, bob) - bobBefore, credited - credited / 3, "his");
        assertEq(distributor.earningsPotOf(coin, asset), 0, "paid from the earnings pot");
        assertEq(distributor.potOf(coin, asset), tax, "and the Reward Tax's pot is whole");

        // The Reward Tax then pays its own round, from its own pot.
        (holders, amounts) = _pair(alice, tax / 2, bob, tax - tax / 2);
        Built memory taxRound = _post(coin, asset, holders, amounts);
        _warpPastDelay(taxRound.round);
        vm.prank(stranger);
        distributor.claim{gas: KEEPER_GAS}(_claims(taxRound));
        assertEq(_balance(asset, alice) - aliceBefore, credited / 3 + tax / 2);
        assertEq(distributor.potOf(coin, asset), 0);
        assertEq(_balance(asset, address(distributor)), held, "nothing is left of either");
    }

    function test_fork_holders_theEarningsAreClaimable_apartFromTheRewardTax_nvdaAsCurrency0() public {
        _dividends(QUOTE_FIRST);
    }

    function test_fork_holders_theEarningsAreClaimable_apartFromTheRewardTax_theCoinAsCurrency0() public {
        _dividends(COIN_FIRST);
    }

    function test_fork_holders_theEarningsAreClaimable_apartFromTheRewardTax_nativeEth() public {
        _dividends(NATIVE_PAIR);
    }
}
