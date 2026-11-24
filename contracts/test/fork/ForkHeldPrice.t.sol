// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkTaxRouteBase} from "./ForkTaxRouteBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// #271 on the real PoolManager: a wallet that lifts a busy coin's price through either Universal Router
/// and holds it while every one of the Tax Vault's calls is made once a minute, then sells through the same
/// router, loses; and a lift undone in one block leaves the Reference Price where it was. With the coin as
/// currency0, as currency1, and paired with native ETH, against NVDA.
contract ForkHeldPriceTest is ForkTaxRouteBase {
    address internal attacker = makeAddr("attacker");

    function test_fork_heldPrice_loses_coinIsCurrency0() public {
        _heldPriceLoses(UNIVERSAL_ROUTER, 0);
    }

    function test_fork_heldPrice_loses_coinIsCurrency1() public {
        _heldPriceLoses(UNIVERSAL_ROUTER, 1);
    }

    function test_fork_heldPrice_loses_native() public {
        _heldPriceLoses(UNIVERSAL_ROUTER, 2);
    }

    function test_fork_heldPrice_v212_loses_coinIsCurrency0() public {
        _heldPriceLoses(UNIVERSAL_ROUTER_V2_1_2, 0);
    }

    function test_fork_heldPrice_v212_loses_coinIsCurrency1() public {
        _heldPriceLoses(UNIVERSAL_ROUTER_V2_1_2, 1);
    }

    function test_fork_heldPrice_v212_loses_native() public {
        _heldPriceLoses(UNIVERSAL_ROUTER_V2_1_2, 2);
    }

    /// A Reward Launch with every path: a burn share, a liquidity share, and holders paid in the coin.
    function _busyCoin(uint256 kind) internal returns (PoolKey memory key) {
        key = kind == 2
            ? _launchNativeTyped(StokerHook.LaunchType.Reward, 2_500, 2_500, StokerHook.PayoutAsset.Coin)
            : _launchReward(kind == 1, 2_500, 2_500, StokerHook.PayoutAsset.Coin);
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        for (uint256 i; i < 10; i++) {
            _trade(key, trader, true, true, 40 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        _letThePriceStand();
    }

    function _heldPriceLoses(address router, uint256 kind) internal {
        PoolKey memory key = _busyCoin(kind);
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        if (_native(key)) vm.deal(attacker, 1_000 ether);
        else deal(address(quote), attacker, 10_000 ether);
        _approveFor(router, attacker, key);
        int24 r0 = hook.referenceTick(key.toId());

        // Lifted and sold back in one block: the reference does not move.
        uint256 snap = vm.snapshotState();
        _route(router, attacker, key, Trade(true, true, 25 * u), 0);
        _route(router, attacker, key, Trade(false, true, _coinOfKey(key).balanceOf(attacker)), 0);
        assertEq(hook.referenceTick(key.toId()), r0, "a lift undone in one block moves nothing");
        vm.revertToState(snap);

        // Lifted, held for forty minutes of calls, sold back.
        uint256[3] memory lifts = [uint256(5 * u), 25 * u, 100 * u];
        for (uint256 l; l < lifts.length; l++) {
            snap = vm.snapshotState();
            uint256 before = _quoteBalanceOf(key, attacker);
            _route(router, attacker, key, Trade(true, true, lifts[l]), 0);
            for (uint256 i; i < 40; i++) {
                vm.warp(vm.getBlockTimestamp() + 60);
                vm.startPrank(attacker);
                try taxVault.addSupport(key) {} catch {}
                try taxVault.burn(key) {} catch {}
                try taxVault.buyForHolders(key) {} catch {}
                vm.stopPrank();
            }
            _route(router, attacker, key, Trade(false, true, _coinOfKey(key).balanceOf(attacker)), 0);
            uint256 afterAll = _quoteBalanceOf(key, attacker);
            assertLt(afterAll, before, "the held lift loses");
            emit log_named_decimal_uint("lift", lifts[l], 18);
            emit log_named_decimal_uint("  the wallet lost", before - afterAll, 18);
            vm.revertToState(snap);
        }
    }
}
