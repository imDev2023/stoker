// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkTaxRouteBase} from "./ForkTaxRouteBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// #245's fourth fork criterion and its last: the public call spends the Reward Burn share in pieces no
/// larger than the cap and the coin's supply falls by what was bought; and no swap of a trader contains a
/// buy made by the Tax Vault. With the coin as currency0, as currency1, and paired with native ETH.
contract ForkBurnTest is ForkTaxRouteBase {
    function _launchKind(uint256 kind) internal returns (PoolKey memory) {
        if (kind == 2) {
            return _launchNativeTyped(StokerHook.LaunchType.Reward, 5_000, 0, StokerHook.PayoutAsset.QuoteAsset);
        }
        return _launchReward(kind == 1, 5_000, 0, StokerHook.PayoutAsset.QuoteAsset);
    }

    function _churn(PoolKey memory key) internal {
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        for (uint256 i; i < 4; i++) {
            _trade(key, trader, true, true, 40 * u);
            _trade(key, trader, false, true, _coinOfKey(key).balanceOf(trader) / 2);
        }
    }

    function test_fork_burn_cappedPieces_supplyFalls_coinIsCurrency0() public {
        _burnInPieces(_launchKind(0));
    }

    function test_fork_burn_cappedPieces_supplyFalls_coinIsCurrency1() public {
        _burnInPieces(_launchKind(1));
    }

    function test_fork_burn_cappedPieces_supplyFalls_native() public {
        _burnInPieces(_launchKind(2));
    }

    function _burnInPieces(PoolKey memory key) internal {
        _churn(key);
        IERC20 coin = _coinOfKey(key);
        (uint256 burnPart,,,) = taxVault.waiting(key);
        uint256 supply0 = coin.totalSupply();
        uint256 spentTotal;
        uint256 burnedTotal;
        uint256 n;
        for (; n < 50; n++) {
            (uint256 waitingNow,,,) = taxVault.waiting(key);
            if (waitingNow < 1e9) break;
            uint256 cap = taxVault.pieceCap(key);
            uint256 supply = coin.totalSupply();
            vm.prank(stranger);
            (uint256 spent, uint256 burned) = taxVault.burn(key);
            assertLe(spent, cap, "no piece larger than the cap");
            assertEq(supply - coin.totalSupply(), burned, "the supply fell by what was bought");
            spentTotal += spent;
            burnedTotal += burned;
            vm.warp(vm.getBlockTimestamp() + PIECE_INTERVAL);
        }
        assertGt(n, 1, "it took several pieces");
        assertEq(supply0 - coin.totalSupply(), burnedTotal, "every coin bought was burned");
        assertEq(coin.balanceOf(address(taxVault)), 0, "the vault kept none");
        (uint256 left,,,) = taxVault.waiting(key);
        assertEq(spentTotal + left, burnPart, "the burn spent its own share and no more");
        emit log_named_uint("pieces", n);
        emit log_named_decimal_uint("Quote Asset spent on the Reward Burn", spentTotal, 18);
        emit log_named_decimal_uint("coins burned", burnedTotal, 18);
    }

    function test_fork_burn_noTraderSwapContainsAVaultBuy() public {
        for (uint256 kind; kind < 3; kind++) {
            PoolKey memory key = _launchKind(kind);
            _churn(key);
            _approveFor(UNIVERSAL_ROUTER, trader, key);
            uint256 u = _native(key) ? 0.05 ether : 1 ether;
            Trade memory t = Trade(true, true, 5 * u);
            TaxVault.Books memory before = taxVault.booksOf(key.toId());
            vm.recordLogs();
            _route(UNIVERSAL_ROUTER, trader, key, t, 0);
            _assertOneSwapBy(vm.getRecordedLogs(), UNIVERSAL_ROUTER);
            assertEq(taxVault.booksOf(key.toId()).burnSpent, before.burnSpent, "no vault buy in the trader's swap");

            // The vault's own buy is its own transaction, its own swap, with the vault as the sender.
            vm.recordLogs();
            vm.prank(stranger);
            taxVault.burn(key);
            _assertOneSwapBy(vm.getRecordedLogs(), address(taxVault));
        }
    }

    function _assertOneSwapBy(Vm.Log[] memory logs, address sender) internal view {
        uint256 swaps;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pm) && logs[i].topics[0] == IPoolManager.Swap.selector) {
                swaps++;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), sender, "the swap's sender");
            }
        }
        assertEq(swaps, 1, "exactly one swap");
    }
}
