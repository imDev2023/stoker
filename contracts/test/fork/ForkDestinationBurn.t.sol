// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkDestinationsBase} from "./ForkDestinationsBase.sol";
import {EarningsDestination} from "../../src/destinations/EarningsDestination.sol";

/// The burn's Destination on the real PoolManager (#248): a coin's Creator earnings, in a real Stock Token
/// and in native ETH, are paid to the Destination by the Payout Call, handed to the coin's burn in the Tax
/// Vault, and spent in capped buys that burn what they buy, so the supply falls.
contract ForkDestinationBurnTest is ForkDestinationsBase {
    function _burnTheEarnings(uint256 kind) internal {
        PoolKey memory key = _launchTo(kind, address(burnDestination));
        IERC20 coin = _coinOfKey(key);
        _earnThrough(key);
        uint256 credited = _credited(key);
        assertGt(credited, 0, _kindName(kind));

        // A Keeper's Payout Call pays the Destination like any Credit owner, under a Keeper's gas.
        address[] memory owners = new address[](2);
        (owners[0], owners[1]) = (address(burnDestination), platform);
        vm.prank(stranger);
        hook.payout{gas: KEEPER_GAS}(_asset(key), owners);
        assertEq(_creditIn(key, address(burnDestination)), 0, "paid, not refused");
        assertEq(_assetBalance(key, address(burnDestination)), credited);

        assertEq(_applyBy(stranger, burnDestination, key), credited, "exactly the coin's own earnings");
        assertEq(_assetBalance(key, address(burnDestination)), 0);
        (uint256 burnFunded,) = taxVault.fundedWaiting(key);
        assertEq(burnFunded, credited);

        uint256 supply = coin.totalSupply();
        uint256 burnedInAll;
        uint256 pieces;
        while (true) {
            (burnFunded,) = taxVault.fundedWaiting(key);
            if (burnFunded == 0) break;
            uint256 cap = taxVault.pieceCap(key);
            vm.prank(stranger);
            (uint256 spent, uint256 burned) = taxVault.burn(key);
            assertLe(spent, cap, "each piece within the cap");
            burnedInAll += burned;
            pieces++;
            _letThePriceStand();
        }
        assertGt(pieces, 0);
        assertEq(supply - coin.totalSupply(), burnedInAll, "the supply fell by exactly what was bought");
        assertEq(coin.balanceOf(address(taxVault)), 0);
        assertGt(burnDestination.waitingOf(key), 0, "the buys paid the fee: the rule compounds");
    }

    function test_fork_burn_theSupplyFalls_nvdaAsCurrency0() public {
        _burnTheEarnings(QUOTE_FIRST);
    }

    function test_fork_burn_theSupplyFalls_theCoinAsCurrency0() public {
        _burnTheEarnings(COIN_FIRST);
    }

    function test_fork_burn_theSupplyFalls_nativeEth() public {
        _burnTheEarnings(NATIVE_PAIR);
    }

    /// With the Destination blocked by the Stock Token's registry, its earnings stay owed in the hook and
    /// nothing is applied; the coin trades on, and once unblocked the work goes through.
    function test_fork_burn_aDestinationTheIssuerBlocksStaysOwed() public {
        PoolKey memory key = _launchTo(QUOTE_FIRST, address(burnDestination));
        _earnThrough(key);
        uint256 owed = _creditIn(key, address(burnDestination));
        _block(address(burnDestination));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(EarningsDestination.CreditNotReceived.selector, owed));
        burnDestination.applyEarnings(key);
        _trade(key, trader, true, true, 1 ether);
        assertGt(_creditIn(key, address(burnDestination)), owed, "the coin trades on, and it is credited");

        vm.clearMockedCalls();
        assertEq(_applyBy(stranger, burnDestination, key), _credited(key));
    }
}
