// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";
import {StokerCoin} from "../src/StokerCoin.sol";

/// @notice #234 point 4: a Reward Tax taken by the hook, a share bought back and burned, a share
///         added to the pool as locked liquidity, in the swap or by a call anyone can make.
contract RewardTaxTest is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _rewardLaunch(bool quoteIsCurrency0, uint16 burnBps, uint16 liquidityBps)
        internal
        returns (PoolKey memory key)
    {
        StokerFactory.LaunchParams memory p = _params(quoteIsCurrency0);
        p.taxBps = 300; // a 3% Reward Tax
        p.burnShareBps = burnBps;
        p.liquidityShareBps = liquidityBps;
        (, key) = _launch(p);
    }

    function _state(PoolKey memory key) internal view returns (StokerHook.State memory) {
        return hook.state(key.toId());
    }

    function _hookClaims(Currency c) internal view returns (uint256) {
        return POOL_MANAGER.balanceOf(address(hook), c.toId());
    }

    function _hookPosition(PoolKey memory key) internal view returns (uint128) {
        return POOL_MANAGER.getPositionLiquidity(
            key.toId(),
            Position.calculatePositionKey(
                address(hook), TickMath.minUsableTick(200), TickMath.maxUsableTick(200), bytes32(0)
            )
        );
    }

    /// The tax is taken on top of the Platform Fee: 4% of the gross NVDA, 1% paid out as before
    /// and 3% held by the hook as ERC-6909 claims, split a quarter burn, a quarter liquidity, half
    /// the holders'. The burn share crosses the flush threshold, so the same swap buys the coin
    /// back and burns it: the coin's total supply falls inside the trade.
    function test_rewardTax_burnInTheSwap() public {
        PoolKey memory key = _rewardLaunch(true, 2_500, 2_500);
        StokerCoin coin = StokerCoin(address(_coin(key)));
        uint256 supplyBefore = coin.totalSupply();
        uint256 platformBefore = NVDA.balanceOf(platform);

        _swap(key, trader, true, true, 10 ether, "");

        StokerHook.State memory s = _state(key);
        assertEq(NVDA.balanceOf(platform) - platformBefore, 0.05 ether, "platform half of the 1%");
        assertEq(s.holderPot, 0.15 ether, "half of the 0.3 NVDA tax");
        assertEq(s.pendingLiquidityQuote, 0.075 ether, "a quarter waits for Graduation");
        assertEq(s.pendingBurnQuote, 0, "the burn quarter was spent in the swap");
        assertGt(s.burnedCoins, 0);
        assertEq(supplyBefore - coin.totalSupply(), s.burnedCoins, "supply fell by the coins burned");
        assertEq(s.lockedLiquidity, 0, "no Reward Liquidity before Graduation");
        // The hook's claims cover exactly what it still holds for the holders and the liquidity.
        assertEq(_hookClaims(Currency.wrap(address(NVDA))), s.holderPot + s.pendingLiquidityQuote);
        emit log_named_uint("coins burned by a 0.075 NVDA burn share", s.burnedCoins);
    }

    /// Below the threshold the burn waits, and anyone may flush it later.
    function test_rewardTax_flushByAnyone() public {
        PoolKey memory key = _rewardLaunch(false, 2_500, 2_500);
        _swap(key, trader, true, true, 0.1 ether, "");
        StokerHook.State memory s = _state(key);
        assertEq(s.pendingBurnQuote, 0.00075 ether, "under the 0.01 NVDA threshold");
        assertEq(s.burnedCoins, 0);

        vm.prank(makeAddr("stranger"));
        hook.flush(key);
        s = _state(key);
        assertEq(s.pendingBurnQuote, 0);
        assertGt(s.burnedCoins, 0, "burned by a stranger's call");
    }

    /// A caller-supplied key that names another hook is refused.
    function test_rewardTax_flushRefusesForeignKey() public {
        PoolKey memory key = _rewardLaunch(true, 2_500, 2_500);
        key.hooks = StokerHook(makeAddr("otherHook"));
        vm.expectRevert(StokerHook.BadPool.selector);
        hook.flush(key);
    }

    /// After Graduation the liquidity share, including what waited, is added to the pool as a
    /// full-range position owned by the hook, which has no code that removes it.
    function test_rewardTax_liquidityAfterGraduation() public {
        PoolKey memory key = _rewardLaunch(true, 2_500, 2_500);
        _swap(key, trader, true, true, 40 ether, "");
        assertFalse(_state(key).graduated);
        uint256 waiting = _state(key).pendingLiquidityQuote;
        assertGt(waiting, 0);

        _swap(key, trader, true, true, 100 ether, "");
        StokerHook.State memory s = _state(key);
        assertTrue(s.graduated, "graduated");
        assertGt(s.lockedLiquidity, 0, "Reward Liquidity added");
        assertEq(_hookPosition(key), s.lockedLiquidity, "the hook's full-range position");
        // What is left over waits as claims, never more than rounding dust of the quote side.
        assertLt(s.pendingLiquidityQuote, 0.01 ether);
        assertEq(
            _hookClaims(Currency.wrap(address(NVDA))),
            uint256(s.holderPot) + s.pendingLiquidityQuote + s.pendingBurnQuote,
            "claims match the books"
        );

        // A later sell does not reduce it, and nobody can remove it.
        uint128 locked = s.lockedLiquidity;
        _swap(key, trader, false, true, _coin(key).balanceOf(trader) / 2, "");
        assertGe(_hookPosition(key), locked);
        emit log_named_uint("Reward Liquidity added at Graduation (L)", locked);
    }

    /// A Stoke Launch: the whole tax goes to the pool as locked liquidity; no holder pot, no burn.
    function test_stokeLaunch_wholeTaxBecomesLiquidity() public {
        PoolKey memory key = _rewardLaunch(false, 0, 10_000);
        _swap(key, trader, true, true, 150 ether, "");
        _swap(key, trader, true, true, 5 ether, "");
        StokerHook.State memory s = _state(key);
        assertTrue(s.graduated);
        assertEq(s.holderPot, 0);
        assertEq(s.burnedCoins, 0);
        assertGt(s.lockedLiquidity, 0);
        assertEq(_hookPosition(key), s.lockedLiquidity);
    }

    /// Terms outside the PRD's bounds are refused at launch.
    function test_rewardTax_termsBounded() public {
        StokerFactory.LaunchParams memory p = _params(true);
        p.taxBps = 501;
        vm.prank(creator);
        vm.expectRevert(StokerHook.BadTerms.selector);
        factory.launch(p);
        p.taxBps = 300;
        p.burnShareBps = 6_000;
        p.liquidityShareBps = 5_000;
        vm.prank(creator);
        vm.expectRevert(StokerHook.BadTerms.selector);
        factory.launch(p);
    }
}
