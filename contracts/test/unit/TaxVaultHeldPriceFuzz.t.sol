// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// #271's fuzz: over random lifts, holding times, calls and their spacing, a wallet that starts and ends
/// with no coins never ends with more of the Quote Asset than it began with, beyond rounding dust. The
/// coins are busy (tax waits on every path) and their Reference Price stands at their price when the wallet
/// starts, which is the wallet's best case: a reference already below the price only places and caps less.
contract TaxVaultHeldPriceFuzzTest is TaxLocalBase {
    /// The longest hold the fuzz tries, in minutes. Past it the reference has followed a small lift far
    /// enough that a wallet nobody sells into can take pieces placed at its price: the README measures how
    /// long that takes and what it pays.
    uint256 internal constant MAX_HOLD_MINUTES = 120;
    /// What rounding can leave a wallet, in the Quote Asset's raw units.
    uint256 internal constant DUST = 1_000;

    address internal attacker = makeAddr("attacker");
    PoolKey[6] internal coins;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 6; i++) {
            bool native = i % 3 == 2;
            bool quoteIsCurrency0 = i % 3 != 0;
            bool stoke = i >= 3;
            (, PoolKey memory key) = _launchWith(
                _typedParams(
                    native ? address(0) : address(quote),
                    quoteIsCurrency0,
                    native ? 0.1 ether : 1 ether,
                    stoke ? StokerHook.LaunchType.Liquidity : StokerHook.LaunchType.Reward,
                    100,
                    stoke ? 0 : 2_500,
                    stoke ? 0 : 2_500,
                    stoke ? StokerHook.PayoutAsset.QuoteAsset : StokerHook.PayoutAsset.Coin
                )
            );
            uint256 tradeIn = taxVault.pieceCap(key) * 10_000 / PIECE_BPS * 60 / 25;
            for (uint256 j; j < 60; j++) {
                _trade(key, trader, true, true, tradeIn);
                _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
            }
            coins[i] = key;
        }
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    /// One wallet's whole attempt: buy `lift`, optionally lift again partway, call the vault every
    /// `every` minutes for `hold` minutes with the calls `mask` names, then sell every coin.
    function testFuzz_heldPrice_walletNeverGains(
        uint8 coinIndex,
        uint256 liftSeed,
        uint256 hold,
        uint8 every,
        uint8 mask,
        uint256 topUpSeed,
        uint256 topUpAt
    ) public {
        PoolKey memory key = coins[coinIndex % 6];
        uint256 depth = taxVault.pieceCap(key) * 10_000 / PIECE_BPS;
        // A lift from a thousandth of the pool's depth to twenty times it, spread over the orders of size.
        uint256 lift = _logUniform(liftSeed, depth / 1_000, depth * 20);
        uint256 topUp = topUpSeed % 2 == 0 ? 0 : _logUniform(topUpSeed, depth / 10_000, depth);
        hold = bound(hold, 0, MAX_HOLD_MINUTES);
        uint256 step = bound(every, 1, 10);
        topUpAt = bound(topUpAt, 0, hold);
        mask = uint8(bound(mask, 1, 7));

        if (_native(key)) vm.deal(attacker, 100_000 ether);
        else mockQuote.mint(attacker, 1_000_000 ether);
        uint256 before = _quoteBalanceOf(key, attacker);

        _trade(key, attacker, true, true, lift);
        for (uint256 m = 1; m <= hold; m++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            if (topUp > 0 && m == topUpAt) _trade(key, attacker, true, true, topUp);
            if (m % step != 0) continue;
            vm.startPrank(attacker);
            if (mask & 1 != 0) {
                try taxVault.addSupport(key) {} catch {}
            }
            if (mask & 2 != 0) {
                try taxVault.burn(key) {} catch {}
            }
            if (mask & 4 != 0) {
                try taxVault.buyForHolders(key) {} catch {}
            }
            vm.stopPrank();
        }
        _trade(key, attacker, false, true, _coinOfKey(key).balanceOf(attacker));
        assertEq(_coinOfKey(key).balanceOf(attacker), 0, "no coins left");
        assertLe(_quoteBalanceOf(key, attacker), before + DUST, "the wallet never gains");
    }

    /// A value spread evenly over the powers of two between `lo` and `hi`.
    function _logUniform(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256) {
        uint256 bits = 0;
        for (uint256 r = hi / lo; r > 1; r >>= 1) {
            bits++;
        }
        uint256 shift = seed % (bits + 1);
        uint256 base = lo << shift;
        uint256 span = base > hi ? 0 : (base < hi / 2 ? base : hi - base);
        return base + (span == 0 ? 0 : (seed >> 8) % span);
    }
}
