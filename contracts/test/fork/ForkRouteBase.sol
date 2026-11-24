// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.sol";
import {RouterLib, IUniversalRouter, IV4Quoter, IPermit2Allowance} from "./RouterLib.sol";

/// @notice One trade through either Universal Router, priced by the chain's V4 Quoter, in a coin paired
///         with NVDA or with native ETH, carrying the `hookData` a front-end would put in it (#243). A
///         small base, so each fork contract over it stays clear of the compiler's stack limit (gotcha 9).
abstract contract ForkRouteBase is ForkBase {
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);

    struct Trade {
        bool buy;
        bool exactIn;
        uint256 amount; // the specified amount: paid in on exact in, received on exact out
    }

    /// What the trader saw, measured from outside.
    struct Seen {
        uint256 quoteMoved; // Quote Asset paid (buys) or received (sells)
        uint256 coinsMoved; // coins received (buys) or paid (sells)
        uint256 fee; // what the hook's claims grew by
    }

    function setUp() public virtual override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 100 ether);
    }

    function _isNative(PoolKey memory key) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(0);
    }

    function _quoteOf(PoolKey memory key) internal view returns (Currency) {
        return _isNative(key) ? key.currency0 : Currency.wrap(address(quote));
    }

    function _coinOf(PoolKey memory key) internal view returns (IERC20) {
        return _isNative(key) ? IERC20(Currency.unwrap(key.currency1)) : _coin(key);
    }

    function _quoteBalance(PoolKey memory key, address who) internal view returns (uint256) {
        return _isNative(key) ? who.balance : quote.balanceOf(who);
    }

    function _claimsOf(PoolKey memory key) internal view returns (uint256) {
        return _isNative(key) ? _nativeClaims() : _hookClaims();
    }

    function _creditIn(PoolKey memory key, address owner) internal view returns (uint256) {
        return hook.creditOf(owner, _quoteOf(key));
    }

    function _zeroForOne(PoolKey memory key, bool buy) internal view returns (bool) {
        return _isNative(key) ? buy : buy == _isQuote0(key);
    }

    function _approveFor(address router, address who, PoolKey memory key) internal {
        vm.startPrank(who);
        address coin = address(_coinOf(key));
        IERC20(coin).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(coin, router, type(uint160).max, type(uint48).max);
        if (!_isNative(key)) {
            quote.approve(PERMIT2, type(uint256).max);
            IPermit2Allowance(PERMIT2).approve(address(quote), router, type(uint160).max, type(uint48).max);
        }
        vm.stopPrank();
    }

    /// The Quoter's figure for a trade carrying `hookData`: what comes out on exact in, what goes in on
    /// exact out.
    function _quoteTrade(PoolKey memory key, Trade memory t, bytes memory hookData) internal returns (uint256 figure) {
        IV4Quoter.QuoteExactSingleParams memory q =
            IV4Quoter.QuoteExactSingleParams(key, _zeroForOne(key, t.buy), uint128(t.amount), hookData);
        (figure,) =
            t.exactIn ? IV4Quoter(V4_QUOTER).quoteExactInputSingle(q) : IV4Quoter(V4_QUOTER).quoteExactOutputSingle(q);
    }

    /// The router's call for one trade with `limit` as its slippage bound (the minimum out on exact in, the
    /// maximum in on exact out), the six-field structs written by hand, and the native value a buy sends.
    function _routeCall(PoolKey memory key, Trade memory t, uint256 limit, bytes memory hookData)
        internal
        view
        returns (bytes[] memory inputs, uint256 value)
    {
        bool zeroForOne = _zeroForOne(key, t.buy);
        Currency q = _quoteOf(key);
        Currency c = Currency.wrap(address(_coinOf(key)));
        (Currency cin, Currency cout) = t.buy ? (q, c) : (c, q);
        bytes memory actions;
        bytes[] memory params = new bytes[](3);
        if (t.exactIn) {
            actions = abi.encodePacked(RouterLib.SWAP_EXACT_IN_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL);
            params[0] = abi.encode(
                RouterLib.ExactInputSingleParams(key, zeroForOne, uint128(t.amount), uint128(limit), 0, hookData)
            );
            params[1] = abi.encode(cin, t.amount);
            params[2] = abi.encode(cout, limit);
        } else {
            actions = abi.encodePacked(RouterLib.SWAP_EXACT_OUT_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL);
            params[0] = abi.encode(
                RouterLib.ExactOutputSingleParams(key, zeroForOne, uint128(t.amount), uint128(limit), 0, hookData)
            );
            params[1] = abi.encode(cin, limit);
            params[2] = abi.encode(cout, t.amount);
        }
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        value = _isNative(key) && t.buy ? (t.exactIn ? t.amount : limit) : 0;
    }

    function _route(
        address router,
        address who,
        PoolKey memory key,
        Trade memory t,
        uint256 limit,
        bytes memory hookData
    ) internal {
        (bytes[] memory inputs, uint256 value) = _routeCall(key, t, limit, hookData);
        vm.prank(who);
        IUniversalRouter(router).execute{value: value}(
            abi.encodePacked(RouterLib.V4_SWAP), inputs, block.timestamp + 60
        );
    }

    /// One trade at the Quoter's figure, measured from outside.
    function _routeAndSee(address router, PoolKey memory key, Trade memory t, bytes memory hookData)
        internal
        returns (uint256 figure, Seen memory s)
    {
        figure = _quoteTrade(key, t, hookData);
        IERC20 coin = _coinOf(key);
        (uint256 q0, uint256 c0, uint256 h0) = (_quoteBalance(key, trader), coin.balanceOf(trader), _claimsOf(key));
        _route(router, trader, key, t, figure, hookData);
        (uint256 q1, uint256 c1) = (_quoteBalance(key, trader), coin.balanceOf(trader));
        s.quoteMoved = t.buy ? q0 - q1 : q1 - q0;
        s.coinsMoved = t.buy ? c1 - c0 : c0 - c1;
        s.fee = _claimsOf(key) - h0;
    }

    /// The four trades every fork test of a referrer runs, after a First Buy, in the order the figures
    /// recorded from `main` ran them.
    function _fourTrades(PoolKey memory key) internal pure returns (Trade[4] memory trades) {
        if (_isNative(key)) {
            trades = [
                Trade(true, true, 1 ether),
                Trade(true, false, 1e10 ether),
                Trade(false, true, 1e10 ether),
                Trade(false, false, 0.05 ether)
            ];
        } else {
            trades = [
                Trade(true, true, 10 ether),
                Trade(true, false, 1e10 ether),
                Trade(false, true, 1e10 ether),
                Trade(false, false, 2 ether)
            ];
        }
    }
}
