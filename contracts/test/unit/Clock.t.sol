// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "../utils/LocalBase.sol";
import {OpcodeScan} from "../utils/OpcodeScan.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {Distributor} from "../../src/Distributor.sol";

/// The contracts read time only, never `block.number`, which on Robinhood Chain and Arbitrum is an
/// estimate of the L1 block (the security standards' robinhood-4663 profile, question 1).
contract ClockTest is LocalBase {
    function test_clock_noBlockNumberInAnyRuntime() public {
        (address coin,) = _launch(true, 0);
        assertFalse(OpcodeScan.contains(address(hook).code, OpcodeScan.NUMBER), "hook");
        assertFalse(OpcodeScan.contains(address(factory).code, OpcodeScan.NUMBER), "factory");
        assertFalse(OpcodeScan.contains(coin.code, OpcodeScan.NUMBER), "coin");
        assertFalse(OpcodeScan.contains(address(registry).code, OpcodeScan.NUMBER), "registry");
        assertFalse(OpcodeScan.contains(address(keys).code, OpcodeScan.NUMBER), "keys");
        // The registry's clocks (a day between writes, 48 hours to a scheduled change) read the timestamp.
        assertTrue(OpcodeScan.contains(address(registry).code, OpcodeScan.TIMESTAMP), "the registry reads the time");
        assertFalse(OpcodeScan.contains(address(taxVault).code, OpcodeScan.NUMBER), "tax vault");
        // So do the Graduation Hold (#244) and the Creator Lock's schedule.
        assertTrue(OpcodeScan.contains(address(hook).code, OpcodeScan.TIMESTAMP), "the hold reads the time");
    }

    /// A Creator Lock's runtime (#244) reads the time and never the block number.
    function test_clock_theCreatorLockReadsTimeOnly() public {
        StokerFactory.LaunchParams memory p = _params(true, 0);
        p.creatorLockBps = 2_000;
        p.creatorLockCliff = 7 days;
        vm.prank(creator);
        (, PoolId id) = factory.launch(p);
        address lock = factory.creatorLockOf(id);
        assertFalse(OpcodeScan.contains(lock.code, OpcodeScan.NUMBER), "lock");
        assertTrue(OpcodeScan.contains(lock.code, OpcodeScan.TIMESTAMP), "the lock reads the time");
    }

    /// The Distributor's Round Delay reads the timestamp, never the block number (#247).
    function test_clock_theDistributorReadsTimeOnly() public {
        Distributor d = new Distributor(keys, makeAddr("taxVault"));
        assertFalse(OpcodeScan.contains(address(d).code, OpcodeScan.NUMBER), "distributor");
        assertTrue(OpcodeScan.contains(address(d).code, OpcodeScan.TIMESTAMP), "the Round Delay reads the time");
    }

    function test_clock_theScanFindsNumberWhereItIs() public {
        assertTrue(OpcodeScan.contains(address(new ReadsBlockNumber()).code, OpcodeScan.NUMBER));
        assertTrue(OpcodeScan.contains(address(new ReadsBlockNumber()).code, OpcodeScan.TIMESTAMP));
    }
}

contract ReadsBlockNumber {
    function both() external view returns (uint256, uint256) {
        return (block.number, block.timestamp);
    }
}
