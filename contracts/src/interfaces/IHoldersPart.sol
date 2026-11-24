// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @title IHoldersPart
/// @notice What the Tax Vault hands a Reward Launch's holders' part to: the Distributor (#247, ADR 0029),
///         an address fixed when the Tax Vault is deployed.
/// @dev The Tax Vault calls `deposit` with the PoolManager locked, outside any swap.
///      - `asset` is the Quote Asset, or the coin itself when the Launch's Payout Asset is the coin and the
///        Tax Vault bought it with its capped buy.
///      - The native asset is `Currency.wrap(address(0))` and arrives as the call's value, exactly `amount`.
///      - An ERC-20 is approved to the Distributor for exactly `amount` just before the call, and the
///        Distributor pulls it with `transferFrom` inside `deposit`; the Tax Vault reverts the whole call
///        unless exactly `amount` left it, and clears the allowance afterwards. No value is sent with an
///        ERC-20.
///      - A `deposit` that reverts (a Stock Token's blocklist or pause, for instance) reverts the Tax
///        Vault's call, and the holders' part stays where it was.
interface IHoldersPart {
    /// @param coin The coin whose holders the amount belongs to.
    /// @param asset The asset deposited: the Quote Asset or the coin.
    /// @param amount The amount deposited, in `asset`'s raw units.
    function deposit(address coin, Currency asset, uint256 amount) external payable;
}
