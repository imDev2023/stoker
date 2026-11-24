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

    /// What a swap costs against `main` before the Reference Price, measured and bounded. Until #248 a
    /// standard coin's swap skipped the reference and cost what it did (80 to 159 gas more); since #248 every
    /// pool keeps one, since anyone may fund any coin's burn or Support Liquidity, and every swap also reads
    /// the coin's Creator Tier and adds to its book of Creator Credits. So a standard swap and a taxed one
    /// now pay the same sum over what each cost on `main`.
    function test_gas_everySwapMeasured_andBounded() public {
        uint256 worst;
        uint256 least = type(uint256).max;
        for (uint256 k; k < 6; k++) {
            uint256[4] memory g = _gasOfFour(_coinFor(Kind(k)));
            uint256[4] memory was = _onMain(Kind(k));
            emit log_named_uint("kind", k);
            for (uint256 i; i < 4; i++) {
                // #244's Graduation Hold landed after these figures were recorded: every swap here is a
                // pool's first in its transaction, and judges the hold (HOLD_JUDGEMENT), standard or taxed.
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 delta = int256(g[i]) - int256(was[i]) - int256(HOLD_JUDGEMENT);
                emit log_named_uint("  gas", g[i]);
                emit log_named_int("  against main", delta);
                assertGt(delta, 0, "no swap got cheaper");
                // forge-lint: disable-next-line(unsafe-typecast)
                if (uint256(delta) > worst) worst = uint256(delta);
                // forge-lint: disable-next-line(unsafe-typecast)
                if (uint256(delta) < least) least = uint256(delta);
            }
        }
        assertLe(worst, SWAP_BOUND, "a swap's reference and its Creator book are bounded");
        assertLe(worst - least, 200, "a standard swap and a taxed one pay the same for them");
    }

    /// Measured on 2026-11-24 with #248: 15,921 to 16,020 gas more than on `main` at 6c33d3f for every kind
    /// and every swap type, each swap in a new second with every account cold. About 7,800 of it is the
    /// Reference Price (#271: its slot read cold and written, and the pool's price read from the
    /// PoolManager), which a taxed swap has paid since #271 and a standard one pays since #248; about 8,200
    /// is #248's own: the coin's tier and book (one slot read cold and written, 5,000) and the Launch's terms
    /// reaching a third slot for the top tier's share (2,200), the rest the arithmetic and the larger hook.
    uint256 internal constant SWAP_BOUND = 16_500;
    /// What #244's Graduation Hold adds to a pool's first swap in a transaction, standard or taxed: the hold's
    /// record read cold and written (`lastSwapAt`), the pool's price read, and a transient flag set. Measured
    /// on 2026-11-24 at 8,713 to 8,793 gas by #244, and taken off each figure above.
    uint256 internal constant HOLD_JUDGEMENT = 8_750;
}
