// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// The Graduation Hold and the Creator Lock on the taxed Launch types of #245 (#244): a Reward Launch and a
/// Stoke Launch, with the coin as currency0, as currency1 and paired with the native asset. A taxed swap
/// moves the hold exactly as the price it leaves says, as any swap does; the Tax Vault's own buy (the Reward
/// Burn's piece) is a swap like any other to the hold; and its Support Liquidity, added below the price,
/// moves neither the price nor the hold, and records no Graduation, as no swap would. Every top-level call is
/// a transaction.
/// forge-config: default.isolate = true
abstract contract GraduationTaxedCases is TaxLocalBase {
    using StateLibrary for IPoolManager;

    PoolKey internal key;
    PoolId internal id;
    address internal coin;
    /// More coins than any buy here reaches before its price limit stops it (95% of the seed is 400x).
    uint256 internal constant ALL_THE_COINS = 9.5e11 ether;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1_800_000_000);
        mockQuote.mint(stranger, 1_000_000 ether);
        vm.deal(stranger, 1_000 ether);
        (coin, key) = _launchWith(_caseParams(0, 0, 0));
        id = key.toId();
        _approveAll(trader);
        _approveAll(stranger);
    }

    // ------------------------------------------------ what each case fills in

    function _launchType() internal pure virtual returns (StokerHook.LaunchType);
    /// The ERC-20's side of the pool, ignored for the native asset.
    function _quoteIs0() internal pure virtual returns (bool);
    function _isNative() internal pure virtual returns (bool);

    function _caseParams(uint16 lockBps, uint32 cliff, uint32 unlock)
        internal
        returns (StokerFactory.LaunchParams memory p)
    {
        bool reward = _launchType() == StokerHook.LaunchType.Reward;
        p = _typedParams(
            _isNative() ? address(0) : address(quote),
            _isNative() || _quoteIs0(),
            0,
            _launchType(),
            TAX_BPS,
            reward ? 2_500 : 0,
            reward ? 2_500 : 0,
            StokerHook.PayoutAsset.QuoteAsset
        );
        p.creatorLockBps = lockBps;
        p.creatorLockCliff = cliff;
        p.creatorLockUnlock = unlock;
    }

    /// The Quote Asset of one round trip below the target, and one buy across it from the start.
    function _unit() internal pure returns (uint256) {
        return _isNative() ? 0.1 ether : 1 ether;
    }

    function _crossingBuy() internal pure returns (uint256) {
        return _isNative() ? 7 ether : 100 ether;
    }

    // ------------------------------------------------ the coin's price against the target

    function _coinIs0() internal view returns (bool) {
        return !hook.termsOf(id).quoteIsCurrency0;
    }

    function _target() internal view returns (uint160) {
        return hook.termsOf(id).graduationSqrtPriceX96;
    }

    function _price() internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(id);
    }

    function _cheaper(uint160 p, uint160 by) internal view returns (uint160) {
        return _coinIs0() ? p - by : p + by;
    }

    function _above() internal view returns (uint160) {
        uint160 t = _target();
        return _coinIs0() ? t + t / 100 : t - t / 100;
    }

    function _atOrAbove() internal view returns (bool) {
        return _coinIs0() ? _price() >= _target() : _price() <= _target();
    }

    function _dearerThan(uint160 a, uint160 b) internal view returns (bool) {
        return _coinIs0() ? a > b : a < b;
    }

    /// The hold as the price stands now: what the next transaction or `graduate` would judge.
    function _hold() internal view returns (uint256) {
        return hook.graduationNow(id).holdSince;
    }

    function _graduatedAt() internal view returns (uint256) {
        return hook.graduationOf(id).graduatedAt;
    }

    // ------------------------------------------------ trading, one external call each

    function _approveAll(address who) internal {
        vm.startPrank(who);
        IERC20(coin).approve(address(swapRouter), type(uint256).max);
        if (!_isNative()) quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _swapTo(address who, bool buy, bool exactIn, uint256 amount, uint160 limit) internal {
        if (_isNative()) _swapNativeWithData(key, who, buy, exactIn, amount, who.balance, limit, "");
        else _swapWithData(key, who, buy, exactIn, amount, limit, "");
    }

    function _noLimit(bool buy) internal view returns (uint160) {
        bool zeroForOne = buy == !_coinIs0();
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _buyTo(address who, uint160 limit) internal {
        _swapTo(who, true, false, ALL_THE_COINS, limit);
    }

    function _sellTo(address who, uint160 limit) internal {
        _swapTo(who, false, true, IERC20(coin).balanceOf(who), limit);
    }

    function _dustBuy(address who) internal {
        _swapTo(who, true, true, _unit() / 1_000, _noLimit(true));
    }

    /// Trading below the target, so the Tax Vault has tax to spend: buys and sells that never cross.
    function _volume() internal {
        for (uint256 i; i < 6; i++) {
            _swapTo(stranger, true, true, 50 * _unit(), _noLimit(true));
            _swapTo(stranger, false, true, IERC20(coin).balanceOf(stranger), _noLimit(false));
        }
        assertEq(_hold(), 0, "the volume stayed under the target");
    }

    /// After a swap at `at`: the hold is what the price it left says, given the hold `before` it.
    function _assertHoldAsThePriceSays(uint256 before, uint256 at) internal view {
        uint256 expected = _atOrAbove() ? (before == 0 ? at : before) : 0;
        assertEq(_hold(), expected, "the hold, as the price the swap left says");
    }

    // ------------------------------------------------ taxed swaps

    function test_taxed_swapsMoveTheHoldAsTheirPriceSays() public {
        uint256 t0 = vm.getBlockTimestamp();
        uint256 booked = _taxBooked(key);

        _buyTo(trader, _cheaper(_target(), 1));
        assertGt(_taxBooked(key), booked, "a taxed swap");
        _assertHoldAsThePriceSays(0, t0);

        booked = _taxBooked(key);
        _buyTo(trader, _above());
        assertGt(_taxBooked(key), booked, "a taxed swap");
        _assertHoldAsThePriceSays(0, t0);
        assertEq(_hold(), t0, "started by the taxed buy across");

        vm.warp(t0 + 20 minutes);
        _dustBuy(trader);
        _assertHoldAsThePriceSays(t0, t0 + 20 minutes);

        vm.warp(t0 + 30 minutes);
        _sellTo(trader, _cheaper(_target(), 1));
        _assertHoldAsThePriceSays(t0, t0 + 30 minutes);
        assertEq(_hold(), 0, "cleared by the taxed sell under");

        vm.warp(t0 + 40 minutes);
        _buyTo(trader, _above());
        assertEq(_hold(), t0 + 40 minutes, "started again");
        vm.warp(t0 + 40 minutes + 1 hours);
        booked = _taxBooked(key);
        _dustBuy(trader);
        assertGt(_taxBooked(key), booked, "a taxed swap");
        assertEq(_graduatedAt(), t0 + 40 minutes + 1 hours, "recorded by a taxed swap at the hour");
    }

    // ------------------------------------------------ the Tax Vault's own buy

    function test_taxVaultsBuy_movesTheHoldAsAnySwap() public {
        if (_launchType() != StokerHook.LaunchType.Reward) {
            // A Stoke Launch has no Reward Burn: its vault never buys, and its whole tax is Support Liquidity.
            vm.expectRevert(TaxVault.NothingToSpend.selector);
            taxVault.burn(key);
            return;
        }
        _volume();
        _buyTo(trader, _cheaper(_target(), 1));
        // The vault buys only at a price that has stood (#271's Reference Price, rising 2 ticks a minute).
        _letThePriceStand();
        uint256 t0 = vm.getBlockTimestamp();
        uint160 before = _price();

        vm.prank(stranger);
        taxVault.burn(key);
        assertTrue(_dearerThan(_price(), before), "the vault's buy moved the price");
        _assertHoldAsThePriceSays(0, t0);
        assertEq(_hold(), t0, "the vault's buy across the target started the hold, as any buy would");

        vm.warp(t0 + 59 minutes);
        assertEq(hook.graduationNow(id).graduatedAt, 0, "59 minutes");

        // Long enough for the reference to follow the vault's lift, so it buys again; the hold ran through.
        vm.warp(t0 + 2 days);
        vm.prank(stranger);
        taxVault.burn(key);
        assertEq(_graduatedAt(), t0 + 1 hours, "the vault's swap records it, at the hour's end, as any swap would");
    }

    // ------------------------------------------------ Support Liquidity

    function test_supportLiquidity_leavesTheHoldAsNoSwapWould() public {
        _volume();
        _buyTo(trader, _cheaper(_target(), 1));
        uint160 before = _price();
        (, uint256 added) = _addSupport(key);
        assertGt(added, 0, "a piece was added");
        assertEq(_price(), before, "the price did not move");
        assertEq(_hold(), 0, "a wei under the target, and no swap: no hold");

        _buyTo(trader, _target());
        uint256 t0 = vm.getBlockTimestamp();
        assertEq(_hold(), t0, "a buy to the target starts the hold");

        vm.warp(t0 + 30 minutes);
        before = _price();
        _addSupport(key);
        assertEq(_price(), before, "the price did not move");
        assertEq(_hold(), t0, "Support Liquidity leaves a running hold");

        vm.warp(t0 + 2 hours);
        _addSupport(key);
        assertEq(_graduatedAt(), 0, "no swap, so nothing recorded Graduation");
        assertEq(_hold(), t0);
        vm.prank(stranger);
        hook.graduate(id);
        assertEq(_graduatedAt(), t0 + 1 hours, "the hold that ran through the additions graduates the coin");
    }

    // ------------------------------------------------ the Creator Lock on a taxed Launch

    function test_creatorLock_onATaxedLaunch_seedsFourFifthsAndPaysTheScheduleUntaxed() public {
        (address lockedCoin, PoolKey memory k) = _launchWith(_caseParams(2_000, 7 days, 0));
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(k.toId()));
        IERC20 c = IERC20(lockedCoin);
        assertEq(c.balanceOf(address(lock)), SUPPLY / 5, "a fifth in the lock");
        assertLe(c.balanceOf(address(pm)), SUPPLY * 4 / 5, "four fifths seeded");
        assertEq(c.balanceOf(address(pm)) + SUPPLY / 5, c.totalSupply(), "every coin accounted");
        assertEq(uint8(hook.termsOf(k.toId()).launchType), uint8(_launchType()), "the taxed type stands");

        _trade(k, trader, true, true, _crossingBuy());
        uint256 holdSince = hook.graduationNow(k.toId()).holdSince;
        assertGt(holdSince, 0, "a taxed buy across the target started the hold");
        vm.warp(holdSince + 1 hours);
        hook.graduate(k.toId());

        vm.warp(holdSince + 1 hours + 7 days);
        uint256 booked = _taxBooked(k);
        vm.prank(creator);
        assertEq(lock.claim(), SUPPLY / 5);
        assertEq(c.balanceOf(creator), SUPPLY / 5, "the whole lock, with no tax: the coin is plain");
        assertEq(_taxBooked(k), booked, "a claim is no swap and books no tax");
    }
}

