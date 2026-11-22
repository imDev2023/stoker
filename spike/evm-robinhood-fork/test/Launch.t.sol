// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerCoin} from "../src/StokerCoin.sol";

/// @notice #234 points 1 and 2: the one-transaction launch and the lock.
contract LaunchTest is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _assertLaunched(bool quoteIsCurrency0) internal {
        StokerFactory.LaunchParams memory p = _params(quoteIsCurrency0);
        p.firstBuy = 1 ether; // 1 NVDA
        uint256 creatorNvdaBefore = NVDA.balanceOf(creator);
        uint256 gasBefore = gasleft();
        (address coinAddr, PoolKey memory key) = _launch(p);
        emit log_named_uint("launch gas (incl. prank and approve)", gasBefore - gasleft());
        StokerCoin coin = StokerCoin(coinAddr);

        assertEq(_isQuote0(key), quoteIsCurrency0, "currency order");
        assertEq(coin.totalSupply(), 1_000_000_000_000 ether, "1 trillion at 18 decimals");
        // The First Buy ran inside the launch: the Creator holds coins and paid exactly 1 NVDA.
        uint256 bought = coin.balanceOf(creator);
        assertGt(bought, 0, "first buy delivered");
        assertEq(creatorNvdaBefore - NVDA.balanceOf(creator), 1 ether, "first buy paid");
        // Everything else is in the PoolManager or is the factory's rounding dust.
        uint256 dust = coin.balanceOf(address(factory));
        assertLt(dust, 1e6, "rounding dust only");
        assertEq(coin.balanceOf(address(POOL_MANAGER)) + bought + dust, coin.totalSupply(), "supply accounted");
        emit log_named_uint("first buy of 1 NVDA bought (coins, 18 dp)", bought);
        emit log_named_uint("seed rounding dust kept by the factory (wei)", dust);

        // The pool opened at the listing's start price and the First Buy moved it up from there.
        (uint160 sqrtPrice,, uint24 protocolFee, uint24 lpFee) = POOL_MANAGER.getSlot0(key.toId());
        assertGt(sqrtPrice, 0);
        assertEq(lpFee, 0, "LP fee is zero");
        assertEq(protocolFee, 0, "no protocol fee at this block");
        assertGt(_coinPriceTick(key), START_TICK, "first buy raised the coin's price");

        // One position, the factory's, holds all the pool's liquidity.
        (int24 lower, int24 upper) = quoteIsCurrency0
            ? (TickMath.minUsableTick(200), -START_TICK)
            : (START_TICK, TickMath.maxUsableTick(200));
        uint128 seedL = POOL_MANAGER.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(factory), lower, upper, bytes32(0))
        );
        assertGt(seedL, 0);
        assertEq(POOL_MANAGER.getLiquidity(key.toId()), seedL, "the seed is the only liquidity");
    }

    /// Point 1, with the coin as currency1 (the Quote Asset sorts first).
    function test_launch_oneTransaction_quoteIsCurrency0() public {
        _assertLaunched(true);
    }

    /// Point 1, with the coin as currency0.
    function test_launch_oneTransaction_quoteIsCurrency1() public {
        _assertLaunched(false);
    }

    /// Point 1: NVDA supports ERC-2612, so a Creator with no allowance launches and makes the First
    /// Buy in one transaction, with an off-chain signature in place of an approve transaction.
    function test_launch_withPermit_noPriorApprove() public {
        StokerFactory.LaunchParams memory p = _params(true);
        p.firstBuy = 2 ether;
        assertEq(NVDA.allowance(creator, address(factory)), 0);
        uint256 deadline = block.timestamp + 600;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                creator,
                address(factory),
                p.firstBuy,
                IERC20Permit(address(NVDA)).nonces(creator),
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IERC20Permit(address(NVDA)).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(creatorKey, digest);

        vm.prank(creator);
        (address coin,) = factory.launchWithPermit(p, deadline, v, r, s);
        assertGt(StokerCoin(coin).balanceOf(creator), 0, "first buy delivered");
        assertEq(NVDA.allowance(creator, address(factory)), 0, "permit spent exactly");
    }

    /// A quirk of the seed: with the coin as currency1 the pool opens on the range's upper edge,
    /// which v4 counts as outside it, so the pool reports zero active liquidity until the first
    /// buy. With the coin as currency0 it opens on the lower edge, which is inside.
    function test_launch_activeLiquidityAtOpen() public {
        (, PoolKey memory a) = _launch(_params(true));
        assertEq(POOL_MANAGER.getLiquidity(a.toId()), 0, "coin as currency1: none active at open");
        assertGt(_seedLiquidity(a), 0);
        (, PoolKey memory b) = _launch(_params(false));
        assertEq(POOL_MANAGER.getLiquidity(b.toId()), _seedLiquidity(b), "coin as currency0: all active");
        _swap(a, trader, true, true, 0.01 ether, "");
        assertEq(POOL_MANAGER.getLiquidity(a.toId()), _seedLiquidity(a), "active after a buy");
    }

    /// Point 1: the registry is the gate; an unlisted Quote Asset cannot be launched against.
    function test_launch_refusesUnlistedQuote() public {
        StokerFactory.LaunchParams memory p = _params(true);
        p.quote = makeAddr("unlisted");
        vm.prank(creator);
        vm.expectRevert(StokerFactory.NotListed.selector);
        factory.launch(p);
    }

    /// Point 2: nobody can open a second position, so nobody else's liquidity exists to withdraw.
    function test_lock_nobodyElseCanAddLiquidity() public {
        (, PoolKey memory key) = _launch(_params(true));
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(POOL_MANAGER);
        vm.startPrank(trader);
        NVDA.approve(address(lp), type(uint256).max);
        vm.expectRevert(); // LiquidityAddsClosed, wrapped by the PoolManager
        lp.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(200),
                tickUpper: TickMath.maxUsableTick(200),
                liquidityDelta: 1e18,
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    /// Point 2: a removal is refused by the hook whoever asks, and the seed's liquidity is the
    /// same after the attempt and after trading both ways.
    function test_lock_noPathRemovesTheSeed() public {
        StokerFactory.LaunchParams memory p = _params(true);
        p.firstBuy = 1 ether;
        (, PoolKey memory key) = _launch(p);
        uint128 before = _seedLiquidity(key);

        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(POOL_MANAGER);
        ModifyLiquidityParams memory remove = ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(200),
            tickUpper: -START_TICK,
            liquidityDelta: -1,
            salt: 0
        });
        // A stranger, and even a contract calling as the factory, is stopped by beforeRemoveLiquidity.
        vm.expectRevert();
        lp.modifyLiquidity(key, remove, "");
        vm.prank(address(factory));
        vm.expectRevert();
        lp.modifyLiquidity(key, remove, "");
        // The factory's callback answers the PoolManager alone.
        vm.expectRevert(StokerFactory.NotPoolManager.selector);
        factory.unlockCallback("");

        _swap(key, trader, true, true, 10 ether, "");
        _swap(key, trader, false, true, _coin(key).balanceOf(trader), "");
        assertEq(_seedLiquidity(key), before, "seed liquidity unchanged");
    }

    /// Point 2, by fuzzing: any buy then any sell leaves the seed's liquidity where it was.
    function testFuzz_lock_tradingNeverMovesTheSeed(uint256 buyIn, uint256 sellShare) public {
        buyIn = bound(buyIn, 0.001 ether, 200 ether);
        sellShare = bound(sellShare, 1, 10_000);
        (, PoolKey memory key) = _launch(_params(false));
        uint128 before = _seedLiquidity(key);
        assertGt(before, 0);
        _swap(key, trader, true, true, buyIn, "");
        _swap(key, trader, false, true, _coin(key).balanceOf(trader) * sellShare / 10_000, "");
        assertEq(_seedLiquidity(key), before);
    }

    function _seedLiquidity(PoolKey memory key) internal view returns (uint128) {
        (int24 lower, int24 upper) = _isQuote0(key)
            ? (TickMath.minUsableTick(200), -START_TICK)
            : (START_TICK, TickMath.maxUsableTick(200));
        return POOL_MANAGER.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(factory), lower, upper, bytes32(0))
        );
    }
}
