// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";

/// Who ends up with a sniper's Opening Fee (#246, from the review of PR #274). A standard coin: the Creator's
/// exempt First Buy, a third party's snipe at the launch's own second, every Support Liquidity piece placed
/// after the window, then the Creator sells every coin, then the sniper. Before standard coins kept a
/// Reference Price, the pieces landed just under the lifted price and a First Buy of 15 gained 6.71 from the
/// snipe, 34% of its 19.6 Opening Fee; with the reference (#271, extended to every pool whose Opening Fee
/// feeds the vault) they land near the price the pool opened at, and the Creator's gain is under one basis
/// point of the Opening Fee.
/// In all three pool kinds, for a small and a large First Buy.
contract OpeningFeeEconomicsTest is TaxLocalBase, OpeningFeeHelpers {
    address internal sniper = makeAddr("sniper");

    struct Outcome {
        int256 creator; // the Creator's result in the Quote Asset: proceeds and Credit, less the First Buy
        int256 sniper; // the sniper's result: proceeds of selling everything, less what it paid
        uint256 pieces;
        uint256 placed;
        uint256 openingBooked;
    }

    function setUp() public override {
        super.setUp();
        mockQuote.mint(sniper, 1_000_000 ether);
        vm.deal(sniper, 1_000 ether);
    }

    /// One unit of the Quote Asset in each kind of pool: the native asset's Opening Value is about a
    /// fifteenth of the mock's (1.6 against 24.8), so the same shares of the supply cost a fifteenth.
    function _unit(uint256 kind) internal pure returns (uint256) {
        return kind == 2 ? 0.065 ether : 1 ether;
    }

    function _scenario(uint256 kind, uint256 firstBuy, uint256 snipe, bool place) internal returns (Outcome memory o) {
        PoolKey memory key = _launchOpen(kind, 0, firstBuy);
        int256 creatorStart = int256(_quoteBalanceOf(key, creator)) + int256(firstBuy);
        int256 sniperStart = int256(_quoteBalanceOf(key, sniper));
        if (snipe > 0) _tradeAs(sniper, key, true, true, snipe, 0);
        o.openingBooked = hook.openingFeeBooked(key.toId());
        vm.warp(_launchedAt(key) + OPENING_FEE_DURATION);
        if (place) {
            for (uint256 i; i < 3_000; i++) {
                try taxVault.addSupport(key) returns (uint256 added, uint128) {
                    o.pieces++;
                    o.placed += added;
                } catch {
                    break;
                }
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            }
        }
        uint256 coins = _coinOfKey(key).balanceOf(creator);
        if (coins > 0) _tradeAs(creator, key, false, true, coins, 0);
        coins = _coinOfKey(key).balanceOf(sniper);
        if (coins > 0) _tradeAs(sniper, key, false, true, coins, 0);
        o.creator = int256(_quoteBalanceOf(key, creator) + hook.creditOf(creator, _quoteOfKey(key))) - creatorStart;
        o.sniper = int256(_quoteBalanceOf(key, sniper)) - sniperStart;
    }

    function _log(string memory name, Outcome memory o) internal {
        emit log_string(name);
        emit log_named_decimal_int("  Creator's result", o.creator, 18);
        emit log_named_decimal_int("  sniper's result", o.sniper, 18);
        emit log_named_decimal_uint("  Opening Fee booked", o.openingBooked, 18);
        emit log_named_decimal_uint("  Support Liquidity placed", o.placed, 18);
        emit log_named_uint("  pieces (one a minute)", o.pieces);
    }

    /// The Creator gains nothing from a third party's snipe through its Support Liquidity, and sniping one's
    /// own coin from a second wallet loses.
    function _creatorGainsNothing(uint256 kind, uint256 firstBuyUnits) internal {
        uint256 u = _unit(kind);
        uint256 f = firstBuyUnits * u;
        uint256 snap = vm.snapshotState();
        Outcome memory none = _scenario(kind, f, 0, true);
        vm.revertToState(snap);
        Outcome memory unplaced = _scenario(kind, f, 20 * u, false);
        vm.revertToState(snap);
        Outcome memory placed = _scenario(kind, f, 20 * u, true);
        vm.revertToState(snap);

        emit log_named_uint("kind", kind);
        emit log_named_decimal_uint("First Buy", f, 18);
        _log("no snipe", none);
        _log("snipe of 20 units at the launch second, Support Liquidity never placed", unplaced);
        _log("snipe of 20 units at the launch second, every piece placed", placed);
        emit log_named_decimal_int(
            "  the Creator's gain from the snipe's Support Liquidity", placed.creator - unplaced.creator, 18
        );

        assertGt(placed.pieces, 0, "the snipe's Opening Fee was placed");
        // Not exactly nothing: the reference climbs 2 ticks a minute while the Creator's own coins hold the
        // price up, so the pieces placed in the last of some 150 minutes sit just above where the Creator's
        // sale ends. Measured at 0.0045% of the Opening Fee or less (0.00088 on 19.6), against 34% before the
        // reference; the bound is one basis point of it.
        int256 gain = placed.creator - unplaced.creator;
        assertLe(
            gain, int256(placed.openingBooked / 10_000), "the Creator gains nothing from the snipe's Support Liquidity"
        );
        assertLt(placed.creator + placed.sniper, none.creator, "self-sniping never pays the Creator");
    }

    function test_opening_economics_creatorGainsNothing_coinIsCurrency0_smallFirstBuy() public {
        _creatorGainsNothing(0, 2);
    }

    function test_opening_economics_creatorGainsNothing_coinIsCurrency0_largeFirstBuy() public {
        _creatorGainsNothing(0, 15);
    }

    function test_opening_economics_creatorGainsNothing_coinIsCurrency1_smallFirstBuy() public {
        _creatorGainsNothing(1, 2);
    }

    function test_opening_economics_creatorGainsNothing_coinIsCurrency1_largeFirstBuy() public {
        _creatorGainsNothing(1, 15);
    }

    function test_opening_economics_creatorGainsNothing_native_smallFirstBuy() public {
        _creatorGainsNothing(2, 2);
    }

    function test_opening_economics_creatorGainsNothing_native_largeFirstBuy() public {
        _creatorGainsNothing(2, 15);
    }
}
