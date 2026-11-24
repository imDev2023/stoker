// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// What a wallet gains or loses by holding a lifted price while the Tax Vault's pieces land at it (#271,
/// found by the review of PR #268 on 2026-11-24). One sandwiched piece always lost money
/// (`TaxVaultHostile.t.sol`); before the Reference Price a wallet that bought the price up and held it while
/// pieces landed took part of a coin's waiting tax, over half of it given long enough. This is the issue's
/// reproduction with assertions in place of its logs: across the lifts and piece counts it measured, for
/// all three calls, in both currency orders and with the native asset, the wallet loses.
contract TaxVaultHeldPriceTest is TaxLocalBase {
    address internal attacker = makeAddr("attacker");

    /// The three public calls that spend a coin's tax in its pool.
    enum Call {
        Support,
        Burn,
        Holders
    }

    /// The coin as currency0, as currency1, and paired with the native asset (always currency1).
    enum Pair {
        Coin0,
        Coin1,
        Native
    }

    /// A coin with tax waiting for `call`, as after a busy first hour with nobody making the calls, then
    /// left quiet long enough that its Reference Price stands at its price: a Stoke Launch at the lowest tax
    /// (the cheapest round trip for the wallet) for Support Liquidity, a Reward Launch with half its tax to
    /// the burn (the issue's figure) for the burn, and a Reward Launch at the lowest tax paying its holders
    /// in the coin for the holders' buys.
    function _busyCoin(Call call, Pair pair) internal returns (PoolKey memory key) {
        address quoteAsset = pair == Pair.Native ? address(0) : address(quote);
        bool quoteIsCurrency0 = pair != Pair.Coin0;
        uint256 firstBuy = pair == Pair.Native ? 0.1 ether : 1 ether;
        if (call == Call.Support) {
            (, key) = _launchWith(
                _typedParams(
                    quoteAsset,
                    quoteIsCurrency0,
                    firstBuy,
                    StokerHook.LaunchType.Liquidity,
                    100,
                    0,
                    0,
                    StokerHook.PayoutAsset.QuoteAsset
                )
            );
        } else if (call == Call.Burn) {
            (, key) = _launchWith(
                _typedParams(
                    quoteAsset,
                    quoteIsCurrency0,
                    firstBuy,
                    StokerHook.LaunchType.Reward,
                    300,
                    5_000,
                    0,
                    StokerHook.PayoutAsset.QuoteAsset
                )
            );
        } else {
            (, key) = _launchWith(
                _typedParams(
                    quoteAsset,
                    quoteIsCurrency0,
                    firstBuy,
                    StokerHook.LaunchType.Reward,
                    100,
                    0,
                    0,
                    StokerHook.PayoutAsset.Coin
                )
            );
        }
        // The issue's trading: 40 round trips of 60 of the mock Stock Token, about 2.3 times the pool's depth.
        uint256 tradeIn = _depth(key) * 60 / 25;
        for (uint256 i; i < 40; i++) {
            _trade(key, trader, true, true, tradeIn);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
        }
        // A quiet day: the Reference Price follows the price the trading left, as it does any price that stands.
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    /// The Quote Asset depth of the coin's Seed Position at the price, which a piece is 0.5% of.
    function _depth(PoolKey memory key) internal view returns (uint256) {
        return taxVault.pieceCap(key) * 10_000 / PIECE_BPS;
    }

    function _fund(PoolKey memory key, address who) internal {
        if (_native(key)) vm.deal(who, 100_000 ether);
        else mockQuote.mint(who, 1_000_000 ether);
    }

    function _makeCall(PoolKey memory key, Call call) internal returns (bool done) {
        vm.prank(attacker);
        if (call == Call.Support) {
            try taxVault.addSupport(key) {
                done = true;
            } catch {}
        } else if (call == Call.Burn) {
            try taxVault.burn(key) {
                done = true;
            } catch {}
        } else {
            try taxVault.buyForHolders(key) {
                done = true;
            } catch {}
        }
    }

    /// The wallet's result, in the Quote Asset, of lifting the price with `lift`, making `call` once a minute
    /// `pieces` times, and selling everything back. The state is restored afterwards.
    function _heldPrice(PoolKey memory key, uint256 lift, uint256 pieces, Call call)
        internal
        returns (int256 result, uint256 done)
    {
        uint256 snap = vm.snapshotState();
        _fund(key, attacker);
        uint256 before = _quoteBalanceOf(key, attacker);
        _trade(key, attacker, true, true, lift);
        for (uint256 i; i < pieces; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            if (_makeCall(key, call)) done++;
        }
        _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
        // forge-lint: disable-next-line(unsafe-typecast)
        result = int256(_quoteBalanceOf(key, attacker)) - int256(before);
        vm.revertToState(snap);
    }

    /// Every case of the issue's table, for one call and one pair: lifts of about 25, 75 and 375 of the mock
    /// Stock Token (once, three times and fifteen times the pool's depth), held for 1 to 40 pieces.
    function _assertEveryCaseLoses(Call call, Pair pair) internal {
        PoolKey memory key = _busyCoin(call, pair);
        uint256 depth = _depth(key);
        uint256[3] memory lifts = [depth, depth * 3, depth * 15];
        uint256[5] memory counts = [uint256(1), 5, 10, 20, 40];
        for (uint256 l; l < lifts.length; l++) {
            for (uint256 c; c < counts.length; c++) {
                (int256 r,) = _heldPrice(key, lifts[l], counts[c], call);
                emit log_named_decimal_int("  wallet's result", r, 18);
                assertLt(r, 0, "a held lift loses");
            }
        }
    }

    /// The paths are live: with nobody lifting the price, each call spends a piece on the busy coin, so the
    /// losses above come from the Reference Price and not from a call that could never go through.
    function test_heldPrice_everyCallIsLiveWithoutALift() public {
        for (uint256 c; c < 3; c++) {
            for (uint256 p; p < 3; p++) {
                PoolKey memory key = _busyCoin(Call(c), Pair(p));
                assertTrue(_makeCall(key, Call(c)), "the call goes through at a price that stood");
            }
        }
    }

    function test_heldPrice_support_coin0_loses() public {
        _assertEveryCaseLoses(Call.Support, Pair.Coin0);
    }

    function test_heldPrice_support_coin1_loses() public {
        _assertEveryCaseLoses(Call.Support, Pair.Coin1);
    }

    function test_heldPrice_support_native_loses() public {
        _assertEveryCaseLoses(Call.Support, Pair.Native);
    }

    function test_heldPrice_burn_coin0_loses() public {
        _assertEveryCaseLoses(Call.Burn, Pair.Coin0);
    }

    function test_heldPrice_burn_coin1_loses() public {
        _assertEveryCaseLoses(Call.Burn, Pair.Coin1);
    }

    function test_heldPrice_burn_native_loses() public {
        _assertEveryCaseLoses(Call.Burn, Pair.Native);
    }

    function test_heldPrice_holders_coin0_loses() public {
        _assertEveryCaseLoses(Call.Holders, Pair.Coin0);
    }

    function test_heldPrice_holders_coin1_loses() public {
        _assertEveryCaseLoses(Call.Holders, Pair.Coin1);
    }

    function test_heldPrice_holders_native_loses() public {
        _assertEveryCaseLoses(Call.Holders, Pair.Native);
    }
}
