// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// A Payout Call, which anyone can make, pays each Credit to its owner alone (ADR 0025).
/// A Credit owed to an address the Quote Asset refuses stays owed to that address.
contract PayoutTest is LocalBase {
    PoolKey internal key;

    function setUp() public override {
        super.setUp();
        (, key) = _launch(true, 1 ether);
        _swap(key, trader, true, true, 20 ether);
        _swap(key, trader, false, false, 5 ether);
    }

    function _owners(address a, address b) internal pure returns (address[] memory o) {
        o = new address[](2);
        o[0] = a;
        o[1] = b;
    }

    function test_payout_byAStranger_paysEachOwnerAlone() public {
        uint256 creatorCredit = _credit(creator);
        uint256 platformCredit = _credit(platform);
        assertGt(creatorCredit, 0);
        assertGt(platformCredit, 0);
        uint256 creatorBefore = quote.balanceOf(creator);
        uint256 strangerBefore = quote.balanceOf(stranger);

        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.CreditPaid(creator, _quoteCurrency(), creatorCredit);
        vm.prank(stranger);
        hook.payout(_quoteCurrency(), _owners(creator, platform));

        assertEq(quote.balanceOf(creator) - creatorBefore, creatorCredit, "creator paid their credit");
        assertEq(quote.balanceOf(platform), platformCredit, "platform paid its credit");
        assertEq(quote.balanceOf(stranger), strangerBefore, "the caller receives nothing");
        assertEq(_credit(creator), 0);
        assertEq(_credit(platform), 0);
        assertEq(_hookClaims(), 0, "every claim burned");
    }

    function test_payout_ownerPullsTheirOwn() public {
        uint256 credit = _credit(creator);
        address[] memory me = new address[](1);
        me[0] = creator;
        vm.prank(creator);
        hook.payout(_quoteCurrency(), me);
        assertEq(_credit(creator), 0);
        assertEq(_credit(platform), _hookClaims(), "the platform's credit untouched");
        assertGt(credit, 0);
    }

    function test_payout_twiceInARowPaysNothingMore() public {
        hook.payout(_quoteCurrency(), _owners(creator, creator));
        uint256 balance = quote.balanceOf(creator);
        hook.payout(_quoteCurrency(), _owners(creator, stranger));
        assertEq(quote.balanceOf(creator), balance);
        assertEq(quote.balanceOf(stranger), 0);
    }

    function test_payout_blockedOwnerStaysOwed_othersPaid_swapsGoOn() public {
        mockQuote.setBlocked(creator, true);
        uint256 creatorCredit = _credit(creator);
        uint256 platformCredit = _credit(platform);

        // Swaps still succeed while the Creator is blocked, and keep crediting them.
        _swap(key, trader, true, true, 3 ether);
        _swap(key, trader, false, true, 1e9 ether);
        assertGt(_credit(creator), creatorCredit, "still credited while blocked");
        creatorCredit = _credit(creator);
        platformCredit = _credit(platform);

        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.CreditRefused(creator, _quoteCurrency(), creatorCredit);
        vm.prank(stranger);
        hook.payout(_quoteCurrency(), _owners(creator, platform));

        assertEq(quote.balanceOf(platform), platformCredit, "platform still paid");
        assertEq(_credit(creator), creatorCredit, "creator's credit stays owed, to them");
        assertEq(_hookClaims(), creatorCredit, "and stays backed");

        // Once the issuer lifts the block, the same call pays it.
        mockQuote.setBlocked(creator, false);
        uint256 before = quote.balanceOf(creator);
        hook.payout(_quoteCurrency(), _owners(creator, platform));
        assertEq(quote.balanceOf(creator) - before, creatorCredit);
        assertEq(_hookClaims(), 0);
    }

    function test_payout_unknownCurrencyPaysNothing() public {
        hook.payout(Currency.wrap(address(0xBEEF)), _owners(creator, platform));
        assertGt(_credit(creator), 0);
    }

    function test_payout_noKeyCanMoveACredit() public {
        // The hook has no function that moves, lowers or redirects a Credit: the only path out pays
        // the owner. Its whole external surface is the PoolManager's callbacks, the factory's
        // registration, the views and payout.
        vm.prank(platform);
        hook.payout(_quoteCurrency(), _owners(creator, creator));
        assertEq(quote.balanceOf(platform), 0, "the platform cannot take the creator's credit");
    }

    function test_unlockCallback_onlyThePoolManager() public {
        vm.expectRevert();
        hook.unlockCallback(abi.encode(_quoteCurrency(), _owners(stranger, stranger)));
    }
}
