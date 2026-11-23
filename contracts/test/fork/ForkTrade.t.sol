// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.sol";
import {RouterLib, IUniversalRouter, IV4Quoter, IPermit2Allowance, IStateView, IV4FeeAdapter} from "./RouterLib.sol";

/// Trading through the Universal Router the chain's traffic uses, priced by the chain's V4 Quoter, with
/// the hook keeping the books (#241's fork criteria on trades, Credits, Payout Calls and the protocol fee).
contract ForkTradeTest is ForkBase {
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);
    error V4TooLittleReceivedPerHopSingle(uint256 minPrice, uint256 price);

    /// The Universal Router a test trades through: the one carrying the chain's traffic unless a test
    /// names the other.
    address internal router = UNIVERSAL_ROUTER;

    struct Trade {
        bool buy;
        bool exactIn;
        uint256 amount; // the specified amount: paid in on exact in, received on exact out
    }

    function _currencies(PoolKey memory key, bool buy) internal view returns (Currency cin, Currency cout) {
        Currency q = Currency.wrap(address(quote));
        Currency c = Currency.wrap(address(_coin(key)));
        return buy ? (q, c) : (c, q);
    }

    function _approveRouter(address who, PoolKey memory key) internal {
        vm.startPrank(who);
        quote.approve(PERMIT2, type(uint256).max);
        _coin(key).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(address(quote), router, type(uint160).max, type(uint48).max);
        IPermit2Allowance(PERMIT2).approve(address(_coin(key)), router, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// The Quoter's figure for a trade: what comes out on exact in, what goes in on exact out.
    function _quote(PoolKey memory key, Trade memory t) internal returns (uint256) {
        bool zeroForOne = t.buy == _isQuote0(key);
        IV4Quoter.QuoteExactSingleParams memory q =
            IV4Quoter.QuoteExactSingleParams(key, zeroForOne, uint128(t.amount), "");
        (uint256 figure,) =
            t.exactIn ? IV4Quoter(V4_QUOTER).quoteExactInputSingle(q) : IV4Quoter(V4_QUOTER).quoteExactOutputSingle(q);
        return figure;
    }

    /// One trade through the router with `limit` as the slippage bound: the minimum out on exact in, the
    /// maximum in on exact out.
    function _route(address who, PoolKey memory key, Trade memory t, uint256 limit, uint256 minHopPriceX36) internal {
        bool zeroForOne = t.buy == _isQuote0(key);
        (Currency cin, Currency cout) = _currencies(key, t.buy);
        bytes memory actions;
        bytes[] memory params = new bytes[](3);
        if (t.exactIn) {
            actions = abi.encodePacked(RouterLib.SWAP_EXACT_IN_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL);
            params[0] = abi.encode(
                RouterLib.ExactInputSingleParams(key, zeroForOne, uint128(t.amount), uint128(limit), minHopPriceX36, "")
            );
            params[1] = abi.encode(cin, t.amount);
            params[2] = abi.encode(cout, limit);
        } else {
            actions = abi.encodePacked(RouterLib.SWAP_EXACT_OUT_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL);
            params[0] = abi.encode(
                RouterLib.ExactOutputSingleParams(key, zeroForOne, uint128(t.amount), uint128(limit), 0, "")
            );
            params[1] = abi.encode(cin, limit);
            params[2] = abi.encode(cout, t.amount);
        }
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        vm.prank(who);
        IUniversalRouter(router).execute(abi.encodePacked(RouterLib.V4_SWAP), inputs, block.timestamp + 60);
    }

    function _balances(address who, PoolKey memory key) internal view returns (uint256 q, uint256 c) {
        return (quote.balanceOf(who), _coin(key).balanceOf(who));
    }

    /// Buys and sells, exact in and exact out, deliver the Quoter's figure to the wei, and a bound one wei
    /// tighter than it reverts.
    function test_fork_router_fourTradesDeliverTheQuote_bothOrders() public {
        _fourTradesDeliverTheQuote();
    }

    /// The same four trades through Universal Router v2.1.2, which a growing minority of the chain's
    /// traffic uses.
    function test_fork_router_v212_fourTradesDeliverTheQuote_bothOrders() public {
        assertGt(UNIVERSAL_ROUTER_V2_1_2.code.length, 0, "v2.1.2 is deployed at the pinned block");
        router = UNIVERSAL_ROUTER_V2_1_2;
        _fourTradesDeliverTheQuote();
    }

    function _fourTradesDeliverTheQuote() internal {
        for (uint256 o; o < 2; o++) {
            (, PoolKey memory key) = _launch(o == 0, 1 ether);
            _approveRouter(trader, key);
            Trade[4] memory trades = [
                Trade(true, true, 10 ether),
                Trade(true, false, 1e10 ether),
                Trade(false, true, 1e10 ether),
                Trade(false, false, 2 ether)
            ];
            for (uint256 i; i < trades.length; i++) {
                Trade memory t = trades[i];
                uint256 figure = _quote(key, t);

                // One wei tighter than the figure: refused.
                uint256 snap = vm.snapshotState();
                if (t.exactIn) {
                    vm.expectRevert(abi.encodeWithSelector(V4TooLittleReceived.selector, figure + 1, figure));
                    _route(trader, key, t, figure + 1, 0);
                } else {
                    vm.expectRevert(abi.encodeWithSelector(V4TooMuchRequested.selector, figure - 1, figure));
                    _route(trader, key, t, figure - 1, 0);
                }
                vm.revertToState(snap);

                // At the figure: delivered to the wei.
                (uint256 q0, uint256 c0) = _balances(trader, key);
                _route(trader, key, t, figure, 0);
                (uint256 q1, uint256 c1) = _balances(trader, key);
                if (t.buy && t.exactIn) {
                    assertEq(q0 - q1, t.amount, "paid");
                    assertEq(c1 - c0, figure, "buy exact in: the Quoter's coins");
                } else if (t.buy) {
                    assertEq(q0 - q1, figure, "buy exact out: the Quoter's price");
                    assertEq(c1 - c0, t.amount, "received");
                } else if (t.exactIn) {
                    assertEq(c0 - c1, t.amount, "sold");
                    assertEq(q1 - q0, figure, "sell exact in: the Quoter's proceeds");
                } else {
                    assertEq(c0 - c1, figure, "sell exact out: the Quoter's coins");
                    assertEq(q1 - q0, t.amount, "received");
                }
            }
        }
    }

    /// The router reads the six-field struct: a per-hop floor one above the realised price reverts.
    function test_fork_router_sixFieldLayout_perHopFloorBites() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _approveRouter(trader, key);
        Trade memory t = Trade(true, true, 5 ether);
        uint256 out = _quote(key, t);
        uint256 price = out * 1e36 / t.amount;
        uint256 snap = vm.snapshotState();
        vm.expectRevert(abi.encodeWithSelector(V4TooLittleReceivedPerHopSingle.selector, price + 1, price));
        _route(trader, key, t, out, price + 1);
        vm.revertToState(snap);
        _route(trader, key, t, out, price);
    }

    /// Each swap credits exactly 1.00% of the Quote Asset's side, split between the Creator and the
    /// platform, with no transfer to either.
    function test_fork_fee_eachSwapCreditsOnePercent_noTransfer() public {
        for (uint256 o; o < 2; o++) {
            (, PoolKey memory key) = _launch(o == 0, 0);
            _approveRouter(trader, key);
            Trade[4] memory trades = [
                Trade(true, true, 10 ether),
                Trade(true, false, 1e10 ether),
                Trade(false, true, 1e10 ether),
                Trade(false, false, 2 ether)
            ];
            for (uint256 i; i < trades.length; i++) {
                Trade memory t = trades[i];
                uint256 figure = _quote(key, t);
                uint256 cc0 = _credit(creator);
                uint256 pc0 = _credit(platform);
                uint256 claims0 = _hookClaims();
                (uint256 cq0, uint256 pq0) = (quote.balanceOf(creator), quote.balanceOf(platform));
                (uint256 q0,) = _balances(trader, key);
                _route(trader, key, t, figure, 0);
                (uint256 q1,) = _balances(trader, key);

                uint256 fee = _hookClaims() - claims0;
                uint256 expected;
                if (t.buy && t.exactIn) expected = _feeOnGross(q0 - q1);
                else if (t.buy) expected = _feeOnNet(q0 - q1 - fee);
                else if (t.exactIn) expected = _feeOnGross(q1 - q0 + fee);
                else expected = _feeOnNet(q1 - q0);
                assertEq(fee, expected, "1.00% of the Quote Asset's side");
                assertGt(fee, 0);
                uint256 cc = _credit(creator) - cc0;
                uint256 pc = _credit(platform) - pc0;
                assertEq(cc + pc, fee, "the Credits sum to the fee");
                assertEq(cc, fee * CREATOR_SHARE_BPS / 10_000, "the Creator's tier");
                assertEq(quote.balanceOf(creator), cq0, "no transfer to the Creator");
                assertEq(quote.balanceOf(platform), pq0, "no transfer to the platform");
                assertEq(quote.balanceOf(address(hook)), 0, "the hook holds no NVDA");
            }
        }
    }

    /// A Payout Call by a stranger pays each Credit to its owner alone; with the Creator blocked by the
    /// Stock Token's registry, swaps still succeed, the platform is still paid and the Creator stays owed.
    function test_fork_payout_strangerPays_blockedCreatorStaysOwed() public {
        (, PoolKey memory key) = _launch(false, 1 ether);
        _approveRouter(trader, key);
        _route(trader, key, Trade(true, true, 20 ether), 0, 0);

        address[] memory owners = new address[](2);
        owners[0] = creator;
        owners[1] = platform;

        // A stranger pays both, each to its owner.
        uint256 cc = _credit(creator);
        uint256 pc = _credit(platform);
        uint256 creatorBefore = quote.balanceOf(creator);
        uint256 strangerBefore = quote.balanceOf(stranger);
        vm.prank(stranger);
        hook.payout(Currency.wrap(NVDA), owners);
        assertEq(quote.balanceOf(creator) - creatorBefore, cc, "the Creator paid");
        assertEq(quote.balanceOf(platform), pc, "the platform paid");
        assertEq(quote.balanceOf(stranger), strangerBefore, "the caller gains nothing");
        assertEq(_hookClaims(), 0);

        // The issuer blocks the Creator: swaps go on, crediting them; the platform is paid; they stay owed.
        _block(creator);
        _route(trader, key, Trade(true, true, 10 ether), 0, 0);
        _route(trader, key, Trade(false, true, _coin(key).balanceOf(trader) / 2), 0, 0);
        cc = _credit(creator);
        pc = _credit(platform);
        assertGt(cc, 0);
        uint256 platformBefore = quote.balanceOf(platform);
        vm.prank(stranger);
        hook.payout(Currency.wrap(NVDA), owners);
        assertEq(quote.balanceOf(platform) - platformBefore, pc, "the platform still paid");
        assertEq(_credit(creator), cc, "the Creator's Credit stays owed to the Creator");
        assertEq(_hookClaims(), cc, "and stays backed");

        // Unblocked, the same call pays it.
        vm.clearMockedCalls();
        creatorBefore = quote.balanceOf(creator);
        hook.payout(Currency.wrap(NVDA), owners);
        assertEq(quote.balanceOf(creator) - creatorBefore, cc);
    }

    /// The protocol fee in force on the pool is read from the PoolManager (through the chain's StateView,
    /// as the API will read it) and appears in the Quoter's figure, which the router then delivers.
    function test_fork_protocolFee_readFromTheChain_inTheQuote() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _approveRouter(trader, key);
        bytes32 id = PoolId.unwrap(key.toId());
        (,, uint24 before,) = IStateView(STATE_VIEW).getSlot0(id);
        assertEq(before, 0, "no protocol fee on a new pool");

        Trade memory t = Trade(true, true, 10 ether);
        uint256 quoteWithout = _quote(key, t);

        // Uniswap's controller switches a fee on: 0.05% each way (500 pips in each 12-bit half).
        uint24 protocolFee = 500 | (500 << 12);
        vm.prank(PROTOCOL_FEE_CONTROLLER);
        IPoolManager(address(pm)).setProtocolFee(key, protocolFee);
        (,, uint24 inForce,) = IStateView(STATE_VIEW).getSlot0(id);
        assertEq(inForce, protocolFee, "read from the chain");

        uint256 quoteWith = _quote(key, t);
        assertLt(quoteWith, quoteWithout, "the quote includes the protocol fee");
        emit log_named_uint("coins quoted without the protocol fee", quoteWithout);
        emit log_named_uint("coins quoted with 0.05%", quoteWith);

        uint256 claims0 = _hookClaims();
        (, uint256 c0) = _balances(trader, key);
        _route(trader, key, t, quoteWith, 0);
        (, uint256 c1) = _balances(trader, key);
        assertEq(c1 - c0, quoteWith, "delivered as quoted");
        assertEq(_hookClaims() - claims0, _feeOnGross(10 ether), "our fee is unchanged by Uniswap's");
    }

    /// Anyone may push the controller's policy figure into the PoolManager (`triggerFeeUpdate`). Under
    /// the policy in force a pool whose hook returns deltas, as ours does, resolves to its default, 0, so
    /// a stranger's trigger leaves a Stoker pool paying no protocol fee (#249's finding, on our own hook).
    function test_fork_protocolFee_strangerTriggersThePolicy_ourPoolPaysNothing() public {
        for (uint256 o; o < 2; o++) {
            (, PoolKey memory key) = _launch(o == 0, 1 ether);
            assertEq(IV4FeeAdapter(PROTOCOL_FEE_CONTROLLER).getFee(key), 0, "the policy's figure for our pool");
            vm.prank(stranger);
            IV4FeeAdapter(PROTOCOL_FEE_CONTROLLER).triggerFeeUpdate(key);
            (,, uint24 inForce,) = IStateView(STATE_VIEW).getSlot0(PoolId.unwrap(key.toId()));
            assertEq(inForce, 0, "no protocol fee in force after the trigger");
        }
    }

    /// Multi-hop: one router call sells coin A for NVDA and buys coin B with it, so the hook runs twice in
    /// one transaction, once per pool, and books each swap's fee to that Launch's own Creator.
    function test_fork_router_multiHopThroughTwoLaunches() public {
        (address coinA, PoolKey memory keyA) = _launch(true, 1 ether);
        address creatorA = creator;
        // A second Creator launches coin B on the same hook.
        (creator, creatorKey) = makeAddrAndKey("creatorB");
        deal(NVDA, creator, 10 ether);
        (address coinB, PoolKey memory keyB) = _launch(false, 1 ether);
        address creatorB = creator;

        _approveRouter(trader, keyA);
        _approveRouter(trader, keyB);
        _route(trader, keyA, Trade(true, true, 10 ether), 0, 0);
        uint256 sell = IERC20(coinA).balanceOf(trader) / 2;

        uint256 a0 = _credit(creatorA);
        uint256 b0 = _credit(creatorB);
        uint256 claims0 = _hookClaims();
        uint256 nvda0 = quote.balanceOf(trader);

        RouterLib.PathKey[] memory path = new RouterLib.PathKey[](2);
        path[0] = RouterLib.PathKey(Currency.wrap(NVDA), 0, TICK_SPACING, keyA.hooks, "");
        path[1] = RouterLib.PathKey(Currency.wrap(coinB), 0, TICK_SPACING, keyB.hooks, "");
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RouterLib.ExactInputParams(Currency.wrap(coinA), path, new uint256[](0), uint128(sell), uint128(1))
        );
        params[1] = abi.encode(Currency.wrap(coinA), sell);
        params[2] = abi.encode(Currency.wrap(coinB), uint256(1));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] =
            abi.encode(abi.encodePacked(RouterLib.SWAP_EXACT_IN, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL), params);
        vm.prank(trader);
        IUniversalRouter(router).execute(abi.encodePacked(RouterLib.V4_SWAP), inputs, block.timestamp + 60);

        assertGt(IERC20(coinB).balanceOf(trader), 0, "coin B delivered");
        assertEq(quote.balanceOf(trader), nvda0, "no NVDA left with the trader");
        uint256 creditA = _credit(creatorA) - a0;
        uint256 creditB = _credit(creatorB) - b0;
        assertGt(creditA, 0, "the sell in pool A credited A's Creator");
        assertGt(creditB, 0, "the buy in pool B credited B's Creator");
        uint256 fees = _hookClaims() - claims0;
        // Each pool's fee splits evenly at the first tier, so the Creators hold half of each, rounded down.
        assertApproxEqAbs(creditA + creditB, fees / 2, 1, "each Creator holds their pool's share");
        coinA;
        coinB;
    }
}
