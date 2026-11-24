// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Builds a Merkle tree the way OpenZeppelin's `MerkleProof` verifies one: each pair hashed in
///         sorted order, and the odd node at the end of a level carried up unchanged. It stands in for the
///         Reward Engine (#255), which builds each Round Root off-chain, so the tests post roots the
///         contract has never seen and prove claims against them.
library Merkle {
    /// @notice Every level of the tree, the leaves first and the root last.
    function levels(bytes32[] memory leaves) internal pure returns (bytes32[][] memory out) {
        require(leaves.length > 0, "no leaves");
        uint256 depth = 1;
        for (uint256 n = leaves.length; n > 1; n = (n + 1) / 2) {
            depth++;
        }
        out = new bytes32[][](depth);
        out[0] = leaves;
        for (uint256 d = 1; d < depth; d++) {
            bytes32[] memory below = out[d - 1];
            bytes32[] memory level = new bytes32[]((below.length + 1) / 2);
            for (uint256 i; i < below.length / 2; i++) {
                level[i] = hashPair(below[2 * i], below[2 * i + 1]);
            }
            if (below.length % 2 == 1) level[level.length - 1] = below[below.length - 1];
            out[d] = level;
        }
    }

    function root(bytes32[][] memory tree) internal pure returns (bytes32) {
        return tree[tree.length - 1][0];
    }

    /// @notice The proof of the leaf at `index`: its sibling at every level that has one.
    function proof(bytes32[][] memory tree, uint256 index) internal pure returns (bytes32[] memory p) {
        bytes32[] memory buf = new bytes32[](tree.length);
        uint256 len;
        for (uint256 d; d + 1 < tree.length; d++) {
            uint256 sibling = index ^ 1;
            if (sibling < tree[d].length) buf[len++] = tree[d][sibling];
            index /= 2;
        }
        p = new bytes32[](len);
        for (uint256 i; i < len; i++) {
            p[i] = buf[i];
        }
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