contract GraduationRewardCoinIsCurrency0Test is GraduationTaxedCases {
    function _launchType() internal pure override returns (StokerHook.LaunchType) {
        return StokerHook.LaunchType.Reward;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return false;
    }

    function _isNative() internal pure override returns (bool) {
        return false;
    }
}

contract GraduationRewardQuoteIsCurrency0Test is GraduationTaxedCases {
    function _launchType() internal pure override returns (StokerHook.LaunchType) {
        return StokerHook.LaunchType.Reward;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }

    function _isNative() internal pure override returns (bool) {
        return false;
    }
}

contract GraduationRewardNativeTest is GraduationTaxedCases {
    function _launchType() internal pure override returns (StokerHook.LaunchType) {
        return StokerHook.LaunchType.Reward;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }

    function _isNative() internal pure override returns (bool) {
        return true;
    }
}

contract GraduationStokeCoinIsCurrency0Test is GraduationTaxedCases {
    function _launchType() internal pure override returns (StokerHook.LaunchType) {
        return StokerHook.LaunchType.Liquidity;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return false;
    }

    function _isNative() internal pure override returns (bool) {
        return false;
    }
}

contract GraduationStokeQuoteIsCurrency0Test is GraduationTaxedCases {
    function _launchType() internal pure override returns (StokerHook.LaunchType) {
        return StokerHook.LaunchType.Liquidity;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }

    function _isNative() internal pure override returns (bool) {
        return false;
    }
}

contract GraduationStokeNativeTest is GraduationTaxedCases {
    function _launchType() internal pure override returns (StokerHook.LaunchType) {
        return StokerHook.LaunchType.Liquidity;
    }

    function _quoteIs0() internal pure override returns (bool) {
        return true;
    }

    function _isNative() internal pure override returns (bool) {
        return true;
    }
}
