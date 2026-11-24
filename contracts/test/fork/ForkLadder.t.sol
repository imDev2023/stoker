// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkDestinationsBase} from "./ForkDestinationsBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";

/// The Creator Ladder's key on the real PoolManager, through the Universal Routers (#248's first
/// criterion): after the ladder key raises a coin to the second tier, the next swap credits the Creator the
/// second tier's share and the platform the rest, and the fee the trader pays is unchanged, to the wei
/// against the chain's V4 Quoter. In a coin on either side of an NVDA pool and one paired with native ETH.
contract ForkLadderTest is ForkDestinationsBase {
    struct Seen {
        uint256 quoted; // the V4 Quoter's figure for the trade
        uint256 paid; // what the trader's Quote Asset fell by (a buy) or rose by (a sell)
        uint256 coins; // what the trader's coins rose by (a buy) or fell by (a sell)
        uint256 fee; // what the hook's claims grew by
        uint256 creatorCredit;
        uint256 platformCredit;
    }

    function _see(address router, PoolKey memory key, Trade memory t) internal returns (Seen memory s) {
        s.quoted = _quoteTrade(key, t);
        uint256 q0 = _quoteBalanceOf(key, trader);
        uint256 c0 = _coinOfKey(key).balanceOf(trader);
        uint256 claims = _hookClaimsOf(key);
        uint256 creator0 = _creditIn(key, creator);
        uint256 platform0 = _creditIn(key, platform);
        _route(router, trader, key, t, s.quoted);
        uint256 q1 = _quoteBalanceOf(key, trader);
        uint256 c1 = _coinOfKey(key).balanceOf(trader);
        s.paid = t.buy ? q0 - q1 : q1 - q0;
        s.coins = t.buy ? c1 - c0 : c0 - c1;
        s.fee = _hookClaimsOf(key) - claims;
        s.creatorCredit = _creditIn(key, creator) - creator0;
        s.platformCredit = _creditIn(key, platform) - platform0;
    }

    function _trades(PoolKey memory key) internal pure returns (Trade[4] memory) {
        uint256 unit = _unit(key);
        return [
            Trade(true, true, 5 * unit), // a buy, exact in
            Trade(true, false, 1e9 ether), // a buy, exact out
            Trade(false, true, 1e9 ether), // a sell, exact in
            Trade(false, false, unit / 20) // a sell, exact out
        ];
    }

    function _raisedSwap(address router, uint256 kind) internal {
        PoolKey memory key = _launchTo(kind, address(0));
        _approveFor(router, trader, key);
        Trade memory open = Trade(true, true, 20 * _unit(key));
        _route(router, trader, key, open, _quoteTrade(key, open));
        Trade[4] memory trades = _trades(key);
        for (uint256 i; i < trades.length; i++) {
            uint256 snap = vm.snapshotState();
            Seen memory first = _see(router, key, trades[i]);
            vm.revertToState(snap);

            vm.prank(ladderKey);
            hook.raiseTier(key.toId(), 2);
            Seen memory second = _see(router, key, trades[i]);
            vm.revertToState(snap);

            assertGt(first.fee, 0, _kindName(kind));
            assertEq(first.creatorCredit, first.fee * CREATOR_SHARE_BPS / 10_000, "the first tier's share");
            assertEq(second.creatorCredit, second.fee * SECOND_TIER_SHARE_BPS / 10_000, "the second tier's share");
            assertEq(second.platformCredit, second.fee - second.creatorCredit, "the platform has the rest");
            assertGt(second.creatorCredit, first.creatorCredit);

            // What the trader pays and receives, the fee in it, and the Quoter's figure are those of the
            // same swap before the raise.
            assertEq(second.fee, first.fee, "the fee is unchanged");
            assertEq(second.paid, first.paid, "the trader pays the same");
            assertEq(second.coins, first.coins, "the trader receives the same");
            assertEq(second.quoted, first.quoted, "the Quoter's figure is unchanged");
            // And the Quoter's figure is what the trade delivered: out on exact in, in on exact out.
            bool quotedIsCoins = trades[i].buy == trades[i].exactIn;
            assertEq(second.quoted, quotedIsCoins ? second.coins : second.paid, "to the wei");
        }
    }

    function test_fork_ladder_afterARaiseTheNextSwapCreditsTheSecondShare_nvdaAsCurrency0() public {
        _raisedSwap(UNIVERSAL_ROUTER, QUOTE_FIRST);
    }

    function test_fork_ladder_afterARaiseTheNextSwapCreditsTheSecondShare_theCoinAsCurrency0() public {
        _raisedSwap(UNIVERSAL_ROUTER, COIN_FIRST);
    }

    function test_fork_ladder_afterARaiseTheNextSwapCreditsTheSecondShare_nativeEth() public {
        _raisedSwap(UNIVERSAL_ROUTER, NATIVE_PAIR);
    }

    function test_fork_ladder_theSameThroughUniversalRouterV2_1_2() public {
        _raisedSwap(UNIVERSAL_ROUTER_V2_1_2, QUOTE_FIRST);
        _raisedSwap(UNIVERSAL_ROUTER_V2_1_2, COIN_FIRST);
        _raisedSwap(UNIVERSAL_ROUTER_V2_1_2, NATIVE_PAIR);
    }

    /// The top tier, and what the key cannot do, on the chain: no lowering, nothing past the top, and no
    /// raise once the Admin has revoked it.
    function test_fork_ladder_theTopTier_andTheKeysLimits() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchTo(kind, address(0));
            _approveFor(UNIVERSAL_ROUTER, trader, key);
            vm.startPrank(ladderKey);
            hook.raiseTier(key.toId(), 3);
            vm.expectRevert(abi.encodeWithSelector(StokerHook.InvalidTier.selector, uint8(3), uint8(2)));
            hook.raiseTier(key.toId(), 2);
            vm.expectRevert(abi.encodeWithSelector(StokerHook.InvalidTier.selector, uint8(3), uint8(4)));
            hook.raiseTier(key.toId(), 4);
            vm.stopPrank();
            Seen memory top = _see(UNIVERSAL_ROUTER, key, Trade(true, true, 5 * _unit(key)));
            assertEq(top.creatorCredit, top.fee * TOP_TIER_SHARE_BPS / 10_000, "the top tier's share");
            assertEq(top.fee, _rateOfGross(5 * _unit(key), PLATFORM_FEE_BPS), "1.00% of what the trader paid");
        }
        PoolKey memory later = _launchTo(QUOTE_FIRST, address(0));
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.LadderKey);
        vm.prank(ladderKey);
        vm.expectRevert(StokerHook.NotLadderKey.selector);
        hook.raiseTier(later.toId(), 2);
    }
}
