// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Walks deployed bytecode instruction by instruction, skipping PUSH data and the trailing CBOR
///         metadata, to say whether an opcode appears in the code itself.
library OpcodeScan {
    uint8 internal constant NUMBER = 0x43;
    uint8 internal constant TIMESTAMP = 0x42;

    function contains(bytes memory code, uint8 opcode) internal pure returns (bool) {
        uint256 end = code.length;
        // The compiler appends CBOR metadata whose length is in the last two bytes.
        if (end >= 2) {
            uint256 metaLen = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
            if (metaLen + 2 <= end) end -= metaLen + 2;
        }
        for (uint256 i; i < end; i++) {
            uint8 op = uint8(code[i]);
            if (op == opcode) return true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f; // PUSH1..PUSH32 data
        }
        return false;
    }
}
