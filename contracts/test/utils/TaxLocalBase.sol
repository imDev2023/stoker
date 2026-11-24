// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "./LocalBase.sol";
import {TaxHelpers} from "./TaxHelpers.sol";

/// @notice The tax's local fixture (#245): the mock Stock Token and the native asset both listed, and
///         traders funded in both.
abstract contract TaxLocalBase is LocalBase, TaxHelpers {
    function setUp() public virtual override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
        mockQuote.mint(trader, 1_000_000 ether);
    }
}
