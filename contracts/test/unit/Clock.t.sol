// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "../utils/LocalBase.sol";
import {OpcodeScan} from "../utils/OpcodeScan.sol";

/// The contracts read time only, never `block.number`, which on Robinhood Chain and Arbitrum is an
/// estimate of the L1 block (the security standards' robinhood-4663 profile, question 1).
contract ClockTest is LocalBase {
    function test_clock_noBlockNumberInAnyRuntime() public {
        (address coin,) = _launch(true, 0);
        assertFalse(OpcodeScan.contains(address(hook).code, OpcodeScan.NUMBER), "hook");
        assertFalse(OpcodeScan.contains(address(factory).code, OpcodeScan.NUMBER), "factory");
        assertFalse(OpcodeScan.contains(coin.code, OpcodeScan.NUMBER), "coin");
        assertFalse(OpcodeScan.contains(address(listings).code, OpcodeScan.NUMBER), "listing stand-in");
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
