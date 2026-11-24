// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";

/// What a swap costs in gas, logged so the same file run on `main` before #248 and on this branch shows
/// what the Creator Tier and the per-coin book of Creator Credits add (#248). The hook's storage is made
/// cold before each swap, as it is at the start of a real transaction; the PoolManager's is not, so the
/// figures compare with each other and not with a transaction's receipt.
contract LadderGasTest is TaxLocalBase {
    function _measure(PoolKey memory key, bool buy, bool exactIn, uint256 amount) internal returns (uint256 used) {
        if (!_native(key)) _approveRouter(key, trader);
        vm.cool(address(hook));
        uint256 before = gasleft();
        _trade(key, trader, buy, exactIn, amount);
        used = before - gasleft();
    }

    function test_gas_aSwapInAStandardCoin() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key;
            if (kind == 2) (, key) = _launchNative(0.01 ether, address(0));
            else (, key) = _launch(kind == 0, 1 ether);
            uint256 unit = kind == 2 ? 0.01 ether : 1 ether;
            // The pool's second and later swaps: every slot the hook writes is already non-zero.
            _trade(key, trader, true, true, unit);
            emit log_named_uint(kind == 0 ? "quote as currency0" : kind == 1 ? "coin as currency0" : "native", kind);
            emit log_named_uint("  buy, exact in", _measure(key, true, true, unit));
            emit log_named_uint("  buy, exact out", _measure(key, true, false, 1e9 ether));
            emit log_named_uint("  sell, exact in", _measure(key, false, true, 1e9 ether));
            emit log_named_uint("  sell, exact out", _measure(key, false, false, unit / 100));
        }
    }
}
