// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {StokerTestBase} from "./StokerTestBase.sol";

/// @notice What the tax tests share, locally and on the fork (#245): launching each type, reading the Tax
///         Vault's books and its Support Liquidity from outside, and the tax's own arithmetic.
abstract contract TaxHelpers is StokerTestBase {
    using StateLibrary for IPoolManager;

    uint16 internal constant TAX_BPS = 300; // a Reward Tax of 3%

    uint256 internal _typedLaunches;

    /// A Support Liquidity position the Tax Vault reported adding.
    struct Support {
        int24 lower;
        int24 upper;
        uint128 liquidity;
    }

    // ---------------------------------------------------------------- launching each type

    function _typedParams(
        address quoteAsset,
        bool quoteIsCurrency0,
        uint256 firstBuy,
        StokerHook.LaunchType launchType,
        uint16 taxBps,
        uint16 burnShareBps,
        uint16 liquidityShareBps,
        StokerHook.PayoutAsset payoutAsset
    ) internal returns (StokerFactory.LaunchParams memory p) {
        p.name = "Tax Coin";
        p.symbol = string(abi.encodePacked("TAX", vm.toString(++_typedLaunches)));
        p.quote = quoteAsset;
        p.salt = quoteAsset == address(0)
            ? bytes32(1_000 + _typedLaunches)
            : _saltFor(quoteIsCurrency0, creator, p.name, p.symbol);
        p.creatorDestination = address(0);
        p.firstBuy = firstBuy;
        p.launchType = launchType;
        p.taxBps = taxBps;
        p.burnShareBps = burnShareBps;
        p.liquidityShareBps = liquidityShareBps;
        p.payoutAsset = payoutAsset;
    }

    /// Launches from `p` as the Creator: an ERC-20 First Buy from an allowance, a native one as value.
    function _launchWith(StokerFactory.LaunchParams memory p) internal returns (address coin, PoolKey memory key) {
        vm.startPrank(creator);
        if (p.quote != address(0)) quote.approve(address(factory), p.firstBuy);
        (coin,) = factory.launch{value: p.quote == address(0) ? p.firstBuy : 0}(p);
        vm.stopPrank();
        key = p.quote == address(0) ? _nativeKey(coin) : _keyFor(coin);
    }

    function _launchReward(
        bool quoteIsCurrency0,
        uint16 burnShareBps,
        uint16 liquidityShareBps,
        StokerHook.PayoutAsset payoutAsset
    ) internal returns (PoolKey memory key) {
        (, key) = _launchWith(
            _typedParams(
                address(quote),
                quoteIsCurrency0,
                1 ether,
                StokerHook.LaunchType.Reward,
                TAX_BPS,
                burnShareBps,
                liquidityShareBps,
                payoutAsset
            )
        );
    }

    function _launchStoke(bool quoteIsCurrency0, uint16 taxBps) internal returns (PoolKey memory key) {
        (, key) = _launchWith(
            _typedParams(
                address(quote),
                quoteIsCurrency0,
                1 ether,
                StokerHook.LaunchType.Liquidity,
                taxBps,
                0,
                0,
                StokerHook.PayoutAsset.QuoteAsset
            )
        );
    }

    function _launchNativeTyped(
        StokerHook.LaunchType launchType,
        uint16 burnShareBps,
        uint16 liquidityShareBps,
        StokerHook.PayoutAsset payoutAsset
    ) internal returns (PoolKey memory key) {
        (, key) = _launchWith(
            _typedParams(address(0), true, 0.1 ether, launchType, TAX_BPS, burnShareBps, liquidityShareBps, payoutAsset)
        );
    }

    // ---------------------------------------------------------------- reading from outside

    function _native(PoolKey memory key) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(0);
    }

    /// The pool's Quote Asset, whatever it is paired with.
    function _quoteOfKey(PoolKey memory key) internal view returns (Currency) {
        return _native(key) || _isQuote0(key) ? key.currency0 : key.currency1;
    }

    function _coinOfKey(PoolKey memory key) internal view returns (IERC20) {
        return IERC20(Currency.unwrap(_native(key) || _isQuote0(key) ? key.currency1 : key.currency0));
    }

    function _quoteIsCurrency0(PoolKey memory key) internal view returns (bool) {
        return _native(key) || _isQuote0(key);
    }

    /// The Tax Vault's ERC-6909 claims on the pool's Quote Asset: what backs the tax waiting in it.
    function _vaultClaims(PoolKey memory key) internal view returns (uint256) {
        return pm.balanceOf(address(taxVault), _quoteOfKey(key).toId());
    }

    function _taxBooked(PoolKey memory key) internal view returns (uint256) {
        return hook.taxBooked(key.toId());
    }

    function _sqrtPrice(PoolKey memory key) internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = pm.getSlot0(key.toId());
    }

    function _tickOf(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = pm.getSlot0(key.toId());
    }

    function _supportLiquidity(PoolKey memory key, Support memory s) internal view returns (uint128) {
        return pm.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(taxVault), s.lower, s.upper, bytes32(0))
        );
    }

    /// What a Support Liquidity position holds at the pool's price now: Quote Asset and coins.
    function _supportHoldings(PoolKey memory key, Support memory s)
        internal
        view
        returns (uint256 quoteHeld, uint256 coinsHeld)
    {
        uint160 sqrtP = _sqrtPrice(key);
        uint160 sqrtL = TickMath.getSqrtPriceAtTick(s.lower);
        uint160 sqrtU = TickMath.getSqrtPriceAtTick(s.upper);
        uint128 liquidity = _supportLiquidity(key, s);
        uint256 a0;
        uint256 a1;
        if (sqrtP <= sqrtL) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtL, sqrtU, liquidity, false);
        } else if (sqrtP < sqrtU) {
            a0 = SqrtPriceMath.getAmount0Delta(sqrtP, sqrtU, liquidity, false);
            a1 = SqrtPriceMath.getAmount1Delta(sqrtL, sqrtP, liquidity, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(sqrtL, sqrtU, liquidity, false);
        }
        return _quoteIsCurrency0(key) ? (a0, a1) : (a1, a0);
    }

    /// Adds one Support Liquidity piece as a stranger would and returns the position it made.
    function _addSupport(PoolKey memory key) internal returns (Support memory s, uint256 added) {
        vm.recordLogs();
        vm.prank(stranger);
        (added, s.liquidity) = taxVault.addSupport(key);
        // The range is read back from the event the vault emitted.
        bytes32 sig = TaxVault.SupportAdded.selector;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(taxVault) && logs[i].topics[0] == sig) {
                (s.lower, s.upper,,) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
            }
        }
    }

    // ---------------------------------------------------------------- the tax's arithmetic

    /// A rate of a known gross amount, rounded up (the fee and the tax alike).
    function _rateOfGross(uint256 gross, uint256 bps) internal pure returns (uint256) {
        return (gross * bps + 9_999) / 10_000;
    }

    /// A rate of a gross amount known only as its net, when `totalBps` is taken from it in all.
    function _rateOfNet(uint256 net, uint256 bps, uint256 totalBps) internal pure returns (uint256) {
        return (net * bps + (10_000 - totalBps) - 1) / (10_000 - totalBps);
    }
}

