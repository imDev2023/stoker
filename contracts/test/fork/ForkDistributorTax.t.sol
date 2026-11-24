// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerHook} from "../../src/StokerHook.sol";
import {ForkDistributorBase} from "./ForkDistributorBase.sol";
import {TaxHelpers} from "../utils/TaxHelpers.sol";
import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";
import {StokerTestBase} from "../utils/StokerTestBase.sol";

/// Holder Rewards from real tax on the real PoolManager (#247 with #245): Reward Launches paired with NVDA
/// in either currency order and with native ETH are traded, the Tax Vault's public calls hand the holders'
/// part to the Distributor, and a round pays the holders from it. With the coin as the Payout Asset the
/// vault buys the coin in capped pieces first; with the Quote Asset it hands the tax over as collected.
contract ForkDistributorTaxTest is ForkDistributorBase, TaxHelpers {
    /// The real Distributor in the stand-in's place (`DistributorHelpers`).
    function _deployHoldersPart(address taxVault_)
        internal
        override(StokerTestBase, ForkDistributorBase)
        returns (IHoldersPart)
    {
        return ForkDistributorBase._deployHoldersPart(taxVault_);
    }

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
        deal(NVDA, trader, 100_000 ether);
    }

    /// A Reward Launch whose Payout Asset is the coin pays its holders in the coin, bought with the holders'
    /// part in capped pieces, one per interval, then handed to the Distributor: for a coin on either side of
    /// an NVDA pool and for a coin paired with native ETH.
    function test_fork_aPayoutAssetOfTheCoin_isBoughtInCappedPieces_andPaidToHolders() public {
        PoolKey[3] memory keys_ = [
            _launchReward(true, 0, 0, StokerHook.PayoutAsset.Coin),
            _launchReward(false, 0, 0, StokerHook.PayoutAsset.Coin),
            _launchNativeTyped(StokerHook.LaunchType.Reward, 0, 0, StokerHook.PayoutAsset.Coin)
        ];
        for (uint256 k; k < 3; k++) {
            PoolKey memory key = keys_[k];
            address coin = address(_coinOfKey(key));
            _taxThrough(key);

            uint256 pieces;
            uint256 bought;
            while (true) {
                (,, uint256 waitingQuote,) = taxVault.waiting(key);
                if (waitingQuote == 0) break;
                uint256 cap = taxVault.pieceCap(key);
                vm.prank(stranger);
                (uint256 spent, uint256 got) = taxVault.buyForHolders(key);
                assertLe(spent, cap, "each piece within the cap");
                assertGt(got, 0);
                bought += got;
                pieces++;
                assertLt(pieces, 400, "the holders' part runs out");
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            }
            assertGt(pieces, 1, "bought in more than one capped piece");
            assertEq(IERC20(coin).balanceOf(address(distributor)), 0, "nothing reaches it before the hand-off");

            vm.prank(stranger);
            (Currency asset, uint256 amount) = taxVault.passHoldersPart(key);
            assertEq(Currency.unwrap(asset), coin, "paid in the coin");
            assertEq(amount, bought, "every coin bought for the holders");
            assertEq(distributor.potOf(coin, asset), amount);
            assertEq(IERC20(coin).balanceOf(address(distributor)), amount);

            _payTwoHolders(coin, asset, amount);
            emit log_named_uint("capped pieces", pieces);
        }
    }

    /// A Reward Launch whose Payout Asset is the Quote Asset pays its holders in it, handed over as
    /// collected: NVDA in either currency order and native ETH.
    function test_fork_aPayoutAssetOfTheQuoteAsset_isPaidAsCollected() public {
        PoolKey[3] memory keys_ = [
            _launchReward(true, 0, 0, StokerHook.PayoutAsset.QuoteAsset),
            _launchReward(false, 0, 0, StokerHook.PayoutAsset.QuoteAsset),
            _launchNativeTyped(StokerHook.LaunchType.Reward, 0, 0, StokerHook.PayoutAsset.QuoteAsset)
        ];
        for (uint256 k; k < 3; k++) {
            PoolKey memory key = keys_[k];
            address coin = address(_coinOfKey(key));
            Currency quoteAsset = _quoteOfKey(key);
            _taxThrough(key);
            (,, uint256 waitingQuote,) = taxVault.waiting(key);
            assertGt(waitingQuote, 0);

            uint256 before = _balance(quoteAsset, address(distributor));
            vm.prank(stranger);
            (Currency asset, uint256 amount) = taxVault.passHoldersPart(key);
            assertEq(Currency.unwrap(asset), Currency.unwrap(quoteAsset), "paid in the Quote Asset");
            assertEq(amount, waitingQuote, "the whole holders' part, as collected");
            assertEq(distributor.potOf(coin, asset), amount);
            assertEq(_balance(quoteAsset, address(distributor)) - before, amount);

            _payTwoHolders(coin, asset, amount);
        }
    }

    /// Trades the coin's pool both ways so its tax collects in the Tax Vault.
    function _taxThrough(PoolKey memory key) internal {
        _trade(key, trader, true, true, _native(key) ? 1 ether : 50 ether);
        _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
    }

    /// Posts a round of two holders for the coin's whole pot in `asset`, and a stranger pays it after the
    /// Round Delay.
    function _payTwoHolders(address coin, Currency asset, uint256 amount) internal {
        uint256 aliceBefore = _balance(asset, alice);
        uint256 bobBefore = _balance(asset, bob);
        (address[] memory h, uint256[] memory a) = _pair(alice, amount / 3, bob, amount - amount / 3);
        Built memory b = _post(coin, asset, h, a);
        _warpPastDelay(b.round);
        vm.prank(stranger);
        distributor.claim(_claims(b));
        assertEq(_balance(asset, alice) - aliceBefore, a[0]);
        assertEq(_balance(asset, bob) - bobBefore, a[1]);
        assertEq(distributor.potOf(coin, asset), 0);
    }
}
