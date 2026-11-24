// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";

/// A wallet that holds a lifted price gains nothing from a Destination's waiting earnings (#271's defect,
/// asked of #248's earnings). A coin's Creator earnings are spent by the Tax Vault's own capped calls, so
/// they stand behind the same Reference Price as its tax; and the coins here are standard coins, with no
/// tax at all, whose pools keep a Reference Price only because every pool does.
///
/// The shape is `TaxVaultHeldPrice.t.sol`'s: a busy coin with earnings waiting, a wallet that buys the price
/// up, makes the vault's call once a minute, and sells everything back, across the lifts and piece counts
/// #271 measured, with the coin as currency0, as currency1 and paired with the native asset. Three orders
/// are tried, since anyone may call a Destination's work: the earnings applied before the lift, applied by
/// the wallet right after its lift (so the funding itself arrives at the lifted price), and applied by the
/// wallet again before every call.
contract DestinationsHeldPriceTest is DestinationsLocalBase {
    address internal attacker = makeAddr("attacker");

    enum When {
        BeforeTheLift,
        AfterTheLift,
        BeforeEveryCall
    }

    function _depth(PoolKey memory key) internal view returns (uint256) {
        return taxVault.pieceCap(key) * 10_000 / PIECE_BPS;
    }

    /// A standard coin naming the burn's or the liquidity's Destination, traded as #271's busy coin was (40
    /// round trips of about 2.4 times the pool's depth), then left quiet for a day.
    function _busyCoin(bool burn, uint256 kind) internal returns (PoolKey memory key) {
        key = _launchTo(kind, burn ? address(burnDestination) : address(liquidityDestination));
        uint256 tradeIn = _depth(key) * 60 / 25;
        for (uint256 i; i < 40; i++) {
            _trade(key, trader, true, true, tradeIn);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function _destination(bool burn) internal view returns (EarningsDestination) {
        return burn
            ? EarningsDestination(payable(address(burnDestination)))
            : EarningsDestination(payable(address(liquidityDestination)));
    }

    function _applyAs(address who, bool burn, PoolKey memory key) internal {
        vm.prank(who);
        try _destination(burn).applyEarnings(key) {} catch {}
    }

    function _vaultCall(bool burn, PoolKey memory key) internal returns (bool done) {
        vm.prank(attacker);
        if (burn) {
            try taxVault.burn(key) {
                done = true;
            } catch {}
        } else {
            try taxVault.addSupport(key) {
                done = true;
            } catch {}
        }
    }

    /// The wallet's result, in the Quote Asset, of lifting the price with `lift`, making the vault's call once
    /// a minute `pieces` times, and selling everything back. The state is restored afterwards.
    function _heldPrice(PoolKey memory key, bool burn, When when, uint256 lift, uint256 pieces)
        internal
        returns (int256 result)
    {
        uint256 snap = vm.snapshotState();
        if (_native(key)) vm.deal(attacker, 100_000 ether);
        else mockQuote.mint(attacker, 1_000_000 ether);
        if (when == When.BeforeTheLift) _applyAs(stranger, burn, key);
        uint256 before = _quoteBalanceOf(key, attacker);
        _trade(key, attacker, true, true, lift);
        if (when == When.AfterTheLift) _applyAs(attacker, burn, key);
        for (uint256 i; i < pieces; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            if (when == When.BeforeEveryCall) _applyAs(attacker, burn, key);
            _vaultCall(burn, key);
        }
        _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
        // forge-lint: disable-next-line(unsafe-typecast)
        result = int256(_quoteBalanceOf(key, attacker)) - int256(before);
        vm.revertToState(snap);
    }

    function _assertEveryCaseLoses(bool burn, uint256 kind) internal {
        PoolKey memory key = _busyCoin(burn, kind);
        uint256 depth = _depth(key);
        assertGt(_destination(burn).waitingOf(key), 20 * taxVault.pieceCap(key), "many pieces of earnings wait");
        uint256[3] memory lifts = [depth, depth * 3, depth * 15];
        uint256[5] memory counts = [uint256(1), 5, 10, 20, 40];
        for (uint256 w; w < 3; w++) {
            for (uint256 l; l < lifts.length; l++) {
                for (uint256 c; c < counts.length; c++) {
                    int256 r = _heldPrice(key, burn, When(w), lifts[l], counts[c]);
                    assertLt(r, 0, "a held lift loses");
                }
            }
        }
    }

    /// The paths are live: with nobody lifting the price, the earnings are applied and the vault's call
    /// spends a piece of them, so the losses below come from the Reference Price and not from a call that
    /// could never go through. And a standard coin's pool does keep one.
    function test_heldPrice_earnings_everyPathIsLiveWithoutALift() public {
        for (uint256 kind; kind < 3; kind++) {
            for (uint256 b; b < 2; b++) {
                PoolKey memory key = _busyCoin(b == 0, kind);
                assertEq(hook.termsOf(key.toId()).taxBps, 0, "a standard coin");
                _applyAs(stranger, b == 0, key);
                assertTrue(_vaultCall(b == 0, key), "the call goes through at a price that stood");

                // Lifted a moment ago, the reference has not followed: the burn waits by name.
                _trade(key, trader, true, true, _depth(key));
                assertTrue(hook.referenceTick(key.toId()) != _tickOf(key), "the reference stands apart");
                vm.warp(vm.getBlockTimestamp() + 60);
                if (b == 0) {
                    vm.expectPartialRevert(TaxVault.AboveReference.selector);
                    taxVault.burn(key);
                }
            }
        }
    }

    function test_heldPrice_earnings_burn_quoteFirst_loses() public {
        _assertEveryCaseLoses(true, QUOTE_FIRST);
    }

    function test_heldPrice_earnings_burn_coinFirst_loses() public {
        _assertEveryCaseLoses(true, COIN_FIRST);
    }

    function test_heldPrice_earnings_burn_native_loses() public {
        _assertEveryCaseLoses(true, NATIVE_PAIR);
    }

    function test_heldPrice_earnings_liquidity_quoteFirst_loses() public {
        _assertEveryCaseLoses(false, QUOTE_FIRST);
    }

    function test_heldPrice_earnings_liquidity_coinFirst_loses() public {
        _assertEveryCaseLoses(false, COIN_FIRST);
    }

    function test_heldPrice_earnings_liquidity_native_loses() public {
        _assertEveryCaseLoses(false, NATIVE_PAIR);
    }
}
