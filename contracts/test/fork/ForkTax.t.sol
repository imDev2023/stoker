// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkTaxRouteBase} from "./ForkTaxRouteBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// #245's second fork criterion: through both Universal Routers, each swap of a Reward Launch moves exactly
/// its tax to the Tax Vault's books, in both directions, exact in and exact out, and the V4 Quoter's figure
/// includes it: the trade delivers the figure to the wei with the tax taken, and a bound one wei tighter
/// reverts. With the coin as currency0, as currency1, and paired with native ETH.
contract ForkTaxTest is ForkTaxRouteBase {
    function test_fork_tax_fourTrades_coinIsCurrency0() public {
        _fourTradesBookTheTax(UNIVERSAL_ROUTER, 0);
    }

    function test_fork_tax_fourTrades_coinIsCurrency1() public {
        _fourTradesBookTheTax(UNIVERSAL_ROUTER, 1);
    }

    function test_fork_tax_fourTrades_native() public {
        _fourTradesBookTheTax(UNIVERSAL_ROUTER, 2);
    }

    function test_fork_tax_v212_fourTrades_coinIsCurrency0() public {
        _fourTradesBookTheTax(UNIVERSAL_ROUTER_V2_1_2, 0);
    }

    function test_fork_tax_v212_fourTrades_coinIsCurrency1() public {
        _fourTradesBookTheTax(UNIVERSAL_ROUTER_V2_1_2, 1);
    }

    function test_fork_tax_v212_fourTrades_native() public {
        _fourTradesBookTheTax(UNIVERSAL_ROUTER_V2_1_2, 2);
    }

    function _launchKind(uint256 kind) internal returns (PoolKey memory) {
        if (kind == 2) {
            return _launchNativeTyped(StokerHook.LaunchType.Reward, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        }
        return _launchReward(kind == 1, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
    }

    function _fourTradesBookTheTax(address router, uint256 kind) internal {
        PoolKey memory key = _launchKind(kind);
        _approveFor(router, trader, key);
        uint256 u = _native(key) ? 0.05 ether : 1 ether;
        Trade[4] memory trades = [
            Trade(true, true, 10 * u),
            Trade(true, false, 1e10 ether),
            Trade(false, true, 1e10 ether),
            Trade(false, false, 2 * u)
        ];
        for (uint256 i; i < 4; i++) {
            Trade memory t = trades[i];
            uint256 figure = _quoteTrade(key, t);

            uint256 snap = vm.snapshotState();
            if (t.exactIn) {
                vm.expectRevert(abi.encodeWithSelector(V4TooLittleReceived.selector, figure + 1, figure));
                _route(router, trader, key, t, figure + 1);
            } else {
                vm.expectRevert(abi.encodeWithSelector(V4TooMuchRequested.selector, figure - 1, figure));
                _route(router, trader, key, t, figure - 1);
            }
            vm.revertToState(snap);

            _routeAndAssert(router, key, t, figure);
        }
    }

    struct Before {
        uint256 q;
        uint256 c;
        uint256 fee;
        uint256 tax;
        uint256 vault;
        bytes32 books;
    }

    function _before(PoolKey memory key) internal view returns (Before memory b) {
        b.q = _quoteBalanceOf(key, trader);
        b.c = _coinOfKey(key).balanceOf(trader);
        b.fee = _hookClaimsOf(key);
        b.tax = _taxBooked(key);
        b.vault = _vaultClaims(key);
        b.books = keccak256(abi.encode(taxVault.booksOf(key.toId())));
    }

    /// Routes at the Quoter's figure and checks it was delivered to the wei with exactly the tax taken.
    function _routeAndAssert(address router, PoolKey memory key, Trade memory t, uint256 figure) internal {
        Before memory b = _before(key);
        _route(router, trader, key, t, figure);
        uint256 fee = _hookClaimsOf(key) - b.fee;
        uint256 tax = _taxBooked(key) - b.tax;
        uint256 total = PLATFORM_FEE_BPS + TAX_BPS;
        uint256 q1 = _quoteBalanceOf(key, trader);
        uint256 c1 = _coinOfKey(key).balanceOf(trader);
        if (t.buy && t.exactIn) {
            assertEq(b.q - q1, t.amount, "paid");
            assertEq(c1 - b.c, figure, "the Quoter's coins");
            assertEq(tax, _rateOfGross(t.amount, TAX_BPS), "the tax: 3% of what was paid");
        } else if (t.buy) {
            assertEq(b.q - q1, figure, "the Quoter's price");
            assertEq(c1 - b.c, t.amount, "received");
            assertEq(tax, _rateOfNet(figure - fee - tax, TAX_BPS, total), "the tax on the buy's net");
        } else if (t.exactIn) {
            assertEq(b.c - c1, t.amount, "sold");
            assertEq(q1 - b.q, figure, "the Quoter's proceeds");
            assertEq(tax, _rateOfGross(figure + fee + tax, TAX_BPS), "the tax: 3% of the pool's output");
        } else {
            assertEq(b.c - c1, figure, "the Quoter's coins");
            assertEq(q1 - b.q, t.amount, "received");
            assertEq(tax, _rateOfNet(t.amount, TAX_BPS, total), "the tax on the sell's net");
        }
        assertGt(tax, 0);
        assertEq(_vaultClaims(key) - b.vault, tax, "exactly the tax reached the vault's claims");
        assertEq(keccak256(abi.encode(taxVault.booksOf(key.toId()))), b.books, "nothing spent in the swap");
        assertEq(_quoteBalanceOf(key, address(taxVault)), 0, "nothing transferred to the vault");
    }
}
