// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ForkBase} from "./Base.t.sol";
import {StokerHook} from "../src/StokerHook.sol";

/// @notice #234 point 7: the hook reads time only, never `block.number`, which on Robinhood Chain
///         is an estimate of the L1 block number shared by about 120 consecutive L2 blocks.
contract ClockTest is ForkBase {
    using PoolIdLibrary for PoolKey;

    uint8 internal constant OP_NUMBER = 0x43;
    uint8 internal constant OP_TIMESTAMP = 0x42;
    /// @dev `l1BlockNumber` in the header of L2 block 120,800,000 (eth_getBlockByNumber, Alchemy).
    uint256 internal constant L1_BLOCK_AT_FORK = 26_472_290;

    /// @dev Walks EVM bytecode as instructions, skipping PUSH operands and the trailing CBOR
    ///      metadata, and counts one opcode.
    function _count(bytes memory code, uint8 op) internal pure returns (uint256 n) {
        uint256 metaLen = (uint256(uint8(code[code.length - 2])) << 8) | uint8(code[code.length - 1]);
        uint256 end = code.length - metaLen - 2;
        for (uint256 i; i < end; i++) {
            uint8 b = uint8(code[i]);
            if (b == op) n++;
            if (b >= 0x60 && b <= 0x7f) i += b - 0x5f; // PUSH1..PUSH32 carry 1..32 bytes of data
        }
    }

    /// The deployed hook, factory and coin contain no NUMBER instruction at all, and the hook does
    /// read TIMESTAMP. This is a property of the runtime, not of a test run, so it holds on the
    /// live chain where a fork cannot reproduce Nitro's `block.number`.
    function test_clock_noBlockNumberInRuntime() public {
        (address coin,) = _launch(_params(true));
        assertEq(_count(address(hook).code, OP_NUMBER), 0, "hook reads no block.number");
        assertEq(_count(address(factory).code, OP_NUMBER), 0, "factory reads no block.number");
        assertEq(_count(coin.code, OP_NUMBER), 0, "coin reads no block.number");
        assertGt(_count(address(hook).code, OP_TIMESTAMP), 0, "hook reads block.timestamp");
    }

    /// The scanner is load-bearing: it finds NUMBER in a contract that does read block.number.
    function test_clock_scannerFindsNumber() public {
        BlockNumberReader r = new BlockNumberReader();
        assertGt(_count(address(r).code, OP_NUMBER), 0);
    }

    /// Behaviour agrees: the same trades under wildly different `block.number` values and the
    /// same timestamps give the same result, and Graduation is stamped with the timestamp.
    function test_clock_blockNumberChangesNothing() public {
        (, PoolKey memory a) = _launch(_params(true));
        uint256 snap = vm.snapshotState();
        vm.roll(block.number + 5_000_000);
        _swap(a, trader, true, true, 150 ether, "");
        StokerHook.State memory s1 = hook.state(a.toId());
        uint256 got1 = _coin(a).balanceOf(trader);
        vm.revertToState(snap);
        vm.roll(26_000_000); // about what `block.number` reads on the live chain (an L1 estimate)
        _swap(a, trader, true, true, 150 ether, "");
        StokerHook.State memory s2 = hook.state(a.toId());
        assertEq(_coin(a).balanceOf(trader), got1);
        assertEq(s1.graduatedAt, s2.graduatedAt);
        assertTrue(s2.graduated);
        assertEq(s2.graduatedAt, block.timestamp);
    }

    /// What a fork reproduces, measured here. Foundry forks Robinhood Chain with `block.number` set
    /// to the forked header's `l1BlockNumber` (26,472,290 at L2 block 120,800,000), so a fork test
    /// does see Nitro's L1 estimate rather than the L2 height. The ArbSys precompile's code on the
    /// chain is the 0xfe stub, yet Foundry answers `arbBlockNumber()` itself with an L2 height,
    /// so a hook that used ArbSys would also run on a fork; `vm.roll` does not move that answer.
    function test_clock_forkReportsTheL1Estimate() public {
        assertEq(block.number, L1_BLOCK_AT_FORK, "block.number is the header's l1BlockNumber");
        assertTrue(block.number != FORK_BLOCK, "not the L2 height");
        assertEq(address(0x64).code, hex"fe", "ArbSys is a stub in the chain's state");
        (bool ok, bytes memory ret) = address(0x64).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        assertTrue(ok, "Foundry emulates ArbSys");
        uint256 l2 = abi.decode(ret, (uint256));
        emit log_named_uint("ArbSys.arbBlockNumber() on the fork", l2);
        assertEq(l2, FORK_BLOCK, "the forked L2 height");
        // vm.roll moves block.number but not Foundry's ArbSys answer.
        vm.roll(block.number + 7);
        (, ret) = address(0x64).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        assertEq(abi.decode(ret, (uint256)), FORK_BLOCK, "ArbSys does not follow vm.roll");
    }
}

contract BlockNumberReader {
    function read() external view returns (uint256) {
        return block.number;
    }
}
