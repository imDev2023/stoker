// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ForkTaxRouteBase} from "./ForkTaxRouteBase.sol";
import {DestinationHelpers} from "../utils/DestinationHelpers.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {StokerTestBase} from "../utils/StokerTestBase.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";

/// @notice The fork fixture of the Creator Ladder's key and the Destinations (#248): Robinhood Chain at the
///         pinned block, our contracts on the real PoolManager with the real Distributor beside the real Tax
///         Vault, NVDA and native ETH both listed, the ladder key named, and the three Destination
///         contracts. Kept small, with each test contract over it small too, so none meets the compiler's
///         stack limit (gotcha 9).
abstract contract ForkDestinationsBase is ForkTaxRouteBase, DestinationHelpers {
    uint256 internal constant KEEPER_GAS = 1_000_000;

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
        _deployDestinations();
    }

    /// The coin as currency1 of an NVDA pool, as currency0 of one, and paired with native ETH.
    function _kindName(uint256 kind) internal pure returns (string memory) {
        return kind == QUOTE_FIRST ? "NVDA as currency0" : kind == COIN_FIRST ? "the coin as currency0" : "native ETH";
    }

    /// Trades a coin through the Universal Router the chain's traffic uses and through the test router, so
    /// its Creator's Destination is credited, and lets the price stand (#271).
    function _earnThrough(PoolKey memory key) internal {
        _approveFor(UNIVERSAL_ROUTER, trader, key);
        Trade memory buy = Trade(true, true, 20 * _unit(key));
        _route(UNIVERSAL_ROUTER, trader, key, buy, _quoteTrade(key, buy));
        _churn(key, 2);
        _letThePriceStand();
    }

    function _applyBy(address who, EarningsDestination d, PoolKey memory key) internal returns (uint256) {
        vm.prank(who);
        return d.applyEarnings(key);
    }

    function _asset(PoolKey memory key) internal view returns (Currency) {
        return _quoteOfKey(key);
    }
}
