// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {ForkBase} from "./ForkBase.sol";
import {TaxHelpers} from "../utils/TaxHelpers.sol";
import {StokerTestBase} from "../utils/StokerTestBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// @notice The tax's fork fixture (#245): Robinhood Chain at the pinned block, NVDA and native ETH both
///         listed, and trades through the test router in either kind of pool. A small base, so each fork
///         contract over it stays clear of the compiler's stack limit (gotcha 9).
abstract contract ForkTaxBase is ForkBase, TaxHelpers {
    function setUp() public virtual override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
        deal(NVDA, trader, 100_000 ether);
    }

    /// A trade through the test router in a pool paired with NVDA or with native ETH.
    function _trade(PoolKey memory key, address who, bool buy, bool exactIn, uint256 amount)
        internal
        returns (BalanceDelta)
    {
        if (_native(key)) return _swapNative(key, who, buy, exactIn, amount, who.balance);
        return _swap(key, who, buy, exactIn, amount);
    }

    function _quoteBalanceOf(PoolKey memory key, address who) internal view returns (uint256) {
        return _native(key) ? who.balance : quote.balanceOf(who);
    }

    /// The error a hook's refusal arrives as, wrapped by the PoolManager.
    function _hookError(bytes4 callback, bytes4 reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            callback,
            abi.encodeWithSelector(reason),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _removalRefused() internal view returns (bytes memory) {
        return _hookError(IHooks.beforeRemoveLiquidity.selector, StokerHook.SeedPositionLocked.selector);
    }
}
