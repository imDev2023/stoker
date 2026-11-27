// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DestinationsLocalBase} from "../utils/DestinationsLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {StokerTestBase} from "../utils/StokerTestBase.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The Creator Ladder's key beside the Opening Fee (#248 with #246). A raise needs Graduation, and a coin
/// inside its Opening Fee window cannot have graduated (the hold alone is an hour), so the two never act on
/// the same swap: a raise inside the window is refused by name, at its own second, mid-window and in its last
/// second, and the buys there pay #246's own Opening Fee with the Creator on the first tier's share. A coin
/// sniped in its window, later graduated and then raised credits its Creator the tier's share; the Opening
/// Fee it booked is untouched by the raise, and no swap after the window pays one. In a standard coin, a
/// Reward Launch and a Stoke Launch, in all three pool kinds; every top-level call is a transaction of its
/// own, as the hold needs.
/// forge-config: default.isolate = true
contract LadderOpeningTest is DestinationsLocalBase, OpeningFeeHelpers {
    /// The real Distributor beside the real Tax Vault, as in the Destinations' fixture.
    function _deployHoldersPart(address taxVault_)
        internal
        override(DestinationsLocalBase, StokerTestBase)
        returns (IHoldersPart)
    {
        return DestinationsLocalBase._deployHoldersPart(taxVault_);
    }

    function _aRaiseAndTheOpeningFee(uint256 kind, uint256 launchType) internal {
        PoolKey memory key = _launchOpen(kind, launchType, 0);
        PoolId id = key.toId();
        uint256 taxBps = _taxBpsOf(key);
        uint256 launchedAt = _launchedAt(key);

        // Inside the window: no raise, and each buy pays #246's own figure on the first tier's share.
        uint256[3] memory seconds_ = [uint256(0), 7, OPENING_FEE_DURATION - 1];
        for (uint256 e; e < seconds_.length; e++) {
            vm.warp(launchedAt + seconds_[e]);
            for (uint8 tier = 2; tier <= 3; tier++) {
                vm.prank(ladderKey);
                vm.expectRevert(StokerHook.NotGraduated.selector);
                hook.raiseTier(id, tier);
            }
            Seen memory snipe = _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
            uint256 rate = _openingRateAt(seconds_[e], PLATFORM_FEE_BPS + taxBps);
            assertGt(snipe.opening, 0, "inside the window: an Opening Fee was paid");
            assertEq(snipe.opening, _feesOfGross(snipe.quoteIn, 0, taxBps, rate).opening, "#246's figure");
            assertEq(
                snipe.creatorCredit,
                (snipe.creatorCredit + snipe.platformCredit) * CREATOR_SHARE_BPS / 10_000,
                "the first tier's share"
            );
        }
        assertEq(hook.creatorTierOf(id), 1, "nothing raised it inside its window");

        // After the window the coin graduates like any other, and only then is it raised.
        vm.warp(launchedAt + OPENING_FEE_DURATION);
        uint256 booked = hook.openingFeeBooked(id);
        assertGt(booked, 0);
        _graduate(key);
        assertEq(hook.openingFeeBooked(id), booked, "no Opening Fee after the window, on the crossing buy either");
        _raise(key, 2);
        assertEq(hook.openingFeeBooked(id), booked, "a raise books no Opening Fee");

        // Every swap type on the raised coin: the tier's share of the Platform Fee, and no Opening Fee.
        for (uint256 swapType; swapType < 4; swapType++) {
            bool buy = swapType < 2;
            bool exactIn = swapType % 2 == 0;
            uint256 amount = buy ? _buyAmount(key, exactIn) : (exactIn ? 1e9 ether : _buyAmount(key, true) / 20);
            Seen memory s = _tradeAndSee(key, buy, exactIn, amount, 0);
            uint256 fee = s.creatorCredit + s.platformCredit;
            assertGt(fee, 0);
            assertEq(s.opening, 0, "no Opening Fee after the window");
            assertEq(s.creatorCredit, fee * SECOND_TIER_SHARE_BPS / 10_000, "the second tier's share");
        }
        assertEq(hook.openingFeeBooked(id), booked, "the Opening Fee booked is as the window left it");
        // The coin's own book of Creator Credits holds the Credits and nothing of the Opening Fee.
        assertEq(hook.creatorCreditedOf(id), hook.creditOf(creator, _quoteOfKey(key)), "the book is the Credits");
        assertEq(_vaultClaims(key), hook.taxBooked(id) + booked, "the vault has the tax and the Opening Fee");
    }

    function test_ladderAndTheOpeningFee_standard() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _aRaiseAndTheOpeningFee(kind, 0);
            vm.revertToState(snap);
        }
    }

    function test_ladderAndTheOpeningFee_aRewardLaunch() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _aRaiseAndTheOpeningFee(kind, 1);
            vm.revertToState(snap);
        }
    }

    function test_ladderAndTheOpeningFee_aStokeLaunch() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            _aRaiseAndTheOpeningFee(kind, 2);
            vm.revertToState(snap);
        }
    }
}
