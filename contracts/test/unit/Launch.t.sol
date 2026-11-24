// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";

/// One transaction launches a standard coin by Direct Seed (ADR 0024): the coin, the pool at the
/// Listing's start price, the whole supply as the Seed Position, and the Creator's First Buy.
contract LaunchTest is LocalBase {
    using StateLibrary for IPoolManager;

    function test_launch_quoteIsCurrency0() public {
        _assertLaunch(true);
    }

    function test_launch_quoteIsCurrency1() public {
        _assertLaunch(false);
    }

    function _assertLaunch(bool quoteIsCurrency0) internal {
        uint256 firstBuy = 1 ether;
        uint256 creatorQuoteBefore = quote.balanceOf(creator);
        (address coin, PoolKey memory key) = _launch(quoteIsCurrency0, firstBuy);

        // The Creator paid exactly the First Buy and holds coins.
        assertEq(creatorQuoteBefore - quote.balanceOf(creator), firstBuy, "creator paid the first buy");
        uint256 bought = IERC20Metadata(coin).balanceOf(creator);
        assertGt(bought, 0, "first buy delivered coins");

        // Every coin is in the pool or with the Creator: the factory and the hook hold none.
        assertEq(IERC20Metadata(coin).balanceOf(address(factory)), 0, "factory holds no coin");
        assertEq(IERC20Metadata(coin).balanceOf(address(hook)), 0, "hook holds no coin");
        assertEq(
            IERC20Metadata(coin).balanceOf(address(pm)) + bought, IERC20Metadata(coin).totalSupply(), "coins accounted"
        );
        // Only rounding dust of the seed was burned, never more than a millionth of a coin.
        assertLe(SUPPLY - IERC20Metadata(coin).totalSupply(), 1e12, "seed dust");

        // The pool: LP fee zero, our hook, the seed its only liquidity, the price raised by the First Buy.
        assertEq(key.fee, 0, "LP fee is zero");
        (,, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        assertEq(lpFee, 0, "slot0 LP fee");
        assertEq(protocolFee, 0, "a new pool starts with no protocol fee");
        assertGt(_seedLiquidity(key), 0, "seed position");
        assertEq(_poolLiquidity(key), _seedLiquidity(key), "the seed is the pool's only liquidity");
        int24 coinPriceTick = quoteIsCurrency0 ? -_tick(key) : _tick(key);
        assertGt(coinPriceTick, START_TICK, "the First Buy raised the price from the start");

        // The First Buy paid the Platform Fee like any buy.
        uint256 fee = _feeOnGross(firstBuy);
        assertEq(_credit(creator), fee * CREATOR_SHARE_BPS / 10_000, "creator credit");
        assertEq(_credit(platform), fee - _credit(creator), "platform credit");
    }

    function test_launch_coinIsPlain() public {
        (address coin,) = _launch(true, 0);
        StokerCoin c = StokerCoin(coin);
        assertEq(c.name(), "Test Coin");
        assertEq(c.symbol(), "TEST");
        assertEq(c.decimals(), 18);
        assertEq(c.SUPPLY(), 1e12 * 1e18, "1 trillion at 18 decimals");
        // No owner and no way to mint: neither function exists on the coin.
        (bool ok,) = coin.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");
        (ok,) = coin.call(abi.encodeWithSignature("mint(address,uint256)", stranger, 1));
        assertFalse(ok, "no mint(address,uint256)");
        (ok,) = coin.call(abi.encodeWithSignature("mint(uint256)", 1));
        assertFalse(ok, "no mint(uint256)");
    }

    function test_launch_holderBurnsOwnCoinsOnly() public {
        (address coin,) = _launch(true, 1 ether);
        StokerCoin c = StokerCoin(coin);
        uint256 supply = c.totalSupply();
        uint256 held = c.balanceOf(creator);
        vm.prank(creator);
        c.burn(held / 2);
        assertEq(c.totalSupply(), supply - held / 2, "a burn lowers the supply");
        vm.prank(stranger);
        vm.expectRevert();
        c.burn(1);
    }

    function test_launch_withoutFirstBuy() public {
        (address coin, PoolKey memory key) = _launch(true, 0);
        assertEq(StokerCoin(coin).balanceOf(creator), 0);
        assertEq(_credit(creator), 0);
        // With the coin as currency1 the pool opens on the seed's upper edge, which v4 counts as out of
        // range: no active liquidity until the first buy (the spike's gotcha 6).
        assertEq(_poolLiquidity(key), 0);
        _swap(key, trader, true, true, 1 ether);
        assertEq(_poolLiquidity(key), _seedLiquidity(key));
    }

    function test_launch_withPermit_noPriorApproval() public {
        StokerFactory.LaunchParams memory p = _params(true, 1 ether);
        assertEq(quote.allowance(creator, address(factory)), 0);
        StokerFactory.PermitSignature memory s = _permit(1 ether, block.timestamp + 1 hours);
        vm.prank(creator);
        (address coin,) = factory.launchWithPermit(p, s);
        assertGt(StokerCoin(coin).balanceOf(creator), 0, "first buy on a signature");
    }

    function test_launch_permitAlreadyUsed_stillLaunchesWithAllowance() public {
        // Someone who saw the signature submits the permit first: the launch must not fail for it.
        StokerFactory.LaunchParams memory p = _params(true, 1 ether);
        StokerFactory.PermitSignature memory s = _permit(1 ether, block.timestamp + 1 hours);
        mockQuote.permit(creator, address(factory), 1 ether, s.deadline, s.v, s.r, s.s);
        vm.prank(creator);
        (address coin,) = factory.launchWithPermit(p, s);
        assertGt(StokerCoin(coin).balanceOf(creator), 0);
    }

    function test_launch_refusesUnlistedQuote() public {
        StokerFactory.LaunchParams memory p = _params(true, 0);
        p.quote = address(0xBEEF);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.NotListed.selector, address(0xBEEF)));
        factory.launch(p);
    }

    function test_launch_refusesTheNativeAssetUntilListed() public {
        // The native asset is a Quote Asset like any other (#242): it needs a Listing first.
        StokerFactory.LaunchParams memory p = _params(true, 0);
        p.quote = address(0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.NotListed.selector, address(0)));
        factory.launch(p);
    }

    function test_launch_creatorCannotChooseTheShare() public {
        // The Creator's share is the factory's setting, written into the Launch's terms; LaunchParams has
        // no field for it. A Destination other than the Creator's wallet receives the same share.
        StokerFactory.LaunchParams memory p = _params(true, 1 ether);
        p.creatorDestination = stranger;
        vm.startPrank(creator);
        quote.approve(address(factory), 1 ether);
        factory.launch(p);
        vm.stopPrank();
        uint256 fee = _feeOnGross(1 ether);
        assertEq(_credit(stranger), fee * CREATOR_SHARE_BPS / 10_000);
        assertEq(_credit(creator), 0);
    }

    function test_launch_coinAddressCannotBeTakenByAnother() public {
        // The coin's CREATE2 salt includes the launcher, so a copied salt gives another address.
        StokerFactory.LaunchParams memory p = _params(true, 0);
        vm.prank(stranger);
        (address theirs,) = factory.launch(p);
        vm.prank(creator);
        (address mine,) = factory.launch(p);
        assertTrue(theirs != mine);
    }

    function test_launch_emitsTheTerms() public {
        StokerFactory.LaunchParams memory p = _params(true, 0);
        vm.recordLogs();
        vm.prank(creator);
        (address coin,) = factory.launch(p);
        StokerFactory.Launch memory l = factory.launchOf(_keyFor(coin).toId());
        assertEq(l.coin, coin);
        assertEq(l.quote, address(quote));
        assertEq(l.creator, creator);
        assertEq(hook.termsOf(_keyFor(coin).toId()).creatorDestination, creator);
        assertEq(hook.termsOf(_keyFor(coin).toId()).platformFeeBps, PLATFORM_FEE_BPS);
        assertEq(hook.termsOf(_keyFor(coin).toId()).creatorShareBps, CREATOR_SHARE_BPS);
    }

    function test_factory_refusesUnboundedSettings() public {
        vm.expectRevert(StokerFactory.InvalidSettings.selector);
        new StokerFactory(pm, listings, platform, 0, CREATOR_SHARE_BPS, TICK_SPACING, bytes32(0), taxVault);
        vm.expectRevert(StokerFactory.InvalidSettings.selector);
        new StokerFactory(pm, listings, platform, 1_001, CREATOR_SHARE_BPS, TICK_SPACING, bytes32(0), taxVault);
        vm.expectRevert(StokerFactory.InvalidSettings.selector);
        new StokerFactory(pm, listings, platform, PLATFORM_FEE_BPS, 10_001, TICK_SPACING, bytes32(0), taxVault);
        vm.expectRevert(StokerFactory.InvalidSettings.selector);
        new StokerFactory(
            pm, listings, address(0), PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, TICK_SPACING, bytes32(0), taxVault
        );
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = pm.getSlot0(key.toId());
    }
}
