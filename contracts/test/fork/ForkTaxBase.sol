// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForkBase} from "./ForkBase.sol";
import {TaxHelpers} from "../utils/TaxHelpers.sol";

/// @notice The tax's fork fixture (#245): Robinhood Chain at the pinned block, NVDA and native ETH both
///         listed, and trades through the test router in either kind of pool. A small base, so each fork
///         contract over it stays clear of the compiler's stack limit (gotcha 9).
abstract contract ForkTaxBase is ForkBase, TaxHelpers {
    function setUp() public virtual override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
        deal(NVDA, trader, 100_000 ether);
    }
}
