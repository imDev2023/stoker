// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerHook} from "../src/StokerHook.sol";

/// @notice #234 point 5: Graduation as a threshold, latched the first time the price crosses the
///         Launch's Graduation Target and never reversed by a later fall.
contract GraduationTest is ForkBase {
    using PoolIdLibrary for PoolKey;

    function _graduatedEvents() internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == StokerHook.Graduated.selector) n++;
        }
    }

    function _assertLatch(bool quoteIsCurrency0) internal {
        (, PoolKey memory key) = _launch(_params(quoteIsCurrency0));

        _swap(key, trader, true, true, 50 ether, "");
        assertLt(_coinPriceTick(key), GRADUATION_TICK, "below the target");
        assertFalse(hook.state(key.toId()).graduated, "not yet");

        vm.warp(block.timestamp + 3_600);
        uint64 crossedAt = uint64(block.timestamp);
        vm.recordLogs();
        _swap(key, trader, true, true, 60 ether, "");
        assertEq(_graduatedEvents(), 1, "one Graduated event, in the crossing swap");
        StokerHook.State memory s = hook.state(key.toId());
        assertGe(_coinPriceTick(key), GRADUATION_TICK, "crossed the target");
        assertTrue(s.graduated, "graduated");
        assertEq(s.graduatedAt, crossedAt, "stamped with the block's timestamp");

        // The price falls back under the target: Graduation stands, and its time does not move.
        vm.warp(block.timestamp + 86_400);
        vm.recordLogs();
        _swap(key, trader, false, true, _coin(key).balanceOf(trader), "");
        assertLt(_coinPriceTick(key), GRADUATION_TICK, "back below the target");
        s = hook.state(key.toId());
        assertTrue(s.graduated, "never reversed");
        assertEq(s.graduatedAt, crossedAt, "recorded once");

        // Crossing again records nothing new.
        _swap(key, trader, true, true, 200 ether, "");
        assertEq(hook.state(key.toId()).graduatedAt, crossedAt);
        assertEq(_graduatedEvents(), 0, "no second Graduated event");
    }

    function test_graduation_latchesOnce_quoteIsCurrency0() public {
        _assertLatch(true);
    }

    function test_graduation_latchesOnce_quoteIsCurrency1() public {
        _assertLatch(false);
    }
}
