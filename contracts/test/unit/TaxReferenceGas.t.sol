// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// What the reference price (#271) costs a swap, measured from outside: the gas of one swap through the
/// test router, in a standard coin and in a taxed one, in both currency orders and with the native asset.
contract TaxReferenceGasTest is TaxLocalBase {
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    enum Kind {
        Standard0,
        Standard1,
        StandardNative,
        Reward0,
        Reward1,
        RewardNative
    }

    function _coinFor(Kind k) internal returns (PoolKey memory key) {
        if (k == Kind.Standard0) {
            (, key) = _launch(false, 1 ether);
        } else if (k == Kind.Standard1) {
            (, key) = _launch(true, 1 ether);
        } else if (k == Kind.StandardNative) {
            (, key) = _launchNative(0.1 ether, address(0));
        } else if (k == Kind.Reward0) {
            key = _launchReward(false, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        } else if (k == Kind.Reward1) {
            key = _launchReward(true, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        } else {
            key = _launchNativeTyped(StokerHook.LaunchType.Reward, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        }
    }

    /// The gas of each of the four swap types, each one in a new second after the last.
    function _gasOfFour(PoolKey memory key) internal returns (uint256[4] memory g) {
        bool native = _native(key);
        uint256 buyIn = native ? 0.01 ether : 1 ether;
        // Warm every allowance and balance first, so each figure is the swap alone.
        _trade(key, trader, true, true, buyIn);
        _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
        if (!native) _approveRouter(key, trader);
        for (uint256 i; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            bool buy = i < 2;
            bool exactIn = i % 2 == 0;
            uint256 amount = buy ? (exactIn ? buyIn : 1e9 ether) : (exactIn ? 1e9 ether : buyIn / 4);
            uint160 limit = buy == _quoteIsCurrency0(key) ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
            uint256 maxIn = trader.balance;
            _coolAll(key);
            if (native) _swapNativeApproved(key, trader, buy, exactIn, amount, maxIn, limit);
            else _swapApproved(key, trader, buy, exactIn, amount);
            // The router's call alone, whatever the test's own code around it costs.
            g[i] = vm.lastCallGas().gasTotalUsed;
        }
    }

    /// Each swap is its own transaction on a chain, so every account and slot it touches starts cold.
    function _coolAll(PoolKey memory key) internal {
        vm.cool(address(pm));
        vm.cool(address(hook));
        vm.cool(address(keys));
        vm.cool(address(taxVault));
        vm.cool(address(swapRouter));
        vm.cool(address(_coinOfKey(key)));
        if (!_native(key)) vm.cool(address(quote));
    }

    /// Each swap's gas on `main` at 6c33d3f, before the Reference Price, measured by this same harness in a
    /// checkout of that commit (the router's call alone, `vm.lastCallGas`): the four swap types (buy exact in, buy exact out, sell exact in, sell exact out) for each kind.
    function _onMain(Kind k) internal pure returns (uint256[4] memory) {
        if (k == Kind.Standard0) return [uint256(177_037), 176_469, 174_176, 175_470];
        if (k == Kind.Standard1) return [uint256(177_446), 175_530, 174_028, 176_419];
        if (k == Kind.StandardNative) return [uint256(152_343), 157_180, 157_059, 159_362];
        if (k == Kind.Reward0) return [uint256(193_518), 192_886, 190_689, 191_911];
        if (k == Kind.Reward1) return [uint256(193_888), 191_908, 190_502, 192_837];
        return [uint256(168_801), 173_642, 173_549, 175_820];
    }

    /// A standard coin's swap after its Opening Fee (none booked) costs what it did but for #246's terms slot
    /// and schedule; a taxed swap pays for following its reference too. Both measured here and bounded.
    function test_gas_standardAndTaxedMeasuredAgainstMain() public {
        uint256 standardWorst;
        uint256 taxedWorst;
        for (uint256 k; k < 6; k++) {
            uint256[4] memory g = _gasOfFour(_coinFor(Kind(k)));
            uint256[4] memory was = _onMain(Kind(k));
            emit log_named_uint("kind", k);
            for (uint256 i; i < 4; i++) {
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 delta = int256(g[i]) - int256(was[i]);
                emit log_named_uint("  gas", g[i]);
                emit log_named_int("  against main", delta);
                uint256 off = delta < 0 ? uint256(-delta) : uint256(delta);
                if (k < 3 && off > standardWorst) standardWorst = off;
                if (k >= 3 && delta > 0 && uint256(delta) > taxedWorst) taxedWorst = uint256(delta);
            }
        }
        assertLe(standardWorst, STANDARD_TOLERANCE, "a standard swap's cost since #271 and #246 is bounded");
        assertLe(taxedWorst, TAXED_BOUND, "a taxed swap's reference is bounded");
    }

    /// Measured on 2026-11-24 for #271 alone: 80 gas more on a swap with the coin specified and 159 with the
    /// Quote Asset specified, under 0.1%: the comparison that skips the reference (about 30 gas in each
    /// callback), the dispatch over the hook's one new external view (about 20), and the rest the compiler's
    /// layout of the larger hook. With #246 merged: 3,232 to 4,115 gas more than 6c33d3f, about 2%: the
    /// terms' third slot read cold (2,100, the Opening Fee's terms), the schedule's and the Referrer Fee's
    /// room arithmetic, and #271's share above.
    uint256 internal constant STANDARD_TOLERANCE = 4_500;
    /// Measured for #271 alone: about 7,800 gas on a swap in a new second (the reference's slot read cold and
    /// written, and the pool's price read from the PoolManager); a second swap in the same second reads the
    /// slot alone. With #246 merged: 10,765 to 11,648 more than 6c33d3f, the same 3,200 to 4,100 above it.
    uint256 internal constant TAXED_BOUND = 12_500;
}
