// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {CountingRecipient} from "../utils/Recipients.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// Trades in a coin paired with the native asset take the Platform Fee in the native asset and record
/// Credits as for any Quote Asset, and no swap pays the native asset to a Creator or the platform (#242).
contract NativeFeesTest is LocalBase {
    using StateLibrary for IPoolManager;

    /// The Creator Earnings Destination: a contract that counts every payment that reaches it.
    CountingRecipient internal destination;

    struct Seen {
        uint256 quoteIn;
        uint256 quoteOut;
        uint256 fee;
        uint256 creatorCredit;
        uint256 platformCredit;
    }

    function setUp() public override {
        super.setUp();
        _listNative();
        destination = new CountingRecipient();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
    }

    function _swapAndSee(PoolKey memory key, bool buy, bool exactIn, uint256 amount) internal returns (Seen memory s) {
        uint256 q0 = trader.balance;
        uint256 claims0 = _nativeClaims();
        uint256 c0 = _nativeCredit(address(destination));
        uint256 p0 = _nativeCredit(platform);
        _swapNative(key, trader, buy, exactIn, amount, 100 ether);
        uint256 q1 = trader.balance;
        if (q0 > q1) s.quoteIn = q0 - q1;
        else s.quoteOut = q1 - q0;
        s.fee = _nativeClaims() - claims0;
        s.creatorCredit = _nativeCredit(address(destination)) - c0;
        s.platformCredit = _nativeCredit(platform) - p0;
        // No native transfer to either recipient inside a swap, and nothing left with the hook.
        assertEq(destination.payments(), 0, "no swap paid the Creator's Destination");
        assertEq(address(destination).balance, 0);
        assertEq(platform.balance, 0, "no swap paid the platform");
        assertEq(address(hook).balance, 0, "the hook holds no native asset");
        assertEq(address(swapRouter).balance, 0, "the router refunded every unspent wei");
        assertEq(s.creatorCredit + s.platformCredit, s.fee, "the Credits sum to the fee");
        assertEq(s.creatorCredit, s.fee * CREATOR_SHARE_BPS / 10_000, "the Creator's share");
    }

    function test_native_fee_buyExactIn() public {
        (, PoolKey memory key) = _launchNative(0, address(destination));
        Seen memory s = _swapAndSee(key, true, true, 0.5 ether);
        assertEq(s.quoteIn, 0.5 ether, "paid the specified amount");
        assertEq(s.fee, _feeOnGross(0.5 ether), "1.00% of what the trader paid");
        assertEq(s.fee, 0.005 ether);
    }

    function test_native_fee_buyExactOut() public {
        (address coin, PoolKey memory key) = _launchNative(0, address(destination));
        uint256 coins0 = IERC20(coin).balanceOf(trader);
        Seen memory s = _swapAndSee(key, true, false, 1e10 ether);
        assertEq(IERC20(coin).balanceOf(trader) - coins0, 1e10 ether, "received the specified coins");
        assertEq(s.fee, _feeOnNet(s.quoteIn - s.fee), "1.00% of what the trader paid, fee included");
    }

    function test_native_fee_sellExactIn() public {
        (address coin, PoolKey memory key) = _launchNative(0, address(destination));
        _swapNative(key, trader, true, true, 1 ether, 0);
        Seen memory s = _swapAndSee(key, false, true, IERC20(coin).balanceOf(trader) / 2);
        assertEq(s.fee, _feeOnGross(s.quoteOut + s.fee), "1.00% of the pool's output");
    }

    function test_native_fee_sellExactOut() public {
        (, PoolKey memory key) = _launchNative(0, address(destination));
        _swapNative(key, trader, true, true, 1 ether, 0);
        Seen memory s = _swapAndSee(key, false, false, 0.1 ether);
        assertEq(s.quoteOut, 0.1 ether, "received the specified native amount");
        assertEq(s.fee, _feeOnNet(0.1 ether), "1.00% of the pool's output, fee included");
    }

    function testFuzz_native_fee_isOnePercentOfTheNativeSide(bool buy, bool exactIn, uint256 amount) public {
        (address coin, PoolKey memory key) = _launchNative(0, address(destination));
        _swapNative(key, trader, true, true, 2 ether, 0);
        if (buy) amount = bound(amount, 1e6, exactIn ? 50 ether : 1e11 ether);
        else amount = bound(amount, 1e6, exactIn ? IERC20(coin).balanceOf(trader) : 1 ether);
        Seen memory s = _swapAndSee(key, buy, exactIn, amount);
        uint256 expected;
        if (buy && exactIn) expected = _feeOnGross(s.quoteIn);
        else if (buy) expected = _feeOnNet(s.quoteIn - s.fee);
        else if (exactIn) expected = _feeOnGross(s.quoteOut + s.fee);
        else expected = _feeOnNet(s.quoteOut);
        assertEq(s.fee, expected, "the fee is 1.00% of the native side");
    }

    function test_native_fee_tinySwapCannotBeSwallowed() public {
        (, PoolKey memory key) = _launchNative(0, address(destination));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(StokerHook.SwapTooSmall.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        _swapNativeApproved(key, trader, true, true, 1, 0, TickMath.MIN_SQRT_PRICE + 1);
    }

    // ------------------------------------------------ a swap its own price limit stops early

    function _limit(PoolKey memory key, bool buy, int24 ticks) internal view returns (uint160) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        return TickMath.getSqrtPriceAtTick(buy ? tick - ticks : tick + ticks);
    }

    function _stoppedEarly() internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(StokerHook.SwapStoppedEarly.selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// With the native asset as the specified side (an exact-in buy, an exact-out sell) the fee is taken
    /// before the pool runs, so a swap its own price limit stops early is refused in both directions.
    function test_native_fee_nativeSpecifiedSwapStoppedByItsLimit_reverts() public {
        (address coin, PoolKey memory key) = _launchNative(0, address(destination));
        _swapNative(key, trader, true, true, 2 ether, 0);
        vm.prank(trader);
        IERC20(coin).approve(address(swapRouter), type(uint256).max);

        // An exact-in buy of 50 its limit stops after a fraction.
        uint160 buyLimit = _limit(key, true, 400);
        vm.expectRevert(_stoppedEarly());
        _swapNativeApproved(key, trader, true, true, 50 ether, 0, buyLimit);

        // An exact-out sell of 1.5 its limit stops after a fraction.
        uint160 sellLimit = _limit(key, false, 400);
        vm.expectRevert(_stoppedEarly());
        _swapNativeApproved(key, trader, false, false, 1.5 ether, 0, sellLimit);

        // The same limits leave a swap they do not stop alone.
        uint256 claims0 = _nativeClaims();
        _swapNativeApproved(key, trader, true, true, 0.001 ether, 0, buyLimit);
        assertEq(_nativeClaims() - claims0, _feeOnGross(0.001 ether), "a limit that does not bind changes nothing");
        claims0 = _nativeClaims();
        _swapNativeApproved(key, trader, false, false, 0.001 ether, 0, _limit(key, false, 400));
        assertEq(_nativeClaims() - claims0, _feeOnNet(0.001 ether));
    }

    /// With the coin as the specified side the fee is taken on the native asset that really moved, so a
    /// swap its limit stops early pays exactly 1.00% of what it traded, in both directions.
    function test_native_fee_coinSpecifiedSwapStoppedByItsLimit_paysOnWhatItTraded() public {
        (address coin, PoolKey memory key) = _launchNative(0, address(destination));
        _swapNative(key, trader, true, true, 2 ether, 0);
        IERC20 c = IERC20(coin);
        vm.prank(trader);
        c.approve(address(swapRouter), type(uint256).max);

        // An exact-out buy of far more coins than the limit lets through, with value to spare.
        uint256 q0 = trader.balance;
        uint256 c0 = c.balanceOf(trader);
        uint256 claims0 = _nativeClaims();
        _swapNativeApproved(key, trader, true, false, 1e11 ether, 100 ether, _limit(key, true, 400));
        uint256 fee = _nativeClaims() - claims0;
        assertLt(c.balanceOf(trader) - c0, 1e11 ether, "stopped early");
        assertGt(fee, 0);
        assertEq(fee, _feeOnNet(q0 - trader.balance - fee), "1.00% of what the buy really paid");
        assertEq(address(swapRouter).balance, 0, "the unspent value refunded");

        // An exact-in sell of far more coins than the limit lets through.
        q0 = trader.balance;
        c0 = c.balanceOf(trader);
        claims0 = _nativeClaims();
        _swapNativeApproved(key, trader, false, true, c0, 0, _limit(key, false, 400));
        fee = _nativeClaims() - claims0;
        assertLt(c0 - c.balanceOf(trader), c0, "stopped early");
        assertGt(fee, 0);
        assertEq(fee, _feeOnGross(trader.balance - q0 + fee), "1.00% of what the pool really paid");
    }

    /// A coin paired with the native asset and one paired with an ERC-20 share the hook: each books in its
    /// own Quote Asset, and neither touches the other's Credits.
    function test_native_fee_booksApartFromAnERC20Launch() public {
        (, PoolKey memory nativeKey) = _launchNative(0, address(destination));
        (, PoolKey memory erc20Key) = _launch(true, 1 ether);
        uint256 erc20Claims = _hookClaims();
        uint256 erc20Credit = _credit(creator);
        _swapNative(nativeKey, trader, true, true, 1 ether, 0);
        assertEq(_hookClaims(), erc20Claims, "the ERC-20 claims untouched");
        assertEq(_credit(creator), erc20Credit);
        _swap(erc20Key, trader, true, true, 1 ether);
        assertEq(_nativeClaims(), _feeOnGross(1 ether), "the native claims untouched by the ERC-20 swap");
    }
}
