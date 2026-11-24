// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "../utils/LocalBase.sol";
import {OpcodeScan} from "../utils/OpcodeScan.sol";
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
        // The Opening Fee (#246) reads the timestamp, in the hook's swap and in the vault's buys.
        assertTrue(OpcodeScan.contains(address(hook).code, OpcodeScan.TIMESTAMP), "the hook reads the time");
        assertTrue(OpcodeScan.contains(address(taxVault).code, OpcodeScan.TIMESTAMP), "the vault reads the time");
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
