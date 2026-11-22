// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";

contract PlainQuote is ERC20 {
    constructor() ERC20("Fresh Quote", "FRESH") {
        _mint(msg.sender, 1e30);
    }
}

/// @notice #234 point 3: the Platform Fee on the Quote Asset's side, both directions, paid to three
///         recipients inside the swap, with the pool's LP fee at zero.
contract FeesTest is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_FEE_TOPIC = keccak256(
        "SwapFee(bytes32,bool,uint256,uint256,uint256,address,uint256,address,uint256,uint256)"
    );

    struct Bal {
        uint256 trader;
        uint256 creatorDest;
        uint256 ref;
        uint256 plat;
    }

    function _bal() internal view returns (Bal memory b) {
        b = Bal(NVDA.balanceOf(trader), NVDA.balanceOf(creatorDestination), NVDA.balanceOf(referrer), NVDA.balanceOf(platform));
    }

    /// @dev Runs one swap and checks: the fee is 1% of the gross NVDA side (rounded up), its three
    ///      shares reached their wallets in the same transaction, and they add up to the fee.
    function _assertFee(bool quoteIsCurrency0, bool buy, bool exactIn) internal {
        StokerFactory.LaunchParams memory p = _params(quoteIsCurrency0);
        p.firstBuy = 5 ether;
        (, PoolKey memory key) = _launch(p);
        // The trader needs coins to sell.
        if (!buy) _swap(key, trader, true, true, 20 ether, "");

        Bal memory b0 = _bal();
        uint256 coinBefore = _coin(key).balanceOf(trader);
        uint256 amount = buy ? (exactIn ? 3 ether : 1e29) : (exactIn ? coinBefore / 2 : 2 ether);
        vm.recordLogs();
        _swap(key, trader, buy, exactIn, amount, abi.encode(referrer));
        Bal memory b1 = _bal();

        // The gross NVDA amount of the trade, from the trader's own balances.
        uint256 quoteMoved = buy ? b0.trader - b1.trader : b1.trader - b0.trader;
        uint256 creatorShare = b1.creatorDest - b0.creatorDest;
        uint256 referrerShare = b1.ref - b0.ref;
        uint256 platformShare = b1.plat - b0.plat;
        uint256 fee = creatorShare + referrerShare + platformShare;
        uint256 gross = buy ? quoteMoved : quoteMoved + fee;

        assertApproxEqAbs(fee, gross / 100, 2, "fee is 1% of the gross Quote Asset side");
        assertGe(fee * 100, gross, "rounded in the platform's favour");
        assertEq(referrerShare, fee / 10, "referrer: a tenth of the Platform Fee");
        assertEq(creatorShare, fee / 2, "creator: half of the Platform Fee");
        assertEq(platformShare, fee - creatorShare - referrerShare, "platform: the rest");
        if (exactIn && buy) assertEq(quoteMoved, amount, "exact in");
        if (!exactIn && !buy) assertEq(quoteMoved, amount, "exact out: the trader got exactly what was asked");

        // Nothing was left owed: all three shares were pushed, none deferred.
        assertEq(hook.owed(creatorDestination, Currency.wrap(address(NVDA))), 0);
        assertEq(hook.owed(platform, Currency.wrap(address(NVDA))), 0);

        // The SwapFee event says the same, in the same transaction.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != SWAP_FEE_TOPIC) continue;
            (uint256 eGross, uint256 ePlatformFee,,, uint256 eCreator,, uint256 eRef, uint256 ePlat) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, address, uint256, address, uint256, uint256));
            assertEq(eGross, gross, "event gross");
            assertEq(ePlatformFee, fee, "event fee");
            assertEq(eCreator + eRef + ePlat, fee, "shares sum to the fee");
            assertEq(logs[i].topics[2], bytes32(uint256(buy ? 1 : 0)), "event side");
            seen = true;
        }
        assertTrue(seen, "SwapFee emitted");
    }

    function test_fee_buy_exactIn() public {
        _assertFee(true, true, true);
        _assertFee(false, true, true);
    }

    function test_fee_buy_exactOut() public {
        _assertFee(true, true, false);
        _assertFee(false, true, false);
    }

    function test_fee_sell_exactIn() public {
        _assertFee(true, false, true);
        _assertFee(false, false, true);
    }

    function test_fee_sell_exactOut() public {
        _assertFee(true, false, false);
        _assertFee(false, false, false);
    }

    /// Without a referrer in hookData the platform keeps the referrer's tenth.
    function test_fee_noReferrer_platformKeepsTheShare() public {
        (, PoolKey memory key) = _launch(_params(true));
        Bal memory b0 = _bal();
        _swap(key, trader, true, true, 10 ether, "");
        Bal memory b1 = _bal();
        assertEq(b1.ref, b0.ref);
        assertEq(b1.creatorDest - b0.creatorDest, 0.05 ether, "half of 0.1 NVDA");
        assertEq(b1.plat - b0.plat, 0.05 ether, "the other half");
    }

    /// A Creator Destination the stock token's registry blocks would revert every push. The hook
    /// catches the failed push and records a claim, so the pool keeps trading.
    function test_fee_blockedRecipient_doesNotBrickThePool() public {
        (, PoolKey memory key) = _launch(_params(true));
        // The stock tokens ask this registry about both parties of every transfer.
        vm.mockCall(
            STOCK_REGISTRY, abi.encodeWithSignature("isBlocked(address)", creatorDestination), abi.encode(true)
        );
        uint256 before = NVDA.balanceOf(creatorDestination);
        _swap(key, trader, true, true, 10 ether, abi.encode(referrer));
        assertEq(NVDA.balanceOf(creatorDestination), before, "the push was refused");
        assertEq(hook.owed(creatorDestination, Currency.wrap(address(NVDA))), 0.05 ether, "owed instead");
        assertEq(NVDA.balanceOf(referrer), 0.01 ether, "the other shares still pushed");

        // Once unblocked, the Creator Destination claims what it is owed.
        vm.clearMockedCalls();
        vm.prank(creatorDestination);
        hook.claim(Currency.wrap(address(NVDA)));
        assertEq(NVDA.balanceOf(creatorDestination), before + 0.05 ether);
        assertEq(hook.owed(creatorDestination, Currency.wrap(address(NVDA))), 0);
    }

    /// The registry check is real: a mocked block on the trader stops the trader's own swap, which
    /// shows the mock above reaches the stock token's transfer path.
    function test_fee_registryBlockReachesTheTransferPath() public {
        (, PoolKey memory key) = _launch(_params(true));
        // The allowance is in place before the block (approve is itself blocklist-checked).
        _swap(key, trader, true, true, 1 ether, "");
        vm.mockCall(STOCK_REGISTRY, abi.encodeWithSignature("isBlocked(address)", trader), abi.encode(true));
        // approve is checked too.
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x75e91ce7), trader));
        NVDA.approve(address(swapRouter), 1);
        bool q0 = _isQuote0(key);
        vm.prank(trader);
        // The stock token's own error, Blocked(address), selector 0x75e91ce7.
        vm.expectRevert(abi.encodeWithSelector(bytes4(0x75e91ce7), trader));
        swapRouter.swap(key, _buyParams(q0, 1 ether), _settings(), "");
    }

    /// A Quote Asset the PoolManager holds none of: when a router swaps before it settles (as the
    /// Universal Router's SWAP, SETTLE_ALL, TAKE_ALL order does), the in-swap push has nothing to
    /// take from, so each share falls back to a claim instead of reverting the swap.
    function test_fee_freshQuote_swapBeforeSettle_fallsBackToClaims() public {
        PlainQuote fresh = new PlainQuote();
        assertEq(fresh.balanceOf(address(POOL_MANAGER)), 0);
        factory.list(address(fresh), START_TICK, GRADUATION_TICK, FLUSH_THRESHOLD);
        StokerFactory.LaunchParams memory p = _params(true);
        p.quote = address(fresh);
        p.salt = bytes32(0);
        vm.prank(creator);
        (address coin,) = factory.launch(p);
        bool q0 = address(fresh) < coin;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(q0 ? address(fresh) : coin),
            currency1: Currency.wrap(q0 ? coin : address(fresh)),
            fee: 0,
            tickSpacing: 200,
            hooks: hook
        });

        fresh.transfer(trader, 100 ether);
        vm.startPrank(trader);
        fresh.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            _buyParams(q0, 10 ether),
            _settings(),
            ""
        );
        vm.stopPrank();
        assertEq(fresh.balanceOf(creatorDestination), 0, "nothing could be pushed");
        assertEq(hook.owed(creatorDestination, Currency.wrap(address(fresh))), 0.05 ether, "owed instead");
        assertEq(hook.owed(platform, Currency.wrap(address(fresh))), 0.05 ether, "owed instead");

        // Once the PoolManager holds the currency, the next trade's shares are pushed.
        vm.prank(trader);
        swapRouter.swap(key, _buyParams(q0, 10 ether), _settings(), "");
        assertEq(fresh.balanceOf(creatorDestination), 0.05 ether, "pushed this time");
    }

    /// The factory settles the First Buy's Quote Asset before it swaps, so even on a fresh Quote
    /// Asset the in-swap shares are pushed, not deferred.
    function test_fee_freshQuote_settleFirst_pushes() public {
        PlainQuote fresh = new PlainQuote();
        factory.list(address(fresh), START_TICK, GRADUATION_TICK, FLUSH_THRESHOLD);
        StokerFactory.LaunchParams memory p = _params(true);
        p.quote = address(fresh);
        p.salt = bytes32(0);
        p.firstBuy = 10 ether;
        fresh.transfer(creator, 10 ether);
        vm.startPrank(creator);
        fresh.approve(address(factory), 10 ether);
        factory.launch(p);
        vm.stopPrank();
        assertEq(fresh.balanceOf(creatorDestination), 0.05 ether, "pushed in the launch");
        assertEq(hook.owed(creatorDestination, Currency.wrap(address(fresh))), 0);
    }

    function _buyParams(bool q0, uint256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: q0,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: q0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    /// The pool's LP fee is zero and stays zero: the key's static fee is 0 and the hook returns no
    /// fee override, so the whole charge is the hook's.
    function test_fee_lpFeeIsZero() public {
        (, PoolKey memory key) = _launch(_params(false));
        assertEq(key.fee, 0);
        _swap(key, trader, true, true, 10 ether, "");
        (,,, uint24 lpFee) = POOL_MANAGER.getSlot0(key.toId());
        assertEq(lpFee, 0);
    }
}
