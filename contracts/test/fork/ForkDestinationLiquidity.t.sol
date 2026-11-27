// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkDestinationsBase} from "./ForkDestinationsBase.sol";

/// The liquidity's Destination on the real PoolManager (#248): a coin's Creator earnings become Support
/// Liquidity in the coin's own pool, which grows by them, with no coin bought and the price unmoved.
contract ForkDestinationLiquidityTest is ForkDestinationsBase {
    function _supportFromTheEarnings(uint256 kind) internal {
        PoolKey memory key = _launchTo(kind, address(liquidityDestination));
        IERC20 coin = _coinOfKey(key);
        _earnThrough(key);
        uint256 credited = _credited(key);
        assertGt(credited, 0, _kindName(kind));

        assertEq(_applyBy(stranger, liquidityDestination, key), credited, "exactly the coin's own earnings");
        (, uint256 supportFunded) = taxVault.fundedWaiting(key);
        assertEq(supportFunded, credited);

        uint160 price = _sqrtPrice(key);
        uint256 supply = coin.totalSupply();
        uint256 inPool = coin.balanceOf(address(pm));
        uint256 quoteInPool = _assetBalance(key, address(pm));
        uint256 addedInAll;
        uint256 heldInAll;
        uint256 pieces;
        while (true) {
            (, supportFunded) = taxVault.fundedWaiting(key);
            if (supportFunded <= 2) break;
            vm.recordLogs();
            (Support memory s, uint256 added) = _addSupport(key);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; i++) {
                assertTrue(logs[i].topics[0] != IPoolManager.Swap.selector, "no swap: no coin bought");
            }
            assertGt(_supportLiquidity(key, s), 0, "the vault holds the position");
            (uint256 quoteHeld, uint256 coinsHeld) = _supportHoldings(key, s);
            assertEq(coinsHeld, 0, "Quote Asset alone");
            heldInAll = quoteHeld;
            addedInAll += added;
            pieces++;
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
        }
        assertGt(pieces, 0);
        assertGt(heldInAll, 0, "Support Liquidity grew");
        assertLe(addedInAll, credited);
        assertGe(addedInAll + 2 * pieces, credited, "all of the earnings but each piece's rounding");
        assertEq(_sqrtPrice(key), price, "the price did not move");
        assertEq(coin.totalSupply(), supply, "no coin was burned");
        assertEq(coin.balanceOf(address(pm)), inPool, "no coin left the pool or entered it");
        // The Quote Asset stayed in the PoolManager: it moved from the vault's claims into the pool.
        assertEq(_assetBalance(key, address(pm)), quoteInPool);
        assertEq(coin.balanceOf(address(taxVault)), 0);
    }

    function test_fork_liquidity_supportLiquidityGrows_noCoinBought_nvdaAsCurrency0() public {
        _supportFromTheEarnings(QUOTE_FIRST);
    }

    function test_fork_liquidity_supportLiquidityGrows_noCoinBought_theCoinAsCurrency0() public {
        _supportFromTheEarnings(COIN_FIRST);
    }

    function test_fork_liquidity_supportLiquidityGrows_noCoinBought_nativeEth() public {
        _supportFromTheEarnings(NATIVE_PAIR);
    }
}
