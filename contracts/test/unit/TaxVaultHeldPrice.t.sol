// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// What a wallet gains or loses by holding a lifted price while Support Liquidity pieces land at it (the
/// review of 2026-11-24). One sandwiched piece loses money (`TaxVaultHostile.t.sol`); this measures the
/// case the README names and does not measure: a coin with tax waiting, a wallet that buys the price up,
/// has a piece placed under its lifted price every interval, and then sells everything into them.
contract TaxVaultHeldPriceTest is TaxLocalBase {
    address internal attacker = makeAddr("attacker");

    /// A Stoke Launch at the lowest tax (the cheapest round trip for the wallet) that has traded enough
    /// for many pieces of tax to be waiting, as after a busy first hour with nobody making the calls.
    function _busyCoin(bool q0) internal returns (PoolKey memory key) {
        key = _launchStoke(q0, 100);
        for (uint256 i; i < 40; i++) {
            _trade(key, trader, true, true, 60 ether);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
    }

    /// The wallet's result, in the Quote Asset, of lifting the price with `lift`, having `pieces` placed
    /// one interval apart, and selling everything back.
    function _heldPrice(PoolKey memory key, uint256 lift, uint256 pieces, bool burn)
        internal
        returns (int256 result)
    {
        uint256 snap = vm.snapshotState();
        mockQuote.mint(attacker, 1_000_000 ether);
        uint256 before = quote.balanceOf(attacker);
        _trade(key, attacker, true, true, lift);
        for (uint256 i; i < pieces; i++) {
            skip(60);
            vm.prank(attacker);
            if (burn) {
                try taxVault.burn(key) {} catch {}
            } else {
                try taxVault.addSupport(key) {} catch {}
            }
        }
        _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
        // forge-lint: disable-next-line(unsafe-typecast)
        result = int256(quote.balanceOf(attacker)) - int256(before);
        vm.revertToState(snap);
    }

    function test_heldPrice_measured() public {
        for (uint256 o; o < 2; o++) {
            PoolKey memory key = _busyCoin(o == 0);
            (, uint256 waiting,,) = taxVault.waiting(key);
            emit log_named_decimal_uint("Support Liquidity waiting", waiting, 18);
            emit log_named_decimal_uint("one piece at the resting price", taxVault.pieceCap(key), 18);
            uint256[3] memory lifts = [uint256(25 ether), 75 ether, 375 ether];
            uint256[5] memory counts = [uint256(1), 5, 10, 20, 40];
            for (uint256 l; l < lifts.length; l++) {
                emit log_named_decimal_uint("lift, Quote Asset bought", lifts[l], 18);
                for (uint256 c; c < counts.length; c++) {
                    int256 r = _heldPrice(key, lifts[l], counts[c], false);
                    emit log_named_uint("  pieces", counts[c]);
                    emit log_named_decimal_int("  wallet's result", r, 18);
                }
            }
        }
    }

    /// The same with the Reward Burn's buys: a Reward Launch with half its tax to the burn.
    function test_heldPrice_burn_measured() public {
        PoolKey memory key = _launchReward(true, 5_000, 0, StokerHook.PayoutAsset.QuoteAsset);
        for (uint256 i; i < 40; i++) {
            _trade(key, trader, true, true, 60 ether);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        (uint256 waiting,,,) = taxVault.waiting(key);
        emit log_named_decimal_uint("Reward Burn waiting", waiting, 18);
        uint256[2] memory lifts = [uint256(75 ether), 375 ether];
        uint256[4] memory counts = [uint256(1), 10, 20, 40];
        for (uint256 l; l < lifts.length; l++) {
            emit log_named_decimal_uint("lift, Quote Asset bought", lifts[l], 18);
            for (uint256 c; c < counts.length; c++) {
                int256 r = _heldPrice(key, lifts[l], counts[c], true);
                emit log_named_uint("  pieces", counts[c]);
                emit log_named_decimal_int("  wallet's result", r, 18);
            }
        }
    }
}
