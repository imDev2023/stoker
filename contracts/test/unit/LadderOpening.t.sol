// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {StokerTestBase} from "../utils/StokerTestBase.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";

/// The Creator Ladder's key beside the Opening Fee (#248 with #246): a raise on a coin still inside its
/// Opening Fee window changes the Creator's part of the Platform Fee and nothing of the Opening Fee. The buyer
/// pays and receives the same, the Opening Fee booked for the coin's Support Liquidity is the same to the wei
/// and is #246's own figure, the tax is the same, and the raise itself books nothing. In a standard coin, a
/// Reward Launch and a Stoke Launch, in all three pool kinds, at the launch's own second, inside the window
/// and in its last second, for a buy exact in and exact out and for a sell.
contract LadderOpeningTest is DestinationsLocalBase, OpeningFeeHelpers {
    /// The real Distributor beside the real Tax Vault, as in the Destinations' fixture.
    function _deployHoldersPart(address taxVault_)
        internal
        override(DestinationsLocalBase, StokerTestBase)
        returns (IHoldersPart)
    {
        return DestinationsLocalBase._deployHoldersPart(taxVault_);
    }

    /// One buy at `elapsed` seconds after the launch on the given tier, and the coins it delivered; the state
    /// is restored afterwards.
    function _buyOnTier(PoolKey memory key, uint8 tier, uint256 elapsed, bool exactIn)
        internal
        returns (Seen memory s, uint256 coins, uint256 bookedByTheRaise)
    {
        uint256 snap = vm.snapshotState();
        vm.warp(_launchedAt(key) + elapsed);
        uint256 booked = hook.openingFeeBooked(key.toId());
        if (tier > 1) _raise(key, tier);
        bookedByTheRaise = hook.openingFeeBooked(key.toId()) - booked;
        uint256 before = _coinOfKey(key).balanceOf(trader);
        s = _tradeAndSee(key, true, exactIn, _buyAmount(key, exactIn), 0);
        coins = _coinOfKey(key).balanceOf(trader) - before;
        vm.revertToState(snap);
    }

    function _aRaiseInsideTheWindow(uint256 kind, uint256 launchType) internal {
        PoolKey memory key = _launchOpen(kind, launchType, 0);
        uint256 taxBps = _taxBpsOf(key);
        uint256[3] memory seconds_ = [uint256(0), 7, OPENING_FEE_DURATION - 1];
        uint16[3] memory shares = [CREATOR_SHARE_BPS, SECOND_TIER_SHARE_BPS, TOP_TIER_SHARE_BPS];
        for (uint256 e; e < seconds_.length; e++) {
            for (uint256 x; x < 2; x++) {
                bool exactIn = x == 0;
                (Seen memory first, uint256 firstCoins,) = _buyOnTier(key, 1, seconds_[e], exactIn);
                uint256 fee = first.creatorCredit + first.platformCredit;
                assertGt(first.opening, 0, "inside the window: an Opening Fee was paid");
                assertGt(first.opening, fee, "and it dwarfs the Platform Fee");
                assertEq(first.creatorCredit, fee * shares[0] / 10_000, "the first tier's share");
                if (exactIn) {
                    // #246's own figure for this second, from the rule kept in its tests.
                    uint256 rate = _openingRateAt(seconds_[e], PLATFORM_FEE_BPS + taxBps);
                    assertEq(first.opening, _feesOfGross(first.quoteIn, 0, taxBps, rate).opening, "#246's figure");
                }
                for (uint8 tier = 2; tier <= 3; tier++) {
                    (Seen memory raised, uint256 coins, uint256 bookedByTheRaise) =
                        _buyOnTier(key, tier, seconds_[e], exactIn);
                    assertEq(bookedByTheRaise, 0, "a raise books no Opening Fee");
                    // The Opening Fee is untouched, with everything else the buyer pays.
                    assertEq(raised.opening, first.opening, "the Opening Fee is the same to the wei");
                    assertEq(raised.tax, first.tax, "the tax is the same");
                    assertEq(raised.vaultClaims, first.vaultClaims, "the vault was given the same");
                    assertEq(raised.quoteIn, first.quoteIn, "the buyer pays the same");
                    assertEq(coins, firstCoins, "the buyer receives the same");
                    // The Creator's Credit follows the tier, and the platform has the rest of the same fee.
                    assertEq(raised.creatorCredit + raised.platformCredit, fee, "the Platform Fee is the same");
                    assertEq(raised.creatorCredit, fee * shares[tier - 1] / 10_000, "the tier's share");
                    assertGt(raised.creatorCredit, first.creatorCredit);
                }
            }
        }

        // A sell inside the window pays no Opening Fee on any tier, and its Credit follows the tier too.
        vm.warp(_launchedAt(key) + 3);
        _tradeAndSee(key, true, true, _buyAmount(key, true) * 20, 0);
        _raise(key, 2);
        Seen memory sold = _tradeAndSee(key, false, true, _coinOfKey(key).balanceOf(trader) / 2, 0);
        assertEq(sold.opening, 0, "a sell never pays it");
        assertEq(
            sold.creatorCredit,
            (sold.creatorCredit + sold.platformCredit) * SECOND_TIER_SHARE_BPS / 10_000,
            "the second tier's share of a sell's fee"
        );
        // The coin's own book of Creator Credits holds the Credits and nothing of the Opening Fee.
        PoolId id = key.toId();
        assertEq(hook.creatorCreditedOf(id), hook.creditOf(creator, _quoteOfKey(key)), "the book is the Credits");
        assertEq(_vaultClaims(key), hook.taxBooked(id) + hook.openingFeeBooked(id), "the vault has the rest");
    }

    function test_ladderInTheOpening_standard() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _aRaiseInsideTheWindow(kind, 0);
            vm.revertToState(snap);
        }
    }

    function test_ladderInTheOpening_aRewardLaunch() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _aRaiseInsideTheWindow(kind, 1);
            vm.revertToState(snap);
        }
    }

    function test_ladderInTheOpening_aStokeLaunch() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _aRaiseInsideTheWindow(kind, 2);
            vm.revertToState(snap);
        }
    }
}
