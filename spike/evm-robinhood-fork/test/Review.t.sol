// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";

/// Review tests for PR #239 (main session, 2026-11-22): measurements for #235, not points of the ticket.
contract ReviewTest is ForkBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address internal attacker = makeAddr("attacker");

    function _fund(address who, uint256 amount) internal {
        deal(address(NVDA), who, amount);
    }

    /// A: what does it cost one wallet to force Graduation and leave again?
    function test_review_forcedGraduationCost() public {
        (, PoolKey memory key) = _launch(_params(false));
        _fund(attacker, 1_000 ether);
        uint256 creatorBefore = NVDA.balanceOf(creatorDestination);

        _swap(key, attacker, true, true, 115 ether, "");
        assertTrue(hook.state(key.toId()).graduated, "graduated by one buy");
        _swap(key, attacker, false, true, _coin(key).balanceOf(attacker), "");

        uint256 lost = 1_000 ether - NVDA.balanceOf(attacker);
        emit log_named_decimal_uint("NVDA spent to cross", 115 ether, 18);
        emit log_named_decimal_uint("NVDA lost on the round trip", lost, 18);
        emit log_named_decimal_uint("of which paid to the Creator Destination", NVDA.balanceOf(creatorDestination) - creatorBefore, 18);
        assertTrue(hook.state(key.toId()).graduated, "still graduated with nothing left in the pool");
    }

    /// B: a Stoke Launch's tax waits for Graduation; what does the wallet that crosses take?
    function _churn(PoolKey memory key, uint256 cycles) internal {
        _fund(trader, 5_000 ether);
        for (uint256 i; i < cycles; i++) {
            _swap(key, trader, true, true, 40 ether, "");
            _swap(key, trader, false, true, _coin(key).balanceOf(trader), "");
        }
    }

    function _crossAndLeave(PoolKey memory key, uint256 buy) internal returns (int256 pnl) {
        _fund(attacker, 10_000 ether);
        _swap(key, attacker, true, true, buy, "");
        _swap(key, attacker, false, true, _coin(key).balanceOf(attacker), "");
        pnl = int256(NVDA.balanceOf(attacker)) - int256(10_000 ether);
    }

    function _stoke(uint16 taxBps) internal returns (PoolKey memory key) {
        StokerFactory.LaunchParams memory p = _params(false);
        p.taxBps = taxBps;
        p.liquidityShareBps = 10_000;
        (, key) = _launch(p);
    }

    function _measure(uint16 taxBps, uint256 cycles) internal {
        PoolKey memory key = _stoke(taxBps);
        _churn(key, cycles);
        StokerHook.State memory s = hook.state(key.toId());
        assertFalse(s.graduated);
        emit log_named_uint("tax bps", taxBps);
        emit log_named_decimal_uint("tax waiting for Graduation (NVDA)", s.pendingLiquidityQuote, 18);
        uint256 snap = vm.snapshotState();
        uint256[4] memory sizes = [uint256(125 ether), 250 ether, 500 ether, 1_000 ether];
        for (uint256 i; i < sizes.length; i++) {
            int256 pnl = _crossAndLeave(key, sizes[i]);
            emit log_named_decimal_uint("  cross with a buy of", sizes[i], 18);
            emit log_named_decimal_int("  round-trip result (NVDA)", pnl, 18);
            vm.revertToState(snap);
        }
    }

    function test_review_graduationFlushCapture_tax5() public {
        _measure(500, 12);
    }

    function test_review_graduationFlushCapture_tax1() public {
        _measure(100, 40);
    }

    /// The same round trip with nothing waiting, as the control.
    function test_review_graduationFlushCapture_control() public {
        PoolKey memory key = _stoke(500);
        int256 pnl = _crossAndLeave(key, 250 ether);
        emit log_named_decimal_int("control, 5% tax, buy 250, nothing waiting (NVDA)", pnl, 18);
    }

    /// C: a donation credits the hook's position with fees; does the next add survive it?
    function test_review_donationBreaksTheNextAdd() public {
        StokerFactory.LaunchParams memory p = _params(true);
        p.taxBps = 300;
        p.burnShareBps = 2_500;
        p.liquidityShareBps = 2_500;
        (, PoolKey memory key) = _launch(p);
        _swap(key, trader, true, true, 140 ether, "");
        assertTrue(hook.state(key.toId()).graduated);
        assertGt(hook.state(key.toId()).lockedLiquidity, 0);

        PoolDonateTest donor = new PoolDonateTest(POOL_MANAGER);
        _fund(attacker, 100 ether);
        vm.startPrank(attacker);
        NVDA.approve(address(donor), type(uint256).max);
        bool q0 = _isQuote0(key);
        donor.donate(key, q0 ? 50 ether : 0, q0 ? 0 : 50 ether, "");
        vm.stopPrank();

        // A 1 NVDA buy crosses the flush threshold and adds liquidity inside the swap.
        vm.expectRevert();
        this.externalSwap(key, 1 ether);
        emit log("a 1 NVDA buy reverts after a 50 NVDA donation");

        // A larger trade's add exceeds the accrued fees and clears it.
        _swap(key, trader, true, true, 100 ether, "");
        _swap(key, trader, true, true, 1 ether, "");
        emit log("a 100 NVDA buy clears it; 1 NVDA buys work again");
    }

    function externalSwap(PoolKey memory key, uint256 amount) external {
        _swap(key, trader, true, true, amount, "");
    }
}
