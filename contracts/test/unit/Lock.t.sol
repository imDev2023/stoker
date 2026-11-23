// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {SeedRemover} from "../utils/SeedRemover.sol";

/// Nothing removes the Seed Position, nobody else adds liquidity, and donations are refused (ADR 0024,
/// ADR 0025).
contract LockTest is LocalBase {
    using StateLibrary for IPoolManager;

    PoolKey internal key;
    PoolModifyLiquidityTest internal lpRouter;
    PoolDonateTest internal donateRouter;
    uint128 internal seed;

    function setUp() public override {
        super.setUp();
        (, key) = _launch(true, 1 ether);
        seed = _seedLiquidity(key);
        lpRouter = new PoolModifyLiquidityTest(pm);
        donateRouter = new PoolDonateTest(pm);
        vm.prank(trader);
        quote.approve(address(lpRouter), type(uint256).max);
        vm.prank(trader);
        quote.approve(address(donateRouter), type(uint256).max);
    }

    function test_lock_theFactoryItselfCannotRemoveTheSeed() public {
        // Give the factory's own address code that tries to remove its position: the hook refuses,
        // whoever the position's owner is.
        (int24 lower, int24 upper) = factory.seedRange(key.toId());
        vm.etch(address(factory), address(new SeedRemover(pm)).code);
        vm.expectRevert();
        SeedRemover(address(factory)).remove(key, lower, upper, int256(uint256(seed)));
        vm.expectRevert();
        SeedRemover(address(factory)).remove(key, lower, upper, 0); // a zero "poke" is a removal to v4
        assertEq(
            pm.getPositionLiquidity(key.toId(), Position.calculatePositionKey(address(factory), lower, upper, 0)),
            seed,
            "seed untouched"
        );
    }

    function test_lock_nobodyRemovesThroughARouter() public {
        (int24 lower, int24 upper) = factory.seedRange(key.toId());
        address[3] memory who = [creator, stranger, platform];
        for (uint256 i; i < who.length; i++) {
            vm.prank(who[i]);
            vm.expectRevert();
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -int256(uint256(seed)), 0), "");
        }
        assertEq(_seedLiquidity(key), seed);
    }

    function test_lock_nobodyElseAddsLiquidity() public {
        vm.prank(trader);
        vm.expectRevert();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_200, 887_200, 1e18, 0), "");
        vm.prank(creator);
        vm.expectRevert();
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_200, 887_200, 1e18, 0), "");
        assertEq(_poolLiquidity(key), seed);
    }

    function test_lock_donationsRefused() public {
        bool q0 = _isQuote0(key);
        vm.prank(trader);
        vm.expectRevert();
        donateRouter.donate(key, q0 ? 50 ether : 0, q0 ? 0 : 50 ether, "");
        // The next swap goes through untouched.
        _swap(key, trader, true, true, 1 ether);
    }

    function test_lock_nobodyElseInitializesAPoolOnTheHook() public {
        // A pool keyed on our hook that the factory did not open would carry no Launch's terms.
        PoolKey memory foreign = key;
        foreign.tickSpacing = 60;
        vm.expectRevert();
        pm.initialize(foreign, TickMath.getSqrtPriceAtTick(0));
    }

    function test_lock_tradingNeverMovesTheSeed() public {
        for (uint256 i; i < 5; i++) {
            _swap(key, trader, true, true, 10 ether);
            _swap(key, trader, false, true, _coin(key).balanceOf(trader) / 3);
        }
        assertEq(_seedLiquidity(key), seed);
    }
}
