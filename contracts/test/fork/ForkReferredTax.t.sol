// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkTaxRouteBase} from "./ForkTaxRouteBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// A trade naming a referrer on a Reward Launch through both Universal Routers (#243 with #245): in all four
/// swap types the V4 Quoter, given the same hookData, quotes the trade to the wei with the Platform Fee, the
/// Referrer Fee and the tax all in it, and each is its own rate of the Quote Asset's side. With the coin as
/// currency0, as currency1, and paired with native ETH.
contract ForkReferredTaxTest is ForkTaxRouteBase {
    address internal referrer = makeAddr("frontEnd");
    uint256 internal constant REF_BPS = 75;

    function test_fork_referredTax_coinIsCurrency0() public {
        _bothRouters(0);
    }

    function test_fork_referredTax_coinIsCurrency1() public {
        _bothRouters(1);
    }

    function test_fork_referredTax_native() public {
        _bothRouters(2);
    }

    function _bothRouters(uint256 kind) internal {
        PoolKey memory key = kind == 2
            ? _launchNativeTyped(StokerHook.LaunchType.Reward, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset)
            : _launchReward(kind == 1, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        address[2] memory routers = [UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_V2_1_2];
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        Trade[4] memory trades = [
            Trade(true, true, 10 * u),
            Trade(true, false, 1e10 ether),
            Trade(false, true, 1e10 ether),
            Trade(false, false, 2 * u)
        ];
        for (uint256 r; r < 2; r++) {
            uint256 snap = vm.snapshotState();
            _approveFor(routers[r], trader, key);
            for (uint256 i; i < 4; i++) {
                _referredTrade(routers[r], key, trades[i]);
            }
            vm.revertToState(snap);
        }
    }

    struct Before {
        uint256 q;
        uint256 c;
        uint256 claims;
        uint256 refCredit;
        uint256 tax;
    }

    function _referredTrade(address router, PoolKey memory key, Trade memory t) internal {
        bytes memory hookData = abi.encode(referrer, REF_BPS);
        uint256 figure = _quoteTrade(key, t, hookData);
        Before memory b = Before(
            _quoteBalanceOf(key, trader),
            _coinOfKey(key).balanceOf(trader),
            _hookClaimsOf(key),
            hook.creditOf(referrer, _quoteOfKey(key)),
            _taxBooked(key)
        );
        _route(router, trader, key, t, figure, hookData);
        uint256 q1 = _quoteBalanceOf(key, trader);
        uint256 c1 = _coinOfKey(key).balanceOf(trader);
        uint256 rf = hook.creditOf(referrer, _quoteOfKey(key)) - b.refCredit;
        uint256 pf = _hookClaimsOf(key) - b.claims - rf;
        uint256 tax = _taxBooked(key) - b.tax;
        uint256 total = PLATFORM_FEE_BPS + REF_BPS + TAX_BPS;

        // The Quoter's figure, given the same hookData, is what the router delivered, to the wei.
        if (t.exactIn) assertEq(t.buy ? c1 - b.c : q1 - b.q, figure, "exact in: the Quoter's output");
        else assertEq(t.buy ? b.q - q1 : b.c - c1, figure, "exact out: the Quoter's input");

        uint256 side; // the Quote Asset side the rates are of, or its net where only the net is known
        if (t.buy && t.exactIn) side = t.amount;
        else if (t.buy) side = figure - pf - rf - tax;
        else if (t.exactIn) side = figure + pf + rf + tax;
        else side = t.amount;
        bool onNet = !t.exactIn; // exact out: the net is known, a buy's input to the pool or a sell's output
        assertEq(pf, onNet ? _rateOfNet(side, PLATFORM_FEE_BPS, total) : _rateOfGross(side, PLATFORM_FEE_BPS), "fee");
        assertEq(rf, onNet ? _rateOfNet(side, REF_BPS, total) : _rateOfGross(side, REF_BPS), "Referrer Fee");
        assertEq(tax, onNet ? _rateOfNet(side, TAX_BPS, total) : _rateOfGross(side, TAX_BPS), "tax");
        assertGt(rf, 0);
        assertGt(tax, 0);
    }
}
