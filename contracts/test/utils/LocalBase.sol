// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerTestBase} from "./StokerTestBase.sol";
import {MockQuote} from "./MockQuote.sol";

/// @notice The local fixture: v4-core's PoolManager compiled from source, a mock Stock Token as the
///         Quote Asset, and our contracts. Needs no RPC, so CI runs it on every push.
abstract contract LocalBase is StokerTestBase {
    MockQuote internal mockQuote;

    function setUp() public virtual {
        pm = new PoolManager(address(this));
        mockQuote = new MockQuote();
        quote = IERC20(address(mockQuote));
        _deployStoker();
        mockQuote.mint(creator, 1_000 ether);
        mockQuote.mint(trader, 100_000 ether);
    }
}
