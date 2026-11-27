// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StokerHook} from "../StokerHook.sol";
import {TaxVault} from "../TaxVault.sol";
import {EarningsDestination} from "./EarningsDestination.sol";

/// @title BurnDestination
/// @notice The Creator Earnings Destination of the burn (ADR 0011's `burn`, on an EVM chain, #248): a
///         coin's Creator earnings buy the coin in its own pool and what they buy is burned.
///
///         It does not buy. It gives each coin's earnings to that coin's burn in the Tax Vault
///         (`TaxVault.fundBurn`), whose `burn` spends them in the same capped pieces, at the same interval and
///         by the same buy as a Reward Burn, outside any trader's swap.
contract BurnDestination is EarningsDestination {
    /// @notice The Tax Vault of the hook, where every coin's burn is funded and made.
    TaxVault public immutable taxVault;

    constructor(StokerHook hook_) EarningsDestination(hook_) {
        taxVault = TaxVault(payable(hook_.taxVault()));
    }

    function _apply(PoolKey calldata key, Currency asset, uint256 amount) internal override {
        if (asset.isAddressZero()) {
            taxVault.fundBurn{value: amount}(key, amount);
            return;
        }
        uint256 before = _approve(asset, address(taxVault), amount);
        taxVault.fundBurn(key, amount);
        _settled(asset, address(taxVault), amount, before);
    }
}
