// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LocalBase} from "./LocalBase.sol";
import {DistributorHelpers} from "./DistributorHelpers.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {StokerTestBase} from "./StokerTestBase.sol";

/// @notice The Distributor's local fixture: the whole local stack (keys, registry, factory, hook, a mock
///         Stock Token as the Quote Asset), two coins launched in either currency order, and the
///         Distributor beside the real Tax Vault, each deployed knowing the other.
abstract contract DistributorLocalBase is LocalBase, DistributorHelpers {
    /// The real Distributor in the stand-in's place (`DistributorHelpers`).
    function _deployHoldersPart(address taxVault_)
        internal
        override(StokerTestBase, DistributorHelpers)
        returns (IHoldersPart)
    {
        return DistributorHelpers._deployHoldersPart(taxVault_);
    }

    /// The mock Stock Token, with its issuer's blocklist.
    Currency internal stock;
    /// A coin with the Quote Asset as currency0, and one with it as currency1.
    address internal coinA;
    address internal coinB;

    function setUp() public virtual override {
        super.setUp();
        stock = Currency.wrap(address(mockQuote));
        (coinA,) = _launch(true, 0);
        (coinB,) = _launch(false, 0);
        _deployDistributor();
    }
}
