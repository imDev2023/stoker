// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";
import {ListingStandIn} from "../../src/ListingStandIn.sol";

/// The native asset as a Quote Asset (#242, ADR 0024): one call with value launches a coin paired with it
/// and makes the First Buy, with no approval and no permit, and the factory keeps nothing it was sent.
contract NativeLaunchTest is LocalBase {
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
    }

    function test_native_listed() public view {
        assertTrue(listings.listingOf(address(0)).listed, "the native asset has a Listing");
        assertEq(listings.listingOf(address(0)).startTick, NATIVE_START_TICK);
    }

    function test_native_launch_oneCallWithValue_firstBuy() public {
        uint256 firstBuy = 0.1 ether;
        uint256 before = creator.balance;
        (address coin, PoolKey memory key) = _launchNative(firstBuy, address(0));
        StokerCoin c = StokerCoin(coin);

        // The pool key: native ETH as currency0, never a wrapped asset.
        assertEq(Currency.unwrap(key.currency0), address(0), "currency0 is the native asset");
        assertEq(Currency.unwrap(key.currency1), coin);
        assertTrue(hook.termsOf(key.toId()).quoteIsCurrency0);
        assertEq(factory.launchOf(key.toId()).quote, address(0));

        // The Creator paid exactly the value sent and holds coins; nobody kept any of it.
        assertEq(before - creator.balance, firstBuy, "the Creator paid exactly the First Buy");
        assertGt(c.balanceOf(creator), 0, "the First Buy delivered coins");
        assertEq(address(factory).balance, 0, "the factory keeps no native asset");
        assertEq(address(hook).balance, 0, "the hook holds no native asset");

        // Every coin is in the pool or with the Creator.
        assertEq(c.balanceOf(address(pm)) + c.balanceOf(creator), c.totalSupply());
        assertEq(c.balanceOf(address(factory)), 0);
        assertLe(SUPPLY - c.totalSupply(), 1e12, "only seed dust burned");

        // The pool opened at the Listing's price and the First Buy raised it.
        (, int24 tick,, uint24 lpFee) = pm.getSlot0(key.toId());
        assertEq(lpFee, 0);
        assertGt(-tick, NATIVE_START_TICK, "the First Buy raised the coin's price from the start");
        assertEq(_poolLiquidity(key), _seedLiquidity(key), "the seed is the pool's only liquidity");

        // The First Buy paid the Platform Fee in the native asset, recorded as Credits, paid to nobody.
        uint256 fee = _feeOnGross(firstBuy);
        assertEq(_nativeCredit(creator), fee * CREATOR_SHARE_BPS / 10_000, "the Creator's Credit");
        assertEq(_nativeCredit(platform), fee - _nativeCredit(creator), "the platform's Credit");
        assertEq(_nativeClaims(), fee, "the fee held as the hook's claims");
        assertEq(platform.balance, 0, "no transfer to the platform");
    }

    function test_native_launch_withoutFirstBuy() public {
        (address coin, PoolKey memory key) = _launchNative(0, address(0));
        assertEq(StokerCoin(coin).balanceOf(creator), 0);
        assertEq(_nativeCredit(creator), 0);
        assertEq(address(factory).balance, 0);
        // A first trader's buy brings the seed into range, as with any Quote Asset sorted first.
        vm.deal(trader, 1 ether);
        _swapNative(key, trader, true, true, 0.01 ether, 0);
        assertEq(_poolLiquidity(key), _seedLiquidity(key));
    }

    function test_native_launch_refusesValueThatDiffersFromTheFirstBuy() public {
        StokerFactory.LaunchParams memory p = _nativeParams(0.1 ether, address(0));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0.1 ether, 0.2 ether));
        factory.launch{value: 0.2 ether}(p);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0.1 ether, 0.05 ether));
        factory.launch{value: 0.05 ether}(p);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0.1 ether, 0));
        factory.launch(p);

        p.firstBuy = 0;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0, 1));
        factory.launch{value: 1}(p);
    }

    function test_native_launch_refusesValueWithAnERC20QuoteAsset() public {
        StokerFactory.LaunchParams memory p = _params(true, 1 ether);
        vm.startPrank(creator);
        quote.approve(address(factory), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0, 1 ether));
        factory.launch{value: 1 ether}(p);
        // Without a First Buy too.
        p.firstBuy = 0;
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0, 1));
        factory.launch{value: 1}(p);
        vm.stopPrank();
    }

    function test_native_launchWithPermit_takesNoValueAndNeedsNoPermit() public {
        // A permit is an ERC-20's: the permit path is not payable, so a native First Buy through it is
        // refused for the value it could not carry, and a native launch without a First Buy goes through.
        StokerFactory.LaunchParams memory p = _nativeParams(0.1 ether, address(0));
        StokerFactory.PermitSignature memory s;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.ValueMismatch.selector, 0.1 ether, 0));
        factory.launchWithPermit(p, s);

        p.firstBuy = 0;
        vm.prank(creator);
        (address coin,) = factory.launchWithPermit(p, s);
        assertGt(coin.code.length, 0);
    }

    function test_native_unlistedUntilListed() public {
        // A fresh stand-in with no native Listing: the factory refuses the native asset.
        ListingStandIn fresh = new ListingStandIn(listingWriter);
        assertFalse(fresh.listingOf(address(0)).listed);
        vm.prank(listingWriter);
        fresh.list(address(0), NATIVE_START_TICK);
        assertTrue(fresh.listingOf(address(0)).listed);
    }

    function test_native_factoryAcceptsNoStrayValue() public {
        vm.prank(creator);
        (bool ok,) = address(factory).call{value: 1 ether}("");
        assertFalse(ok, "the factory has no receive");
        assertEq(address(factory).balance, 0);
    }

    function test_native_hookAcceptsValueOnlyFromThePoolManager() public {
        vm.prank(creator);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok, "only the PoolManager pays the hook");
        assertEq(address(hook).balance, 0);
    }
}
