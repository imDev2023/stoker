// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IQuoteListings
/// @notice What the factory reads from a chain's Quote Registry at launch: one Listing per Quote Asset.
/// @dev The Quote Registry with its Admin, its write limits, the Graduation multiple and the Referrer
///      Fee's cap is its own slice (#243, ADR 0028). Until then `ListingStandIn` answers this interface.
interface IQuoteListings {
    /// @param listed Whether the asset may be a Quote Asset at all.
    /// @param startTick The coin's start price as a tick of the Quote Asset's raw units per one raw unit
    ///        of the coin, whatever the pool's currency order. A multiple of the factory's tick spacing.
    struct Listing {
        bool listed;
        int24 startTick;
    }

    /// @notice The Listing of `quote`; an asset never listed answers `listed == false`.
    function listingOf(address quote) external view returns (Listing memory);
}
