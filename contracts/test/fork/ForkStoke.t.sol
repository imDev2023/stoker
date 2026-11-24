// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkTaxBase} from "./ForkTaxBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// #245's third and fifth fork criteria: the public call turns a Reward Launch's liquidity share into
/// Support Liquidity before Graduation, with no coin bought and the pool's price unmoved by the call; and a
/// Stoke Launch's whole tax becomes Support Liquidity, with no holders' part. With the coin as currency0, as
/// currency1, and paired with native ETH.
contract ForkStokeTest is ForkTaxBase {
    /// The Graduation Target is 20 times the start price (ADR 0024): 29,959 ticks above it, as a tick of
    /// the coin's price in the Quote Asset.
    int24 internal constant TARGET_TICKS = 29_959;

    function _coinPriceTick(PoolKey memory key) internal view returns (int24) {
        int24 tick = _tickOf(key);
        return _quoteIsCurrency0(key) ? -tick : tick;
    }

    function _startTick(PoolKey memory key) internal pure returns (int24) {
        return _native(key) ? NATIVE_START_TICK : START_TICK;
    }

    function _kind(uint256 kind, StokerHook.LaunchType t) internal returns (PoolKey memory) {
        uint16 liq = t == StokerHook.LaunchType.Reward ? 5_000 : 0;
        if (kind == 2) return _launchNativeTyped(t, 0, liq, StokerHook.PayoutAsset.QuoteAsset);
        if (t == StokerHook.LaunchType.Reward) {
            return _launchReward(kind == 1, 0, liq, StokerHook.PayoutAsset.QuoteAsset);
        }
        return _launchStoke(kind == 1, TAX_BPS);
    }

    function test_fork_rewardLiquidity_becomesSupportBeforeGraduation_everyOrder() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _kind(kind, StokerHook.LaunchType.Reward);
            uint256 u = _native(key) ? 0.05 ether : 1 ether;
            _trade(key, trader, true, true, 20 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
            assertLt(_coinPriceTick(key), _startTick(key) + TARGET_TICKS, "the coin has not reached its target");

            IERC20 coin = _coinOfKey(key);
            uint160 price = _sqrtPrice(key);
            uint256 supply = coin.totalSupply();
            uint256 claims = _vaultClaims(key);
            (Support memory s, uint256 added) = _addSupport(key);
            assertGt(added, 0, "Support Liquidity added before Graduation");
            assertEq(_sqrtPrice(key), price, "the call did not move the price");
            assertEq(coin.totalSupply(), supply);
            assertEq(coin.balanceOf(address(taxVault)), 0, "no coin bought");
            assertEq(claims - _vaultClaims(key), added);
            (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, s);
            assertEq(coinsHeld, 0, "Quote Asset alone");
            assertApproxEqAbs(quoteHeld, added, 1);
            assertEq(taxVault.booksOf(key.toId()).supportSpent, added);
            (, uint256 supportLeft, uint256 holdersPart_,) = taxVault.waiting(key);
            assertEq(added + supportLeft, _taxBooked(key) * 5_000 / 10_000, "from the liquidity share alone");
            assertEq(holdersPart_, _taxBooked(key) * 5_000 / 10_000, "the holders' part untouched");
        }
    }

    function test_fork_stokeLaunch_wholeTaxBecomesSupport_noHoldersPart_everyOrder() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _kind(kind, StokerHook.LaunchType.Liquidity);
            uint256 u = _native(key) ? 0.05 ether : 1 ether;
            _trade(key, trader, true, true, 20 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
            uint256 booked = _taxBooked(key);
            (uint256 burnPart, uint256 supportPart, uint256 holdersPart_,) = taxVault.waiting(key);
            assertEq(supportPart, booked, "the whole tax waits for liquidity");
            assertEq(burnPart, 0, "no burn share");
            assertEq(holdersPart_, 0, "no holders' part");

            uint256 total;
            uint256 n;
            for (; n < 100; n++) {
                (, supportPart,,) = taxVault.waiting(key);
                if (supportPart < 1e9) break;
                uint160 price = _sqrtPrice(key);
                (, uint256 added) = _addSupport(key);
                assertEq(_sqrtPrice(key), price, "no piece moved the price");
                total += added;
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            }
            (, supportPart,,) = taxVault.waiting(key);
            assertEq(total + supportPart, booked, "the whole tax became Support Liquidity");
            assertEq(_vaultClaims(key), supportPart, "nothing else kept");
            assertEq(_coinOfKey(key).balanceOf(address(taxVault)), 0, "no coin bought");
            vm.prank(stranger);
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.passHoldersPart(key);
            emit log_named_uint("pieces", n);
        }
    }
}
