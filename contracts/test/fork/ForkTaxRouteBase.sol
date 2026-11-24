// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkTaxBase} from "./ForkTaxBase.sol";
import {RouterLib, IUniversalRouter, IV4Quoter, IPermit2Allowance} from "./RouterLib.sol";

/// @notice One trade through either Universal Router, priced by the chain's V4 Quoter, in a coin paired
///         with NVDA or with native ETH, for the tax's fork tests (#245).
abstract contract ForkTaxRouteBase is ForkTaxBase {
    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);

    struct Trade {
        bool buy;
        bool exactIn;
        uint256 amount; // the specified amount: paid in on exact in, received on exact out
    }

    function _zeroForOne(PoolKey memory key, bool buy) internal view returns (bool) {
        return buy == _quoteIsCurrency0(key);
    }

    function _approveFor(address router, address who, PoolKey memory key) internal {
        vm.startPrank(who);
        address coin = address(_coinOfKey(key));
        IERC20(coin).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(coin, router, type(uint160).max, type(uint48).max);
        if (!_native(key)) {
            quote.approve(PERMIT2, type(uint256).max);
            IPermit2Allowance(PERMIT2).approve(address(quote), router, type(uint160).max, type(uint48).max);
        }
        vm.stopPrank();
    }

    /// The Quoter's figure for a trade: what comes out on exact in, what goes in on exact out.
    function _quoteTrade(PoolKey memory key, Trade memory t) internal returns (uint256 figure) {
        return _quoteTrade(key, t, "");
    }

    /// The same, for a trade carrying `hookData` (a referrer and a Referrer Fee, #243).
    function _quoteTrade(PoolKey memory key, Trade memory t, bytes memory hookData) internal returns (uint256 figure) {
        IV4Quoter.QuoteExactSingleParams memory q =
            IV4Quoter.QuoteExactSingleParams(key, _zeroForOne(key, t.buy), uint128(t.amount), hookData);
        (figure,) =
            t.exactIn ? IV4Quoter(V4_QUOTER).quoteExactInputSingle(q) : IV4Quoter(V4_QUOTER).quoteExactOutputSingle(q);
    }

    /// One trade through `router` with `limit` as the slippage bound: the minimum out on exact in, the
    /// maximum in on exact out. A native buy sends its side as value.
    function _route(address router, address who, PoolKey memory key, Trade memory t, uint256 limit) internal {
        _route(router, who, key, t, limit, "");
    }

    /// The same, carrying `hookData`.
    function _route(
        address router,
        address who,
        PoolKey memory key,
        Trade memory t,
        uint256 limit,
        bytes memory hookData
    ) internal {
        bool zeroForOne = _zeroForOne(key, t.buy);
        Currency q = _quoteOfKey(key);
        Currency c = Currency.wrap(address(_coinOfKey(key)));
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
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 value = _native(key) && t.buy ? (t.exactIn ? t.amount : limit) : 0;
        vm.prank(who);
        IUniversalRouter(router).execute{value: value}(
            abi.encodePacked(RouterLib.V4_SWAP), inputs, vm.getBlockTimestamp() + 60
        );
    }
}
