// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "./LocalBase.sol";
import {StokerTestBase} from "./StokerTestBase.sol";
import {DestinationHelpers} from "./DestinationHelpers.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";

/// @notice The local fixture of the Creator Ladder's key and the Destinations (#248): the whole local stack
///         with the real Distributor beside the real Tax Vault, the mock Stock Token and the native asset
///         both listed, the three Destination contracts, and traders funded in both assets.
abstract contract DestinationsLocalBase is LocalBase, DestinationHelpers {
    function _deployHoldersPart(address taxVault_)
        internal
        virtual
        override(StokerTestBase, DestinationHelpers)
        returns (IHoldersPart)
    {
        return DestinationHelpers._deployHoldersPart(taxVault_);
    }

    function setUp() public virtual override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
        mockQuote.mint(trader, 1_000_000 ether);
        _deployDestinations();
    }
}
