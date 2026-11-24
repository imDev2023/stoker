// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IReferenceSettings
/// @notice The two rates of every taxed pool's Reference Price (#271), fixed when the Tax Vault is deployed.
///         The hook reads them from the Tax Vault once, in its constructor, and keeps them as its own
///         immutables, so the Tax Vault's spending rule and the price it trusts are set in one place.
interface IReferenceSettings {
    /// @notice The most the Reference Price rises toward a dearer coin, in ticks per minute the price stood.
    function referenceRiseTicksPerMinute() external view returns (uint24);

    /// @notice The most the Reference Price falls toward a cheaper coin, in ticks per minute the price stood.
    function referenceFallTicksPerMinute() external view returns (uint24);
}
