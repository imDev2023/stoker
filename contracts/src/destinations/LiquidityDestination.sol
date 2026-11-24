// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StokerHook} from "../StokerHook.sol";
import {TaxVault} from "../TaxVault.sol";
import {EarningsDestination} from "./EarningsDestination.sol";

/// @title LiquidityDestination
/// @notice The Creator Earnings Destination of the liquidity (ADR 0011's `liquidity`, on an EVM chain,
///         #248): a coin's Creator earnings become Support Liquidity in the coin's own pool, Quote Asset alone
///         in a locked position, with no coin bought (ADR 0025).
///
///         It adds no liquidity itself: the hook admits only the factory and the Tax Vault. It gives each
///         coin's earnings to that coin's Support Liquidity in the Tax Vault (`TaxVault.fundSupport`), whose
///         `addSupport` places them in the same capped pieces and by the same addition as a coin's tax.
contract LiquidityDestination is EarningsDestination {
    /// @notice The Tax Vault of the hook, which holds every Support Liquidity position.
    TaxVault public immutable taxVault;

    constructor(StokerHook hook_) EarningsDestination(hook_) {
        taxVault = TaxVault(payable(hook_.taxVault()));
    }

    function _apply(PoolKey calldata key, Currency asset, uint256 amount) internal override {
        if (asset.isAddressZero()) {
            taxVault.fundSupport{value: amount}(key, amount);
            return;
        }
        uint256 before = _approve(asset, address(taxVault), amount);
        taxVault.fundSupport(key, amount);
        _settled(asset, address(taxVault), amount, before);
    }
}
