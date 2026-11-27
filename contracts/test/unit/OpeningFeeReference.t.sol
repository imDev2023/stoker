// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// A standard coin's Reference Price (#246 with #271): a standard coin has no tax, but its Opening Fee waits in
/// the Tax Vault as Support Liquidity, so it keeps a Reference Price from its first swap while the window runs,
/// and for good once an Opening Fee was booked; a standard coin whose window passed with nothing booked stops
/// following, and can never give the vault anything to spend at a lifted price.
contract OpeningFeeReferenceTest is TaxLocalBase, OpeningFeeHelpers {
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    function _openTick(PoolKey memory key) internal view returns (int24) {
        // The pool opens at the Listing's start price: the tick itself with the coin as currency0, its
        // inverse with the Quote Asset as currency0.
        int24 start = _native(key) ? NATIVE_START_TICK : START_TICK;
        return _quoteIsCurrency0(key) ? -start : start;
    }

    /// The coin is cheaper at `a` than at `b`, or as cheap.
    function _cheaperOrEqual(PoolKey memory key, int24 a, int24 b) internal view returns (bool) {
        return _quoteIsCurrency0(key) ? a >= b : a <= b;
    }

    /// The reference starts at the price the pool opened at with the pool's first swap, the First Buy, and
    /// lags a lifted price, in every kind of pool.
    function test_opening_aStandardCoinsReferenceStartsAtItsOpenPrice() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, kind == 2 ? 0.1 ether : 1 ether);
            // The First Buy lifted the price; the reference stood at the open price before it.
            assertTrue(_tickOf(key) != _openTick(key), "the First Buy moved the price");
            vm.warp(_launchedAt(key) + 5);
            _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
            int24 ref = hook.referenceTick(key.toId());
            assertTrue(_cheaperOrEqual(key, ref, _tickOf(key)), "the reference lags the lifted price");
            // Five seconds at most 2 ticks a minute: it has barely moved from the open price.
            int24 moved = ref > _openTick(key) ? ref - _openTick(key) : _openTick(key) - ref;
            assertLe(moved, 1, "the reference started at the open price");
            vm.revertToState(snap);
        }
    }

    /// After a snipe paid an Opening Fee, a wallet that lifts a standard coin's price and holds it while a
    /// Support Liquidity piece lands gets the piece under the Reference Price, never under its lifted price:
    /// #271's case, closed for a standard coin too.
    function test_opening_aLiftedStandardCoinGetsSupportUnderItsReference() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, 0);
            _tradeAndSee(key, true, true, _buyAmount(key, true), 0); // a snipe at the launch's own second
            vm.warp(_launchedAt(key) + OPENING_FEE_DURATION);
            // A large lift, held for a minute.
            _tradeAndSee(key, true, true, _buyAmount(key, true) * 5, 0);
            int24 lifted = _tickOf(key);
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            int24 ref = hook.referenceTick(key.toId());
            assertTrue(ref != lifted, "the reference has not caught the lift");
            (Support memory sup,) = _addSupport(key);
            // The piece lies on the cheaper side of the reference, below the lifted price.
            if (_quoteIsCurrency0(key)) assertGe(sup.lower, ref, "above the reference's tick (coin cheaper)");
            else assertLe(sup.upper, ref, "below the reference's tick");
            vm.revertToState(snap);
        }
    }

    /// A standard coin whose window passed with no Opening Fee booked keeps following all the same (#248).
    /// Until #248 it stopped, since the vault could never have anything of it to spend; now anyone may fund
    /// any coin's burn or Support Liquidity at any time, and a reference that had stopped would, when next
    /// read, be the price of that moment. So after the window, and after a quiet month in which a reference
    /// left alone would have had time to catch up with any price, a lift still leaves the reference where
    /// the price stood before it; and the vault holds nothing of the coin until someone funds it.
    function test_opening_aStandardCoinWithNoOpeningFeeKeepsFollowingToo() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, kind == 2 ? 0.1 ether : 1 ether);
            vm.warp(_launchedAt(key) + OPENING_FEE_DURATION + 30 days);
            for (uint256 i; i < 6; i++) {
                int24 stood = _tickOf(key);
                _tradeAndSee(key, true, i % 2 == 0, _buyAmount(key, i % 2 == 0), 0);
                assertTrue(_tickOf(key) != stood, "the buy lifted the price");
                assertEq(hook.referenceTick(key.toId()), stood, "the reference is the price that stood");
                vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
                assertTrue(hook.referenceTick(key.toId()) != _tickOf(key), "a minute on, it still lags the lift");
                vm.warp(vm.getBlockTimestamp() + 30 days);
            }
            assertEq(hook.openingFeeBooked(key.toId()), 0, "nothing booked");
            assertEq(_vaultClaims(key), 0, "the vault holds nothing of it");
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.addSupport(key);
            vm.revertToState(snap);
        }
    }

    /// A standard coin that took an Opening Fee keeps following after the window, as every pool does.
    function test_opening_aStandardCoinThatTookAnOpeningFeeKeepsFollowing() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, 0);
            vm.warp(_launchedAt(key) + 19);
            _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
            assertGt(hook.openingFeeBooked(key.toId()), 0, "it took an Opening Fee");
            vm.warp(_launchedAt(key) + 1 days);
            _tradeAndSee(key, true, true, _buyAmount(key, true) * 5, 0);
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
            assertTrue(hook.referenceTick(key.toId()) != _tickOf(key), "the reference lags a lift a day later");
            vm.revertToState(snap);
        }
    }

    // ---------------------------------------------------------------- what it costs a standard swap

    /// Each swap is its own transaction on a chain, so every account and slot it touches starts cold.
    function _coolAll(PoolKey memory key) internal {
        vm.cool(address(pm));
        vm.cool(address(hook));
        vm.cool(address(keys));
        vm.cool(address(taxVault));
        vm.cool(address(swapRouter));
        vm.cool(address(_coinOfKey(key)));
        if (!_native(key)) vm.cool(address(quote));
    }

    /// The gas of each of the four swap types a day after the launch, each in a new second, by the harness
    /// `TaxReferenceGas.t.sol` uses.
    function _gasOfFour(PoolKey memory key) internal returns (uint256[4] memory g) {
        bool native = _native(key);
        uint256 buyIn = native ? 0.01 ether : 1 ether;
        vm.warp(_launchedAt(key) + 1 days);
        _trade(key, trader, true, true, buyIn);
        _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
        if (!native) _approveRouter(key, trader);
        for (uint256 i; i < 4; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            bool buy = i < 2;
            bool exactIn = i % 2 == 0;
            uint256 amount = buy ? (exactIn ? buyIn : 1e9 ether) : (exactIn ? 1e9 ether : buyIn / 4);
            uint160 limit = buy == _quoteIsCurrency0(key) ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
            uint256 maxIn = trader.balance;
            _coolAll(key);
            if (native) _swapNativeApproved(key, trader, buy, exactIn, amount, maxIn, limit);
            else _swapApproved(key, trader, buy, exactIn, amount);
            g[i] = vm.lastCallGas().gasTotalUsed;
        }
    }

    /// The same standard coin with and without an Opening Fee taken. Until #248 the one that took none stopped
    /// following and paid nothing for a reference; since #248 every pool follows for life, so the two cost a
    /// swap in a new second the same, well inside the bound that following once added.
    function test_opening_gas_followingAStandardCoinsReference() public {
        uint256 worst;
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory plain = _launchOpen(kind, 0, kind == 2 ? 0.1 ether : 1 ether);
            uint256[4] memory without = _gasOfFour(plain);
            vm.revertToState(snap);
            PoolKey memory sniped = _launchOpen(kind, 0, kind == 2 ? 0.1 ether : 1 ether);
            _trade(sniped, trader, true, true, _native(sniped) ? 0.01 ether : 1 ether);
            assertGt(hook.openingFeeBooked(sniped.toId()), 0, "took an Opening Fee");
            uint256[4] memory with = _gasOfFour(sniped);
            vm.revertToState(snap);
            emit log_named_uint("kind", kind);
            for (uint256 i; i < 4; i++) {
                // forge-lint: disable-next-line(unsafe-typecast)
                int256 delta = int256(with[i]) - int256(without[i]);
                emit log_named_uint("  gas, none taken", without[i]);
                emit log_named_int("  following, more by", delta);
                if (delta > 0 && uint256(delta) > worst) worst = uint256(delta);
            }
        }
        assertLe(worst, FOLLOWING_BOUND, "following a standard coin's reference is bounded");
    }

    /// Measured on 2026-11-24: see the README; the bound is the taxed swap's (#271).
    uint256 internal constant FOLLOWING_BOUND = 8_500;
}
