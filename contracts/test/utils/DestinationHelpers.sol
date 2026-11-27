// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {BurnDestination} from "../../src/destinations/BurnDestination.sol";
import {LiquidityDestination} from "../../src/destinations/LiquidityDestination.sol";
import {HoldersDestination} from "../../src/destinations/HoldersDestination.sol";
import {StokerTestBase} from "./StokerTestBase.sol";
import {TaxHelpers} from "./TaxHelpers.sol";
import {DistributorHelpers} from "./DistributorHelpers.sol";

/// @notice What the tests of the Creator Ladder's key and the Creator Earnings Destinations share, locally and
///         on the fork (#248): the real Distributor beside the real Tax Vault, the ladder key named through
///         the Admin's two steps, the three Destination contracts, and a Launch of any type naming any
///         Destination in each of the three pool kinds.
abstract contract DestinationHelpers is TaxHelpers, DistributorHelpers {
    address internal ladderKey = makeAddr("ladderKey");
    BurnDestination internal burnDestination;
    LiquidityDestination internal liquidityDestination;
    HoldersDestination internal holdersDestination;

    /// The three pool kinds every path is tested in.
    uint256 internal constant QUOTE_FIRST = 0; // the Quote Asset as currency0, the coin as currency1
    uint256 internal constant COIN_FIRST = 1; // the coin as currency0
    uint256 internal constant NATIVE_PAIR = 2; // paired with the native asset, always currency0

    function _deployHoldersPart(address taxVault_)
        internal
        virtual
        override(StokerTestBase, DistributorHelpers)
        returns (IHoldersPart)
    {
        return DistributorHelpers._deployHoldersPart(taxVault_);
    }

    /// After `_deployStoker`: the round key and the ladder key, and one Destination of each kind.
    function _deployDestinations() internal {
        _deployDistributor();
        _setKey(StokerKeys.Role.LadderKey, ladderKey);
        burnDestination = new BurnDestination(hook);
        liquidityDestination = new LiquidityDestination(hook);
        holdersDestination = new HoldersDestination(hook);
    }

    function _setKey(StokerKeys.Role role, address who) internal {
        vm.prank(keys.admin());
        keys.proposeKey(role, who);
        vm.prank(who);
        keys.acceptKey(role);
    }

    /// Buys the coin across its Graduation Target from a wallet of its own, waits the hour and records
    /// Graduation (#244). The hold judges the price each transaction leaves, so a test that calls this runs
    /// with every top-level call a transaction of its own (Foundry's isolate mode, set on the test contract).
    function _graduate(PoolKey memory key) internal {
        address graduator = makeAddr("graduator");
        uint256 amount = _native(key) ? 7 ether : 100 ether;
        if (_native(key)) vm.deal(graduator, graduator.balance + amount);
        else deal(address(quote), graduator, quote.balanceOf(graduator) + amount);
        _trade(key, graduator, true, true, amount);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        hook.graduate(key.toId());
        assertGt(hook.graduationOf(key.toId()).graduatedAt, 0, "graduated");
    }

    /// A raise by the ladder key; the coin must have graduated (`_graduate`).
    function _raise(PoolKey memory key, uint8 tier) internal {
        vm.prank(ladderKey);
        hook.raiseTier(key.toId(), tier);
    }

    // ---------------------------------------------------------------- launching to a Destination

    /// A standard Launch in pool kind `kind` whose Creator Earnings Destination is `destination` (zero for
    /// the Creator's own wallet), with no First Buy.
    function _launchTo(uint256 kind, address destination) internal returns (PoolKey memory key) {
        return
            _launchTypedTo(
                kind, destination, StokerHook.LaunchType.Standard, 0, 0, 0, StokerHook.PayoutAsset.QuoteAsset
            );
    }

    /// A Reward Launch at `TAX_BPS` with the given shares, naming `destination`.
    function _launchRewardTo(uint256 kind, address destination, uint16 burnShareBps, uint16 liquidityShareBps)
        internal
        returns (PoolKey memory key)
    {
        return _launchTypedTo(
            kind,
            destination,
            StokerHook.LaunchType.Reward,
            TAX_BPS,
            burnShareBps,
            liquidityShareBps,
            StokerHook.PayoutAsset.QuoteAsset
        );
    }

    function _launchTypedTo(
        uint256 kind,
        address destination,
        StokerHook.LaunchType launchType,
        uint16 taxBps,
        uint16 burnShareBps,
        uint16 liquidityShareBps,
        StokerHook.PayoutAsset payoutAsset
    ) internal returns (PoolKey memory key) {
        StokerFactory.LaunchParams memory p = _typedParams(
            kind == NATIVE_PAIR ? address(0) : address(quote),
            kind == QUOTE_FIRST,
            0,
            launchType,
            taxBps,
            burnShareBps,
            liquidityShareBps,
            payoutAsset
        );
        p.creatorDestination = destination;
        (, key) = _launchWith(p);
    }

    // ---------------------------------------------------------------- reading from outside

    /// A unit of the pool's Quote Asset that a test trades in: small against the native Opening Value.
    function _unit(PoolKey memory key) internal pure returns (uint256) {
        return _native(key) ? 0.01 ether : 1 ether;
    }

    function _creditIn(PoolKey memory key, address owner) internal view returns (uint256) {
        return hook.creditOf(owner, _quoteOfKey(key));
    }

    function _destinationOf(PoolKey memory key) internal view returns (address) {
        return hook.termsOf(key.toId()).creatorDestination;
    }

    function _credited(PoolKey memory key) internal view returns (uint256) {
        return hook.creatorCreditedOf(key.toId());
    }

    function _id(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }

    function _assetBalance(PoolKey memory key, address who) internal view returns (uint256) {
        return _balance(_quoteOfKey(key), who);
    }

    /// Buys and sells in the pool as the trader, so its Creator's Destination is credited.
    function _churn(PoolKey memory key, uint256 rounds) internal {
        uint256 unit = _unit(key);
        for (uint256 i; i < rounds; i++) {
            _trade(key, trader, true, true, 20 * unit);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
        }
    }

    /// A copy of the key on another tick spacing: a pool our factory never opened. A memory struct is
    /// assigned by reference, so a test that changed a field of `key` itself would lose the coin's own key.
    function _onAnotherSpacing(PoolKey memory key) internal pure returns (PoolKey memory other) {
        other = PoolKey(key.currency0, key.currency1, key.fee, 60, key.hooks);
    }

    /// A copy of the key on no hook.
    function _onNoHook(PoolKey memory key) internal pure returns (PoolKey memory other) {
        other = PoolKey(key.currency0, key.currency1, key.fee, key.tickSpacing, IHooks(address(0)));
    }

    function _currencyOfCoin(PoolKey memory key) internal view returns (Currency) {
        return Currency.wrap(address(_coinOfKey(key)));
    }
}
