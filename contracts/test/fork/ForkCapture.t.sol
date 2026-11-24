// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkTaxBase} from "./ForkTaxBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// The spike review's capture test (spike/evm-robinhood-fork, test/Review.t.sol), kept as a regression test
/// that must now find nothing to take (#245's seventh criterion). There a Stoke Launch's tax waited for
/// Graduation and a wallet that crossed the target and left in one transaction took 58% to 70% of it. Here
/// the tax waits in the Tax Vault, where no swap reaches it, and Support Liquidity sits below the price: the
/// same wallet crossing the Graduation Target (20 times the start price) and leaving in one transaction
/// loses every fee and tax it paid, and the tax that waited and the Support Liquidity are exactly as they
/// were but for its own tax. With the coin as currency0, as currency1, and paired with native ETH.
contract ForkCaptureTest is ForkTaxBase {
    using StateLibrary for IPoolManager;

    int24 internal constant TARGET_TICKS = 29_959; // 20 times the start price

    function test_fork_capture_crossingTheTargetTakesNothing_coinIsCurrency0() public {
        _measure(_launchStoke(false, 500), [uint256(125 ether), 250 ether, 500 ether, 1_000 ether]);
    }

    function test_fork_capture_crossingTheTargetTakesNothing_coinIsCurrency1() public {
        _measure(_launchStoke(true, 500), [uint256(125 ether), 250 ether, 500 ether, 1_000 ether]);
    }

    function test_fork_capture_crossingTheTargetTakesNothing_native() public {
        PoolKey memory key =
            _launchNativeTyped(StokerHook.LaunchType.Liquidity, 0, 0, StokerHook.PayoutAsset.QuoteAsset);
        _measure(key, [uint256(8 ether), 16 ether, 32 ether, 64 ether]);
    }

    function _measure(PoolKey memory key, uint256[4] memory sizes) internal {
        // Twelve rounds of trading with 5% Stoke Tax, a Support Liquidity piece after each.
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        Support[] memory pieces = new Support[](12);
        for (uint256 i; i < 12; i++) {
            _trade(key, trader, true, true, 40 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader));
            (pieces[i],) = _addSupport(key);
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
        }
        (, uint256 waiting,,) = taxVault.waiting(key);
        assertGt(waiting, 0, "tax waits in the vault");
        emit log_named_decimal_uint("Stoke Tax waiting in the Tax Vault", waiting, 18);

        for (uint256 s; s < sizes.length; s++) {
            uint256 snap = vm.snapshotState();
            _crossOnce(key, sizes[s], pieces, waiting);
            vm.revertToState(snap);
        }
    }

    function _crossOnce(PoolKey memory key, uint256 size, Support[] memory pieces, uint256 waiting) internal {
        CrossAndLeave attacker = new CrossAndLeave();
        uint256 funds = size * 2;
        if (_native(key)) vm.deal(address(attacker), funds);
        else deal(address(quote), address(attacker), funds);

        uint256 fee0 = _hookClaimsOf(key);
        uint256 tax0 = _taxBooked(key);
        attacker.run(pm, swapRouter, key, _quoteIsCurrency0(key), size);
        uint256 left = _native(key) ? address(attacker).balance : quote.balanceOf(address(attacker));
        uint256 ownTax = _taxBooked(key) - tax0;
        uint256 paid = (_hookClaimsOf(key) - fee0) + ownTax;

        int24 peak = _quoteIsCurrency0(key) ? -attacker.peakTick() : attacker.peakTick();
        assertGe(peak, (_native(key) ? NATIVE_START_TICK : START_TICK) + TARGET_TICKS, "the buy crossed the target");
        assertLt(left, funds, "the round trip lost money");
        assertGe(funds - left, paid, "it lost at least every fee and tax it paid: nothing waiting reached it");
        (, uint256 waitingAfter,,) = taxVault.waiting(key);
        assertEq(waitingAfter, waiting + ownTax, "the waiting tax grew by its own tax alone");
        for (uint256 i; i < pieces.length; i++) {
            assertEq(_supportLiquidity(key, pieces[i]) >= pieces[i].liquidity, true, "Support Liquidity stayed");
        }
        emit log_named_decimal_uint("  cross with a buy of", size, 18);
        emit log_named_decimal_int("  round-trip result", int256(left) - int256(funds), 18);
    }
}

/// Crosses the target with one buy and sells every coin back, in one transaction, recording the pool's tick
/// between the two.
contract CrossAndLeave {
    using StateLibrary for IPoolManager;

    int24 public peakTick;

    function run(IPoolManager pm, PoolSwapTest router, PoolKey calldata key, bool quoteIsCurrency0, uint256 buy)
        external
    {
        bool native = Currency.unwrap(key.currency0) == address(0);
        IERC20 coin = IERC20(Currency.unwrap(quoteIsCurrency0 ? key.currency1 : key.currency0));
        if (!native) {
            IERC20(Currency.unwrap(quoteIsCurrency0 ? key.currency0 : key.currency1)).approve(address(router), buy);
        }
        coin.approve(address(router), type(uint256).max);
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        router.swap{value: native ? buy : 0}(key, _params(quoteIsCurrency0, buy), settings, "");
        (, peakTick,,) = pm.getSlot0(key.toId());
        router.swap(key, _params(!quoteIsCurrency0, coin.balanceOf(address(this))), settings, "");
    }

    function _params(bool zeroForOne, uint256 amount) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
    }

    receive() external payable {}
}
