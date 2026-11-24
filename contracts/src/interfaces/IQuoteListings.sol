// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IQuoteListings
/// @notice What the factory reads from a chain's Quote Registry at launch: one Listing per Quote Asset
///         (ADR 0028), every figure of which a new Launch copies into its own terms.
interface IQuoteListings {
    /// @param listed Whether the asset may be a Quote Asset of a new Launch.
    /// @param startTick The coin's start price as a tick of the Quote Asset's raw units per one raw unit
    ///        of the coin, whatever the pool's currency order. A multiple of the registry's tick spacing.
    ///        It sets the Opening Value: what the whole supply is worth at the start price.
    /// @param graduationMultiple The Graduation Target as a multiple of the start price (ADR 0024: 20 at
    ///        first).
    /// @param referrerFeeCapBps The most a trade may name as its Referrer Fee, in basis points of the Quote
    ///        Asset's side (ADR 0027).
    struct Listing {
        bool listed;
        int24 startTick;
        uint16 graduationMultiple;
        uint16 referrerFeeCapBps;
    }

    /// @notice The Listing of `quote` in force now, where the zero address is the chain's native asset
    ///         (native ETH in the pool key, never a wrapped asset); an asset never listed answers
    ///         `listed == false`.
    function listingOf(address quote) external view returns (Listing memory);

    /// @notice The tick spacing every start price is a multiple of, and every pool opens with.
    function tickSpacing() external view returns (int24);
}
