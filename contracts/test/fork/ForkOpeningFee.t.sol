// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkOpeningBase} from "./ForkOpeningBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// #246's fork criteria against the real PoolManager, through both Universal Routers, with the coin as
/// currency0, as currency1 and paired with native ETH: a buy at the launch's own second pays the Platform
/// Fee and an Opening Fee that take 99% together, a buy at ten seconds about half of that, a buy at twenty
/// none; the First Buy inside the launch transaction pays the Platform Fee alone; a sell inside the window
/// pays no Opening Fee.
contract ForkOpeningFeeTest is ForkOpeningBase {
    function _buysAt(uint256 elapsed) internal {
        address[2] memory routers = _routers();
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 r; r < 2; r++) {
                for (uint256 e; e < 2; e++) {
                    bool exactIn = e == 0;
                    uint256 snap = vm.snapshotState();
                    PoolKey memory key = _launchOpen(kind, 0, 0);
                    _approveFor(routers[r], trader, key);
                    vm.warp(_launchedAt(key) + elapsed);
                    (, Seen memory s) =
                        _routeAtFigure(routers[r], key, Trade(true, exactIn, _buyAmount(key, exactIn)), 0);
                    Fees memory f = _checkBuy(s, exactIn, elapsed, 0, 0);
                    uint256 taken = _taken(s);
                    if (elapsed == 0) {
                        // The Platform Fee and the Opening Fee take 99% of the buy together.
                        assertEq(taken * B, s.quoteIn * OPENING_FEE_START_BPS, "99% of the Quote Asset side");
                        assertEq(f.opening, taken - f.fee, "the Opening Fee is the rest above the Platform Fee");
                    } else if (elapsed == 10) {
                        // 1.00% and half of the 98.00% above it: 50.00%.
                        assertEq(taken * B, s.quoteIn * 5_000, "about half: 50%");
                    } else {
                        assertEq(s.opening, 0, "none from twenty seconds on");
                        assertEq(taken, f.fee, "the Platform Fee alone");
                    }
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_fork_opening_buyAtTheLaunchSecond_pays99PercentTogether() public {
        _buysAt(0);
    }

    function test_fork_opening_buyAtTenSeconds_paysAboutHalf() public {
        _buysAt(10);
    }

    function test_fork_opening_buyAtTwentySeconds_paysNone() public {
        _buysAt(20);
    }

    /// The First Buy inside the launch transaction pays the Platform Fee alone: a permit First Buy in NVDA in
    /// both orders, and a native First Buy sent as the launch's value.
    function test_fork_opening_firstBuyPaysThePlatformFeeAlone() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            uint256 firstBuy = kind == 2 ? 0.1 ether : 10 ether;
            StokerFactory.LaunchParams memory p = _typedParams(
                kind == 2 ? address(0) : address(quote),
                kind == 1,
                firstBuy,
                StokerHook.LaunchType.Standard,
                0,
                0,
                0,
                StokerHook.PayoutAsset.QuoteAsset
            );
            uint256 claims0 = pm.balanceOf(address(hook), (kind == 2 ? NATIVE : _quoteCurrency()).toId());
            address coin;
            if (kind == 2) {
                vm.prank(creator);
                (coin,) = factory.launch{value: firstBuy}(p);
            } else {
                StokerFactory.PermitSignature memory sig = _permit(firstBuy, vm.getBlockTimestamp() + 1 hours);
                vm.prank(creator);
                (coin,) = factory.launchWithPermit(p, sig);
            }
            PoolKey memory key = kind == 2 ? _nativeKey(coin) : _keyFor(coin);
            assertEq(_hookClaimsOf(key) - claims0, _rateOfGross(firstBuy, PLATFORM_FEE_BPS), "the Platform Fee");
            assertEq(hook.openingFeeBooked(key.toId()), 0, "no Opening Fee");
            assertEq(_vaultClaims(key), 0, "nothing reached the vault");
            assertGt(_coinOfKey(key).balanceOf(creator), 0, "the Creator holds the coins bought");
            vm.revertToState(snap);
        }
    }

    /// A sell inside the window, exact in and exact out, through both routers, pays no Opening Fee.
    function test_fork_opening_sellInTheWindowPaysNone() public {
        address[2] memory routers = _routers();
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 r; r < 2; r++) {
                uint256 snap = vm.snapshotState();
                PoolKey memory key = _launchOpen(kind, 0, kind == 2 ? 0.1 ether : 10 ether);
                // The trader holds the Creator's coins, to sell them in the launch's own second.
                uint256 coins = _coinOfKey(key).balanceOf(creator);
                vm.prank(creator);
                _coinOfKey(key).transfer(trader, coins);
                _approveFor(routers[r], trader, key);
                (, Seen memory s) = _routeAtFigure(routers[r], key, Trade(false, true, coins / 4), 0);
                assertEq(s.opening, 0, "an exact-in sell pays none");
                assertGt(s.platformCredit, 0, "and pays the Platform Fee");
                vm.warp(_launchedAt(key) + 5);
                (, s) = _routeAtFigure(routers[r], key, Trade(false, false, kind == 2 ? 1e12 : 1e15), 0);
                assertEq(s.opening, 0, "an exact-out sell pays none");
                vm.revertToState(snap);
            }
        }
    }
}
