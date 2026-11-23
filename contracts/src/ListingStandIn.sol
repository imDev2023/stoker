// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IQuoteListings} from "./interfaces/IQuoteListings.sol";

/// @title ListingStandIn
/// @notice A minimal stand-in for the Quote Registry, so the first path can launch (#241).
///         It holds a start price per Quote Asset and nothing else: no Graduation multiple, no Referrer
///         Fee cap, no write limits and no two-step Admin. The Quote Registry (#243, ADR 0028) replaces it
///         behind the same `IQuoteListings` interface; it is never deployed to a live chain.
contract ListingStandIn is IQuoteListings {
    /// @notice The one address that may write a Listing.
    address public immutable writer;

    mapping(address quote => Listing) internal _listings;

    event Listed(address indexed quote, int24 startTick);

    error NotWriter();
    error NativeAssetNotYet();

    constructor(address writer_) {
        writer = writer_;
    }

    /// @notice Lists `quote` with a start price. The native asset is refused until its own slice (#242).
    function list(address quote, int24 startTick) external {
        if (msg.sender != writer) revert NotWriter();
        if (quote == address(0)) revert NativeAssetNotYet();
        _listings[quote] = Listing({listed: true, startTick: startTick});
        emit Listed(quote, startTick);
    }

    /// @inheritdoc IQuoteListings
    function listingOf(address quote) external view returns (Listing memory) {
        return _listings[quote];
    }
}
