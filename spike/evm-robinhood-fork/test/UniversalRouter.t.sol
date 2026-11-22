// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// @notice #234 point 6: swaps through the Universal Router deployed on Robinhood Chain, against a
///         hook that returns deltas on both sides, priced first by the chain's V4 Quoter.
contract UniversalRouterTest is ForkBase {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;
    bytes4 internal constant TOO_LITTLE_PER_HOP = 0x4713c18b; // V4TooLittleReceivedPerHopSingle(uint256,uint256)

    /// @dev Universal Router 2.1.1's layout, with `minHopPriceX36`. The v4-periphery this spike
    ///      pins still has the older five-field struct, which the router would misread silently
    ///      (knowledge base, robinhood-chain/44-uniswap-v4-hooks.md), so it is written out here.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    function setUp() public override {
        super.setUp();
        vm.startPrank(trader);
        NVDA.approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(NVDA), UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _quote(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        internal
        returns (uint256 out)
    {
        (out,) = IV4Quoter(V4_QUOTER).quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams(key, zeroForOne, uint128(amountIn), hookData)
        );
    }

    function _execute(
        PoolKey memory key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minOut,
        uint256 minHopPriceX36,
        bytes memory hookData
    ) internal {
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams(key, zeroForOne, uint128(amountIn), uint128(minOut), minHopPriceX36, hookData)
        );
        params[1] = abi.encode(cin, amountIn);
        params[2] = abi.encode(cout, minOut);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL), params);
        vm.prank(trader);
        IUniversalRouter(UNIVERSAL_ROUTER).execute(abi.encodePacked(V4_SWAP), inputs, block.timestamp + 60);
    }

    function _permitCoin(PoolKey memory key) internal {
        vm.startPrank(trader);
        _coin(key).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(address(_coin(key)), UNIVERSAL_ROUTER, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    /// A buy and a sell through the router each deliver the Quoter's figure to the wei, with the
    /// hook's fee taken and the referrer from `hookData` paid in the same transaction.
    function _assertRoundTrip(bool quoteIsCurrency0) internal {
        (, PoolKey memory key) = _launch(_params(quoteIsCurrency0));
        bool buyZeroForOne = quoteIsCurrency0;
        bytes memory hookData = abi.encode(referrer);

        uint256 quoted = _quote(key, buyZeroForOne, 5 ether, hookData);
        uint256 coinBefore = _coin(key).balanceOf(trader);
        uint256 nvdaBefore = NVDA.balanceOf(trader);
        uint256 gasBefore = gasleft();
        _execute(key, buyZeroForOne, 5 ether, quoted, 0, hookData);
        emit log_named_uint("router buy gas (incl. prank)", gasBefore - gasleft());
        assertEq(_coin(key).balanceOf(trader) - coinBefore, quoted, "buy delivered the quote to the wei");
        assertEq(nvdaBefore - NVDA.balanceOf(trader), 5 ether);
        assertEq(NVDA.balanceOf(referrer), 0.005 ether, "referrer: a tenth of the 0.05 NVDA fee");
        assertEq(NVDA.balanceOf(creatorDestination), 0.025 ether);

        _permitCoin(key);
        uint256 sellAmount = _coin(key).balanceOf(trader) / 2;
        uint256 quotedOut = _quote(key, !buyZeroForOne, sellAmount, hookData);
        nvdaBefore = NVDA.balanceOf(trader);
        _execute(key, !buyZeroForOne, sellAmount, quotedOut, 0, hookData);
        assertEq(NVDA.balanceOf(trader) - nvdaBefore, quotedOut, "sell delivered the quote to the wei");
        // On a sell the fee is 1% of the gross the pool paid out: net = 99% of gross.
        uint256 sellFee = (NVDA.balanceOf(referrer) - 0.005 ether) * 10;
        assertApproxEqAbs(sellFee * 99, quotedOut, 10_000, "sell fee is 1% of the gross");
    }

    function test_router_roundTrip_quoteIsCurrency0() public {
        _assertRoundTrip(true);
    }

    function test_router_roundTrip_quoteIsCurrency1() public {
        _assertRoundTrip(false);
    }

    /// The six-field layout is the one the router reads: a per-hop floor just under the realised
    /// price passes and one just over reverts V4TooLittleReceivedPerHopSingle.
    function test_router_sixFieldLayout_perHopFloorBites() public {
        (, PoolKey memory key) = _launch(_params(true));
        uint256 quoted = _quote(key, true, 5 ether, "");
        uint256 price = quoted * 1e36 / 5 ether;

        uint256 snap = vm.snapshotState();
        vm.expectRevert(abi.encodeWithSelector(TOO_LITTLE_PER_HOP, price + 1, price));
        _execute(key, true, 5 ether, 0, price + 1, "");
        vm.revertToState(snap);

        uint256 before = _coin(key).balanceOf(trader);
        _execute(key, true, 5 ether, 0, price, "");
        assertEq(_coin(key).balanceOf(trader) - before, quoted);
    }

    /// A Reward Launch whose swap also burns and adds liquidity inside the hook still quotes
    /// exactly: the Quoter simulates the same nested work the swap does.
    function test_router_rewardLaunch_nestedFlushQuotesExactly() public {
        StokerFactory.LaunchParams memory p = _params(false);
        p.taxBps = 500;
        p.burnShareBps = 2_500;
        p.liquidityShareBps = 2_500;
        (, PoolKey memory key) = _launch(p);
        bool buy = false; // the coin is currency0, so a buy is oneForZero

        // Past Graduation, so every later swap burns and adds liquidity in the hook.
        uint256 q1 = _quote(key, buy, 150 ether, "");
        _execute(key, buy, 150 ether, q1, 0, "");
        StokerHook.State memory s = hook.state(key.toId());
        assertTrue(s.graduated);
        assertGt(s.lockedLiquidity, 0);

        uint256 before = _coin(key).balanceOf(trader);
        uint256 q2 = _quote(key, buy, 3 ether, "");
        _execute(key, buy, 3 ether, q2, 0, "");
        assertEq(_coin(key).balanceOf(trader) - before, q2, "quote matches with nested burn and add");
        assertGt(hook.state(key.toId()).lockedLiquidity, s.lockedLiquidity, "more liquidity locked");
        assertGt(hook.state(key.toId()).burnedCoins, s.burnedCoins, "more coins burned");
    }
}
