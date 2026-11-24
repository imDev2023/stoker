// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ForkBase} from "./ForkBase.sol";
import {DistributorHelpers} from "../utils/DistributorHelpers.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {StokerTestBase} from "../utils/StokerTestBase.sol";

/// @notice The Distributor's fork fixture (#247): Robinhood Chain at the pinned block, our contracts on the
///         real PoolManager, three coins launched (paired with NVDA as currency0 and as currency1, and with
///         native ETH, always currency0), and the Distributor beside the real Tax Vault.
///         Kept small so the contracts over it stay clear of the compiler's stack limit (gotcha 9).
abstract contract ForkDistributorBase is ForkBase, DistributorHelpers {
    /// The real Distributor in the stand-in's place (`DistributorHelpers`).
    function _deployHoldersPart(address taxVault_)
        internal
        virtual
        override(StokerTestBase, DistributorHelpers)
        returns (IHoldersPart)
    {
        return DistributorHelpers._deployHoldersPart(taxVault_);
    }

    Currency internal constant NVDA_ASSET = Currency.wrap(NVDA);
    Currency internal constant ETH = Currency.wrap(address(0));
    uint256 internal constant KEEPER_GAS = 1_000_000;

    /// NVDA as currency0 (the coin as currency1), NVDA as currency1 (the coin as currency0), native ETH.
    address internal coinA;
    address internal coinB;
    address internal coinN;

    function setUp() public virtual override {
        super.setUp();
        _listNative();
        (coinA,) = _launch(true, 0);
        (coinB,) = _launch(false, 0);
        (coinN,) = _launchNative(0, creator);
        _deployDistributor();
    }

    /// The issuer's global pause: every Stock Token asks the registry `paused()` on every transfer.
    function _pauseRegistry() internal {
        vm.mockCall(STOCK_REGISTRY, abi.encodeWithSignature("paused()"), abi.encode(true));
    }
}
