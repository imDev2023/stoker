// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkTaxRouteBase} from "./ForkTaxRouteBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";

/// @notice The Opening Fee's fork fixture (#246): Robinhood Chain at the pinned block, NVDA and native ETH
///         listed, a buy routed through either Universal Router at the V4 Quoter's figure, and what it did to
///         every book. A small base, so each fork contract over it stays clear of the stack limit (gotcha 9).
abstract contract ForkOpeningBase is ForkTaxRouteBase, OpeningFeeHelpers {
    /// One trade through `router` at the Quoter's figure, naming the referrer at `referrerBps` (none at
    /// zero): the figure is delivered to the wei, and the books are measured from outside.
    function _routeAtFigure(address router, PoolKey memory key, Trade memory t, uint256 referrerBps)
        internal
        returns (uint256 figure, Seen memory s)
    {
        bytes memory data = _data(referrerBps);
        figure = _quoteTrade(key, t, data);
        uint256 coins0 = _coinOfKey(key).balanceOf(trader);
        Seen memory before = _snapshot(key, trader);
        _route(router, trader, key, t, figure, data);
        s = _since(key, before);
        uint256 coins1 = _coinOfKey(key).balanceOf(trader);
        if (t.buy && t.exactIn) {
            assertEq(s.quoteIn, t.amount, "paid what it specified");
            assertEq(coins1 - coins0, figure, "the Quoter's coins, to the wei");
        } else if (t.buy) {
            assertEq(s.quoteIn, figure, "the Quoter's price, to the wei");
            assertEq(coins1 - coins0, t.amount, "received what it specified");
        } else if (t.exactIn) {
            assertEq(coins0 - coins1, t.amount, "sold what it specified");
            assertEq(s.quoteOut, figure, "the Quoter's proceeds, to the wei");
        } else {
            assertEq(coins0 - coins1, figure, "the Quoter's coins, to the wei");
            assertEq(s.quoteOut, t.amount, "received what it specified");
        }
    }

    /// What changed since `before`, with the checks every trade must pass.
    function _since(PoolKey memory key, Seen memory before) internal view returns (Seen memory s) {
        Seen memory afterwards = _snapshot(key, trader);
        if (before.quoteIn > afterwards.quoteIn) s.quoteIn = before.quoteIn - afterwards.quoteIn;
        else s.quoteOut = afterwards.quoteIn - before.quoteIn;
        s.creatorCredit = afterwards.creatorCredit - before.creatorCredit;
        s.platformCredit = afterwards.platformCredit - before.platformCredit;
        s.referrerCredit = afterwards.referrerCredit - before.referrerCredit;
        s.tax = afterwards.tax - before.tax;
        s.opening = afterwards.opening - before.opening;
        s.vaultClaims = afterwards.vaultClaims - before.vaultClaims;
        s.hookClaims = afterwards.hookClaims - before.hookClaims;
        assertEq(s.vaultClaims, s.tax + s.opening, "the vault's claims grew by the tax and the Opening Fee alone");
        assertEq(
            s.hookClaims, s.creatorCredit + s.platformCredit + s.referrerCredit, "the hook's claims are the Credits"
        );
        assertEq(_quoteBalanceOf(key, address(taxVault)), 0, "nothing transferred to the vault");
    }

    function _routers() internal pure returns (address[2] memory) {
        return [UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_V2_1_2];
    }
}
