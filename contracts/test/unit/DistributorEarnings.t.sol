// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {Distributor} from "../../src/Distributor.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";

/// The Distributor's earnings pot (#248, ADR 0029): a coin's Creator earnings arrive from that coin's own
/// Creator Earnings Destination alone, into a pot apart from the coin's Reward Tax, and Round Roots of
/// source `earnings` pay from that pot and from nothing else.
contract DistributorEarningsTest is DestinationsLocalBase {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    /// Hands `amount` of the pool's Quote Asset to the Distributor as `who`, the way a Destination does.
    function _depositEarningsAs(address who, PoolKey memory key, uint256 amount) internal {
        Currency asset = _quoteOfKey(key);
        if (asset.isAddressZero()) {
            vm.deal(who, who.balance + amount);
            vm.prank(who);
            distributor.depositEarnings{value: amount}(key, amount);
        } else {
            IERC20 token = IERC20(Currency.unwrap(asset));
            deal(address(token), who, token.balanceOf(who) + amount);
            vm.startPrank(who);
            token.approve(address(distributor), amount);
            distributor.depositEarnings(key, amount);
            vm.stopPrank();
        }
    }

    function _postEarnings(address coin, Currency asset, address[] memory holders, uint256[] memory amounts)
        internal
        returns (Built memory b)
    {
        b = _build(coin, asset, holders, amounts);
        vm.prank(roundKey);
        distributor.postEarningsRoot(b.round, coin, asset, b.root, b.total);
    }

    function _coinAddr(PoolKey memory key) internal view returns (address) {
        return address(_coinOfKey(key));
    }

    // ---------------------------------------------------------------- who may deposit

    function test_earnings_onlyTheCoinsOwnDestinationDeposits() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(holdersDestination));
            PoolKey memory walletCoin = _launchTo(kind, address(0));
            Currency asset = _quoteOfKey(key);
            uint256 unit = _unit(key);

            // A stranger, the Creator, the Tax Vault, another Destination contract, the Admin and the round
            // key: none is this coin's Destination.
            address[6] memory others =
                [stranger, creator, address(taxVault), address(burnDestination), platform, roundKey];
            for (uint256 i; i < others.length; i++) {
                if (!asset.isAddressZero()) {
                    deal(Currency.unwrap(asset), others[i], unit);
                    vm.prank(others[i]);
                    IERC20(Currency.unwrap(asset)).approve(address(distributor), unit);
                } else {
                    vm.deal(others[i], unit);
                }
                vm.prank(others[i]);
                vm.expectRevert(Distributor.NotTheCoinsDestination.selector);
                distributor.depositEarnings{value: asset.isAddressZero() ? unit : 0}(key, unit);
            }
            // The holders' Destination itself, for a coin that names the Creator's wallet.
            vm.deal(address(holdersDestination), unit);
            vm.prank(address(holdersDestination));
            vm.expectRevert(Distributor.NotTheCoinsDestination.selector);
            distributor.depositEarnings{value: asset.isAddressZero() ? unit : 0}(walletCoin, unit);
            assertEq(distributor.earningsPotOf(_coinAddr(key), asset), 0);
            assertEq(distributor.earningsPotOf(_coinAddr(walletCoin), asset), 0);

            // Its own Destination deposits.
            _depositEarningsAs(address(holdersDestination), key, unit);
            assertEq(distributor.earningsPotOf(_coinAddr(key), asset), unit);
        }
    }

    function test_earnings_aPoolThatIsNotOursIsRefused() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(holdersDestination));
        PoolKey memory other = _onAnotherSpacing(key);
        vm.prank(address(holdersDestination));
        vm.expectRevert(Distributor.NotTheCoinsDestination.selector);
        distributor.depositEarnings(other, 1 ether);
        other = _onNoHook(key);
        vm.prank(address(holdersDestination));
        vm.expectRevert(Distributor.NotTheCoinsDestination.selector);
        distributor.depositEarnings(other, 1 ether);
        // The coin's own key is taken.
        _depositEarningsAs(address(holdersDestination), key, 1 ether);
    }

    /// The Distributor admits whatever address a Launch's terms name: a Creator whose Destination is their
    /// own wallet may give their coin's holders a dividend, and nobody else's coin.
    function test_earnings_aCreatorsWalletIsItsCoinsDestination() public {
        PoolKey memory mine = _launchTo(QUOTE_FIRST, address(0));
        PoolKey memory holdersCoin = _launchTo(QUOTE_FIRST, address(holdersDestination));
        _depositEarningsAs(creator, mine, 2 ether);
        assertEq(distributor.earningsPotOf(_coinAddr(mine), stock()), 2 ether);
        deal(address(quote), creator, 2 ether);
        vm.startPrank(creator);
        quote.approve(address(distributor), 2 ether);
        vm.expectRevert(Distributor.NotTheCoinsDestination.selector);
        distributor.depositEarnings(holdersCoin, 2 ether);
        vm.stopPrank();
    }

    function stock() internal view returns (Currency) {
        return Currency.wrap(address(quote));
    }

    // ---------------------------------------------------------------- the pot

    /// A deposit raises the earnings pot and what an earnings root may reserve together, and nothing of
    /// the Reward Tax's pot.
    function test_earnings_aDepositRaisesItsOwnPotAndWhatARootMayReserve() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(holdersDestination));
            Currency asset = _quoteOfKey(key);
            address coin = _coinAddr(key);
            uint256 unit = _unit(key);
            uint256 held = _balance(asset, address(distributor));

            // The allowance first: an expected event is the next one emitted.
            if (asset.isAddressZero()) {
                vm.deal(address(holdersDestination), 3 * unit);
            } else {
                deal(Currency.unwrap(asset), address(holdersDestination), 3 * unit);
                vm.prank(address(holdersDestination));
                IERC20(Currency.unwrap(asset)).approve(address(distributor), 3 * unit);
            }
            vm.expectEmit(true, true, true, true, address(distributor));
            emit Distributor.EarningsDeposited(coin, asset, address(holdersDestination), 3 * unit);
            vm.prank(address(holdersDestination));
            distributor.depositEarnings{value: asset.isAddressZero() ? 3 * unit : 0}(key, 3 * unit);

            assertEq(distributor.earningsPotOf(coin, asset), 3 * unit);
            assertEq(distributor.earningsAvailableOf(coin, asset), 3 * unit, "a root may reserve all of it");
            assertEq(distributor.earningsReservedOf(coin, asset), 0);
            assertEq(distributor.potOf(coin, asset), 0, "the Reward Tax's pot did not move");
            assertEq(distributor.availableOf(coin, asset), 0);
            assertEq(_balance(asset, address(distributor)) - held, 3 * unit, "exactly the amount arrived");
        }
    }

    function test_earnings_theValueIsExactlyTheNativeAmount_andNoneWithAnERC20() public {
        PoolKey memory nativeKey = _launchTo(NATIVE_PAIR, address(holdersDestination));
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(holdersDestination));
        vm.deal(address(holdersDestination), 10 ether);
        vm.startPrank(address(holdersDestination));
        vm.expectRevert(abi.encodeWithSelector(Distributor.ValueMismatch.selector, 1 ether, 0.5 ether));
        distributor.depositEarnings{value: 0.5 ether}(nativeKey, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Distributor.ValueMismatch.selector, 1 ether, 0));
        distributor.depositEarnings(nativeKey, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(Distributor.ValueMismatch.selector, 0, 1));
        distributor.depositEarnings{value: 1}(key, 1 ether);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- rounds of source earnings

    /// The heart of it: on a Reward Launch that also pays its holders its Creator's earnings, each kind of
    /// round reserves from its own pot alone. A root that could be paid only by reaching into the other pot
    /// is refused, and each round pays its holders from its own.
    function test_earnings_eachRoundPaysFromItsOwnPot_neverTheOthers() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchRewardTo(kind, address(holdersDestination), 0, 0);
            Currency asset = _quoteOfKey(key);
            address coin = _coinAddr(key);
            uint256 unit = _unit(key);
            _fund(coin, asset, 4 * unit); // the Reward Tax's holders' part
            _depositEarningsAs(address(holdersDestination), key, 6 * unit); // the Creator's earnings

            (address[] memory holders, uint256[] memory amounts) = _pair(alice, 3 * unit, bob, 2 * unit);
            // Five units: more than the tax pot's four, under the ten the two hold together.
            Built memory tooMuch = _build(coin, asset, holders, amounts);
            vm.prank(roundKey);
            vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 5 * unit, 4 * unit));
            distributor.postRoot(tooMuch.round, coin, asset, tooMuch.root, tooMuch.total);

            // Seven units: more than the earnings pot's six.
            (holders, amounts) = _pair(alice, 4 * unit, bob, 3 * unit);
            tooMuch = _build(coin, asset, holders, amounts);
            vm.prank(roundKey);
            vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 7 * unit, 6 * unit));
            distributor.postEarningsRoot(tooMuch.round, coin, asset, tooMuch.root, tooMuch.total);

            // Each at its own pot's whole.
            (holders, amounts) = _pair(alice, 3 * unit, bob, unit);
            Built memory taxRound = _post(coin, asset, holders, amounts);
            (holders, amounts) = _pair(alice, 4 * unit, bob, 2 * unit);
            vm.expectEmit(true, true, false, false, address(distributor));
            emit Distributor.EarningsRootPosted(taxRound.round + 1, coin);
            Built memory earningsRound = _postEarnings(coin, asset, holders, amounts);
            assertEq(uint8(distributor.roundOf(taxRound.round).source), uint8(Distributor.Source.Tax));
            assertEq(uint8(distributor.roundOf(earningsRound.round).source), uint8(Distributor.Source.Earnings));
            assertEq(distributor.availableOf(coin, asset), 0);
            assertEq(distributor.earningsAvailableOf(coin, asset), 0);
            assertEq(distributor.reservedOf(coin, asset), 4 * unit);
            assertEq(distributor.earningsReservedOf(coin, asset), 6 * unit);

            // Only the earnings round is claimed: the tax pot is as it was.
            _warpPastDelay(earningsRound.round);
            uint256 aliceBefore = _balance(asset, alice);
            vm.prank(stranger);
            distributor.claim(_claims(earningsRound));
            assertEq(_balance(asset, alice) - aliceBefore, 4 * unit, "her Holder Dividend");
            assertEq(distributor.earningsPotOf(coin, asset), 0, "paid from the earnings pot");
            assertEq(distributor.potOf(coin, asset), 4 * unit, "and nothing of the Reward Tax's");

            vm.prank(stranger);
            distributor.claim(_claims(taxRound));
            assertEq(_balance(asset, alice) - aliceBefore, 7 * unit);
            assertEq(distributor.potOf(coin, asset), 0);
            assertEq(distributor.earningsPotOf(coin, asset), 0);
        }
    }

    /// A coin with nothing in its earnings pot cannot be given an earnings root, whatever its tax pot holds,
    /// nor one from another coin's earnings.
    function test_earnings_noRootFromTheTaxPot_norFromAnotherCoinsEarnings() public {
        PoolKey memory a = _launchRewardTo(QUOTE_FIRST, address(holdersDestination), 0, 0);
        PoolKey memory b = _launchTo(COIN_FIRST, address(holdersDestination));
        _fund(_coinAddr(a), stock(), 10 ether);
        _depositEarningsAs(address(holdersDestination), b, 10 ether);
        (address[] memory holders, uint256[] memory amounts) = _single(alice, 1 ether);
        Built memory built = _build(_coinAddr(a), stock(), holders, amounts);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 1 ether, 0));
        distributor.postEarningsRoot(built.round, _coinAddr(a), stock(), built.root, built.total);
        // And coin B, whose earnings pot holds ten, has no tax pot to post a Reward Round from.
        built = _build(_coinAddr(b), stock(), holders, amounts);
        vm.prank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RootExceedsPot.selector, 1 ether, 0));
        distributor.postRoot(built.round, _coinAddr(b), stock(), built.root, built.total);
    }

    function test_earnings_aCancelledRootFreesItsOwnPot() public {
        PoolKey memory key = _launchRewardTo(QUOTE_FIRST, address(holdersDestination), 0, 0);
        address coin = _coinAddr(key);
        _fund(coin, stock(), 5 ether);
        _depositEarningsAs(address(holdersDestination), key, 8 ether);
        (address[] memory holders, uint256[] memory amounts) = _single(alice, 8 ether);
        Built memory round = _postEarnings(coin, stock(), holders, amounts);
        assertEq(distributor.earningsAvailableOf(coin, stock()), 0);

        vm.prank(platform);
        distributor.cancelRoot(round.round);
        assertEq(distributor.earningsAvailableOf(coin, stock()), 8 ether, "free again in the earnings pot");
        assertEq(distributor.availableOf(coin, stock()), 5 ether, "the tax pot's figure did not move");
        _warpPastDelay(round.round);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundCancelled.selector, round.round));
        distributor.claim(_claims(round));
        // Posted again, it pays.
        round = _postEarnings(coin, stock(), holders, amounts);
        _warpPastDelay(round.round);
        distributor.claim(_claims(round));
        assertEq(quote.balanceOf(alice), 8 ether);
    }

    /// A holder the asset refuses, owed by a Reward Round and an earnings round paid as one payment: each
    /// figure goes back to its own pot.
    function test_earnings_aRefusedPaymentGoesBackToEachRoundsOwnPot() public {
        PoolKey memory key = _launchRewardTo(QUOTE_FIRST, address(holdersDestination), 0, 0);
        address coin = _coinAddr(key);
        _fund(coin, stock(), 5 ether);
        _depositEarningsAs(address(holdersDestination), key, 8 ether);
        (address[] memory holders, uint256[] memory amounts) = _single(alice, 5 ether);
        Built memory taxRound = _post(coin, stock(), holders, amounts);
        (holders, amounts) = _single(alice, 8 ether);
        Built memory earningsRound = _postEarnings(coin, stock(), holders, amounts);
        _warpPastDelay(earningsRound.round);

        Distributor.Claim[] memory both = new Distributor.Claim[](2);
        both[0] = _claimAt(taxRound, 0);
        both[1] = _claimAt(earningsRound, 0);
        mockQuote.setBlocked(alice, true);
        vm.prank(stranger);
        distributor.claim(both);
        assertEq(quote.balanceOf(alice), 0);
        assertEq(distributor.potOf(coin, stock()), 5 ether, "the tax round's figure, back in the tax pot");
        assertEq(distributor.earningsPotOf(coin, stock()), 8 ether, "the earnings round's, back in its own");
        assertFalse(distributor.isClaimed(taxRound.round, alice));
        assertFalse(distributor.isClaimed(earningsRound.round, alice));

        mockQuote.setBlocked(alice, false);
        vm.prank(stranger);
        distributor.claim(both);
        assertEq(quote.balanceOf(alice), 13 ether, "her two rounds, as one payment");
        assertEq(distributor.potOf(coin, stock()), 0);
        assertEq(distributor.earningsPotOf(coin, stock()), 0);
    }

    // ---------------------------------------------------------------- who may post

    function test_earnings_onlyTheRoundKeyPosts_neverTheGuard() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(holdersDestination));
        address coin = _coinAddr(key);
        _depositEarningsAs(address(holdersDestination), key, 8 ether);
        (address[] memory holders, uint256[] memory amounts) = _single(alice, 8 ether);
        Built memory built = _build(coin, stock(), holders, amounts);

        address[5] memory others = [stranger, platform, ladderKey, address(holdersDestination), creator];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(Distributor.NotRoundKey.selector);
            distributor.postEarningsRoot(built.round, coin, stock(), built.root, built.total);
        }
        // The Admin naming itself the round key still cannot post.
        vm.startPrank(platform);
        keys.proposeKey(StokerKeys.Role.RoundKey, platform);
        keys.acceptKey(StokerKeys.Role.RoundKey);
        vm.expectRevert(Distributor.GuardCannotPost.selector);
        distributor.postEarningsRoot(built.round, coin, stock(), built.root, built.total);
        vm.stopPrank();
        _setRoundKey(roundKey);

        // The round's number is the next, whatever its source, and no root is empty.
        vm.startPrank(roundKey);
        vm.expectRevert(abi.encodeWithSelector(Distributor.WrongRound.selector, built.round + 1, built.round));
        distributor.postEarningsRoot(built.round + 1, coin, stock(), built.root, built.total);
        vm.expectRevert(Distributor.InvalidRoot.selector);
        distributor.postEarningsRoot(built.round, coin, stock(), bytes32(0), built.total);
        vm.expectRevert(Distributor.InvalidRoot.selector);
        distributor.postEarningsRoot(built.round, coin, stock(), built.root, 0);
        vm.stopPrank();

        // A revoked key stops at once.
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.RoundKey);
        vm.prank(roundKey);
        vm.expectRevert(Distributor.NotRoundKey.selector);
        distributor.postEarningsRoot(built.round, coin, stock(), built.root, built.total);
    }

    /// An earnings round waits the Round Delay like any other.
    function test_earnings_aRoundWaitsTheRoundDelay() public {
        PoolKey memory key = _launchTo(NATIVE_PAIR, address(holdersDestination));
        address coin = _coinAddr(key);
        _depositEarningsAs(address(holdersDestination), key, 1 ether);
        (address[] memory holders, uint256[] memory amounts) = _single(alice, 1 ether);
        Built memory round = _postEarnings(coin, NATIVE, holders, amounts);
        vm.warp(_payableAt(round.round) - 1);
        vm.expectRevert(abi.encodeWithSelector(Distributor.RoundDelay.selector, round.round, _payableAt(round.round)));
        distributor.claim(_claims(round));
        vm.warp(_payableAt(round.round));
        distributor.claim(_claims(round));
        assertEq(alice.balance, 1 ether);
    }
}
