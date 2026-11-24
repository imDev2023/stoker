// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ForkRouteBase} from "./ForkRouteBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// What the Graduation Hold adds to a swap's gas (#244), measured through the Universal Router the chain's
/// traffic uses, on the real PoolManager. Every top-level call is a transaction of its own (`isolate`), so each
/// figure is what that transaction pays, cold. A pool's first swap in a transaction judges the price the last
/// transaction left, so each step is named by what its judgement does: nothing to change, the start of a hold
/// (from the transaction before), a running hold kept, a hold cleared, Graduation recorded, and a swap after
/// Graduation. The same sequence was measured on `main` before the hold existed; the README sets the two side
/// by side. Each step is asserted to have taken the path it names.
/// forge-config: default.isolate = true
contract ForkHoldGasTest is ForkRouteBase {
    string[7] internal steps = [
        "buy, judging a price under the target",
        "buy across, judging a price under the target",
        "buy, judging a price above: starts the hold",
        "sell under, judging a hold that runs: kept",
        "buy across, judging a price under: clears the hold",
        "buy an hour later, judging a price above: records Graduation",
        "buy after Graduation"
    ];

    function _measured(PoolKey memory key, Trade memory t) internal returns (uint256) {
        (bytes[] memory inputs, uint256 value) = _routeCall(key, t, t.exactIn ? 0 : type(uint128).max, "");
        bytes memory commands = abi.encodePacked(uint8(0x10));
        uint256 deadline = vm.getBlockTimestamp() + 60;
        vm.prank(trader);
        (bool ok,) = UNIVERSAL_ROUTER.call{value: value}(
            abi.encodeWithSignature("execute(bytes,bytes[],uint256)", commands, inputs, deadline)
        );
        assertTrue(ok, "the swap went through");
        return vm.lastCallGas().gasTotalUsed;
    }

    function _walk(PoolKey memory key, uint256 small, uint256 cross) internal returns (uint256[7] memory gas) {
        _approveFor(UNIVERSAL_ROUTER, trader, key);
        uint256 t0 = vm.getBlockTimestamp();
        gas[0] = _measured(key, Trade(true, true, small));
        _assertPath(key, 0, 0);
        gas[1] = _measured(key, Trade(true, true, cross));
        _assertPath(key, 0, 0);
        gas[2] = _measured(key, Trade(true, true, small));
        _assertPath(key, t0, 0);
        gas[3] = _measured(key, Trade(false, true, _coinOf(key).balanceOf(trader)));
        _assertPath(key, t0, 0);
        gas[4] = _measured(key, Trade(true, true, cross));
        _assertPath(key, 0, 0);
        vm.warp(t0 + 1 hours);
        gas[5] = _measured(key, Trade(true, true, small));
        _assertPath(key, t0, t0 + 1 hours);
        gas[6] = _measured(key, Trade(true, true, small));
        _assertPath(key, t0, t0 + 1 hours);
        for (uint256 i; i < 7; i++) {
            emit log_named_uint(steps[i], gas[i]);
        }
    }

    /// The record as each transaction's judgement left it.
    function _assertPath(PoolKey memory key, uint256 holdSince, uint256 graduatedAt) internal view {
        StokerHook.Graduation memory g = hook.graduationOf(key.toId());
        assertEq(g.holdSince, holdSince, "the hold recorded");
        assertEq(g.graduatedAt, graduatedAt, "Graduation");
    }

    function test_fork_holdGas_nvda_quoteIsCurrency1() public {
        (, PoolKey memory key) = _launch(false, 1 ether);
        _walk(key, 1 ether, 100 ether);
    }

    function test_fork_holdGas_nvda_quoteIsCurrency0() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _walk(key, 1 ether, 100 ether);
    }

    function test_fork_holdGas_native() public {
        (, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        assertEq(Currency.unwrap(key.currency0), address(0));
        _walk(key, 0.1 ether, 7 ether);
    }
}
