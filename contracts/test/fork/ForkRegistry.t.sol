// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The Quote Registry on the real PoolManager (#243): a launch against an asset with no Listing reverts,
/// and one against a listed asset opens at the Listing's start price; a later write reaches only later
/// Launches.
contract ForkRegistryTest is ForkBase {
    using StateLibrary for IPoolManager;

    /// Global Dollar (USDG) on Robinhood Chain, a real asset no Listing names until the Admin writes one
    /// (docs/evm/research/quote-assets-and-rehearsal.md, #249).
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    /// A USDG start price: the whole supply (1e30 raw units) worth about $5,000 (5e9 raw units of USDG's
    /// six decimals), 5e-21 a coin raw unit: 1.0001^-467400.
    int24 internal constant USDG_START_TICK = -467_400;

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = pm.getSlot0(key.toId());
    }

    function test_fork_registry_unlistedAssetReverts_listedOpensAtItsStartPrice() public {
        // USDG has no Listing: the factory refuses it.
        quote = IERC20(USDG);
        StokerFactory.LaunchParams memory p = _params(false, 0);
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(StokerFactory.NotListed.selector, USDG));
        factory.launch(p);

        // The Admin lists it; a launch in each currency order opens at the Listing's start price.
        vm.prank(platform);
        registry.list(USDG, USDG_START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        (, PoolKey memory k1) = _launch(false, 0);
        assertEq(_tick(k1), USDG_START_TICK, "coin as currency0: the pool's price is the start price");
        (, PoolKey memory k0) = _launch(true, 0);
        assertEq(_tick(k0), -USDG_START_TICK, "USDG as currency0: the pool's price is its inverse");
        assertEq(hook.termsOf(k0.toId()).startTick, USDG_START_TICK);
        assertEq(hook.termsOf(k0.toId()).graduationMultiple, GRADUATION_MULTIPLE);

        // NVDA and native ETH, listed at setUp, open at theirs (a second Creator, so the coin's CREATE2
        // address is not the first USDG coin's).
        quote = IERC20(NVDA);
        (creator, creatorKey) = makeAddrAndKey("nvdaCreator");
        (, PoolKey memory kn) = _launch(false, 0);
        assertEq(_tick(kn), START_TICK);
        _listNative();
        (, PoolKey memory ke) = _launchNative(0, address(0));
        assertEq(_tick(ke), -NATIVE_START_TICK, "native ETH is always currency0");
    }

    /// A routine write and then a scheduled change reach only Launches made after them; the coin launched
    /// first keeps its own start price, Graduation Target and Referrer Fee cap, and trades on.
    function test_fork_registry_aLaterWriteReachesOnlyLaterLaunches() public {
        (, PoolKey memory first) = _launch(false, 1 ether);
        StokerHook.Terms memory before = hook.termsOf(first.toId());

        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1 days);
        vm.prank(platform);
        registry.writeStartPrice(NVDA, START_TICK + 2_200);
        vm.warp(t0 + 2 days);
        vm.prank(platform);
        registry.scheduleChange(NVDA, START_TICK + 10_000, 25, 40);
        vm.warp(t0 + 4 days);

        assertEq(abi.encode(hook.termsOf(first.toId())), abi.encode(before), "the first coin's terms");
        _swap(first, trader, true, true, 1 ether);

        (creator, creatorKey) = makeAddrAndKey("laterCreator");
        (, PoolKey memory later) = _launch(false, 0);
        assertEq(_tick(later), START_TICK + 10_000, "a later coin opens at the start price in force");
        assertEq(hook.termsOf(later.toId()).graduationMultiple, 25);
        assertEq(hook.termsOf(later.toId()).referrerFeeCapBps, 40);
    }
}
