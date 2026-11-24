// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkOpeningBase} from "./ForkOpeningBase.sol";

/// #246 against the V4 Quoter: for a buy inside the window, exact in and exact out, on a standard coin, a
/// Reward Launch and a Stoke Launch, with and without a referrer, in every kind of pool, the Quoter's figure
/// is what the buyer receives or pays to the wei through both Universal Routers, and a bound one wei tighter
/// reverts; a buy quoted a second early pays less than quoted, never more; and the Opening Fee becomes
/// Support Liquidity in the coin's pool on the real PoolManager.
contract ForkOpeningQuoteTest is ForkOpeningBase {
    function test_fork_opening_theQuotersFigureIsWhatTheBuyerGets() public {
        address[2] memory routers = _routers();
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 lt; lt < 3; lt++) {
                for (uint256 r; r < 2; r++) {
                    uint256 snap = vm.snapshotState();
                    PoolKey memory key = _launchOpen(kind, lt, 0);
                    _approveFor(routers[r], trader, key);
                    uint256 referrerBps = (lt + kind) % 2 == 0 ? 0 : REFERRER_FEE_CAP_BPS;
                    for (uint256 e; e < 2; e++) {
                        bool exactIn = e == 0;
                        vm.warp(_launchedAt(key) + 3 + 6 * e);
                        Trade memory t = Trade(true, exactIn, _buyAmount(key, exactIn));
                        uint256 figure = _quoteTrade(key, t, _data(referrerBps));
                        uint256 tight = vm.snapshotState();
                        if (exactIn) {
                            vm.expectRevert(abi.encodeWithSelector(V4TooLittleReceived.selector, figure + 1, figure));
                            _route(routers[r], trader, key, t, figure + 1, _data(referrerBps));
                        } else {
                            vm.expectRevert(abi.encodeWithSelector(V4TooMuchRequested.selector, figure - 1, figure));
                            _route(routers[r], trader, key, t, figure - 1, _data(referrerBps));
                        }
                        vm.revertToState(tight);
                        (, Seen memory s) = _routeAtFigure(routers[r], key, t, referrerBps);
                        _checkBuy(s, exactIn, 3 + 6 * e, referrerBps, _taxBpsOf(key));
                        assertGt(s.opening, 0, "an Opening Fee in the figure");
                    }
                    vm.revertToState(snap);
                }
            }
        }
    }

    /// Quoted a second early, a buy lands a second later and pays less than quoted: on exact in it receives
    /// more coins than the figure, on exact out it pays less than the figure. Among them the last second,
    /// quoted at 19 and landing at 20.
    function test_fork_opening_aBuyQuotedASecondEarlyPaysLessNeverMore() public {
        address[2] memory routers = _routers();
        uint256[3] memory seconds_ = [uint256(0), 10, 19];
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 i; i < 3; i++) {
                for (uint256 e; e < 2; e++) {
                    bool exactIn = e == 0;
                    address router = routers[(kind + i + e) % 2];
                    uint256 snap = vm.snapshotState();
                    PoolKey memory key = _launchOpen(kind, 1, 0);
                    _approveFor(router, trader, key);
                    vm.warp(_launchedAt(key) + seconds_[i]);
                    Trade memory t = Trade(true, exactIn, _buyAmount(key, exactIn));
                    uint256 figure = _quoteTrade(key, t, "");
                    vm.warp(_launchedAt(key) + seconds_[i] + 1);
                    uint256 coins0 = _coinOfKey(key).balanceOf(trader);
                    uint256 quote0 = _quoteBalanceOf(key, trader);
                    // A native buy sends the bound as value, and the router keeps what the swap did not use (no
                    // sweep), so what the buyer paid the pool is the value less what stayed with the router.
                    uint256 kept0 = _quoteBalanceOf(key, router);
                    _route(router, trader, key, t, figure, "");
                    uint256 kept = _quoteBalanceOf(key, router) - kept0;
                    if (exactIn) {
                        assertGt(_coinOfKey(key).balanceOf(trader) - coins0, figure, "more coins than quoted");
                    } else {
                        assertLt(quote0 - _quoteBalanceOf(key, trader) - kept, figure, "paid less than quoted");
                    }
                    vm.revertToState(snap);
                }
            }
        }
    }

    /// A standard coin's only income, its Opening Fee, becomes Support Liquidity in its own pool on the
    /// real PoolManager: Quote Asset alone on the side the coin's price falls into, the price unmoved.
    function test_fork_opening_becomesSupportLiquidityInTheCoinsPool() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, 0);
            _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
            uint256 opening = hook.openingFeeBooked(key.toId());
            assertGt(opening, 0, "the buy paid an Opening Fee");
            (, uint256 supportPart,,) = taxVault.waiting(key);
            assertEq(supportPart, opening, "all of it waits as Support Liquidity");
            uint160 price = _sqrtPrice(key);
            (Support memory sup, uint256 added) = _addSupport(key);
            assertGt(added, 0, "a piece was placed");
            assertEq(_sqrtPrice(key), price, "the price unmoved");
            (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, sup);
            assertApproxEqAbs(quoteHeld, added, 2, "Quote Asset alone");
            assertEq(coinsHeld, 0, "no coin");
            vm.revertToState(snap);
        }
    }
}
