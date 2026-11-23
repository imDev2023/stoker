// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {ForkBase} from "./ForkBase.sol";
import {SeedRemover} from "../utils/SeedRemover.sol";
import {OpcodeScan} from "../utils/OpcodeScan.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";

/// The launch and the lock on the real PoolManager, against NVDA (#241's first three fork criteria).
contract ForkLaunchTest is ForkBase {
    using StateLibrary for IPoolManager;

    function _launchWithPermit(bool quoteIsCurrency0) internal returns (address coin, PoolKey memory key) {
        StokerFactory.LaunchParams memory p = _params(quoteIsCurrency0, 1 ether);
        assertEq(quote.allowance(creator, address(factory)), 0, "no prior approval");
        StokerFactory.PermitSignature memory s = _permit(1 ether, block.timestamp + 1 hours);
        PoolId id;
        vm.prank(creator);
        (coin, id) = factory.launchWithPermit(p, s);
        key = _keyFor(coin);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(id));
        assertEq(address(quote) < coin, quoteIsCurrency0, "currency order");
    }

    function test_fork_launch_permitFirstBuy_quoteIsCurrency0() public {
        _assertLaunch(true);
    }

    function test_fork_launch_permitFirstBuy_quoteIsCurrency1() public {
        _assertLaunch(false);
    }

    function _assertLaunch(bool quoteIsCurrency0) internal {
        uint256 nvdaBefore = quote.balanceOf(creator);
        uint256 gasBefore = gasleft();
        (address coin, PoolKey memory key) = _launchWithPermit(quoteIsCurrency0);
        emit log_named_uint("launch gas, permit First Buy included", gasBefore - gasleft());
        StokerCoin c = StokerCoin(coin);

        assertEq(nvdaBefore - quote.balanceOf(creator), 1 ether, "the Creator paid exactly 1 NVDA");
        uint256 bought = c.balanceOf(creator);
        assertGt(bought, 0, "the First Buy delivered coins");
        emit log_named_uint("coins for 1 NVDA", bought);
        assertEq(c.balanceOf(address(factory)), 0, "factory holds no coin");
        assertEq(c.balanceOf(address(pm)) + bought, c.totalSupply(), "every coin in the pool or with the Creator");
        assertLe(SUPPLY - c.totalSupply(), 1e12, "only seed dust burned");

        // A plain coin: no owner and no way to mint.
        (bool ok,) = coin.staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");
        (ok,) = coin.call(abi.encodeWithSignature("mint(address,uint256)", creator, 1));
        assertFalse(ok, "no mint");
        assertEq(c.decimals(), 18);

        // The pool: LP fee zero, the seed its only liquidity, the price above the start.
        (,, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        assertEq(lpFee, 0);
        emit log_named_uint("protocol fee on a new pool", protocolFee);
        assertEq(_poolLiquidity(key), _seedLiquidity(key));

        uint256 fee = _feeOnGross(1 ether);
        assertEq(_credit(creator), fee * CREATOR_SHARE_BPS / 10_000, "the First Buy credited the Creator");
        assertEq(_credit(platform), fee - _credit(creator));

        // The runtimes read no block.number (an L1 estimate on this chain).
        assertFalse(OpcodeScan.contains(coin.code, OpcodeScan.NUMBER));
        assertFalse(OpcodeScan.contains(address(hook).code, OpcodeScan.NUMBER));
        assertFalse(OpcodeScan.contains(address(factory).code, OpcodeScan.NUMBER));
    }

    function test_fork_lock_noCallByAnyoneRemovesTheSeed() public {
        for (uint256 o; o < 2; o++) {
            (, PoolKey memory key) = _launchWithPermit(o == 0);
            _swap(key, trader, true, true, 10 ether);
            (int24 lower, int24 upper) = factory.seedRange(key.toId());
            uint128 seed = _seedLiquidity(key);
            bytes32 positionKey = Position.calculatePositionKey(address(factory), lower, upper, 0);

            // Through a liquidity router, from the Creator, a stranger and the platform.
            PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(pm);
            address[3] memory who = [creator, stranger, platform];
            for (uint256 i; i < who.length; i++) {
                vm.prank(who[i]);
                vm.expectRevert();
                lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, -int256(uint256(seed)), 0), "");
            }
            // From the factory's own address, given code that tries: the position's owner is refused too.
            uint256 snap = vm.snapshotState();
            vm.etch(address(factory), address(new SeedRemover(pm)).code);
            vm.expectRevert();
            SeedRemover(address(factory)).remove(key, lower, upper, int256(uint256(seed)));
            vm.expectRevert();
            SeedRemover(address(factory)).remove(key, lower, upper, 0);
            assertEq(pm.getPositionLiquidity(key.toId(), positionKey), seed, "seed untouched");
            vm.revertToState(snap);

            // Nobody else adds liquidity, and a donation is refused.
            deal(NVDA, stranger, 100 ether);
            vm.startPrank(stranger);
            quote.approve(address(lpRouter), type(uint256).max);
            vm.expectRevert();
            lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, 1e18, 0), "");
            PoolDonateTest donor = new PoolDonateTest(pm);
            quote.approve(address(donor), type(uint256).max);
            vm.expectRevert();
            donor.donate(key, _isQuote0(key) ? 50 ether : 0, _isQuote0(key) ? 0 : 50 ether, "");
            vm.stopPrank();

            // Trading on, the seed stays whole and the next swap succeeds.
            _swap(key, trader, false, true, _coin(key).balanceOf(trader) / 2);
            _swap(key, trader, true, true, 1 ether);
            assertEq(_seedLiquidity(key), seed);
            assertEq(_poolLiquidity(key), seed, "still the pool's only liquidity");
        }
    }
}
