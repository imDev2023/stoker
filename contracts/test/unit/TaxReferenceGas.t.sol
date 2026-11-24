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
            uint256 before = gasleft();
            if (native) _swapNativeApproved(key, trader, buy, exactIn, amount, maxIn, limit);
            else _swapApproved(key, trader, buy, exactIn, amount);
            g[i] = before - gasleft();
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

    function test_gas_logged() public {
        for (uint256 k; k < 6; k++) {
            uint256[4] memory g = _gasOfFour(_coinFor(Kind(k)));
            emit log_named_uint("kind", k);
            for (uint256 i; i < 4; i++) {
                emit log_named_uint("  gas", g[i]);
            }
        }
    }
}
