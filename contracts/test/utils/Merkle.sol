// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Builds a Merkle tree exactly as OpenZeppelin's `StandardMerkleTree.of` does (merkle-tree 1.x),
///         the format the Reward Engine (#255) builds each Round Root in: the leaves sorted by their hash,
///         laid out as a complete binary tree in one array (node `i`'s children at `2i + 1` and `2i + 2`,
///         the root at 0, the sorted leaves at the end in reverse), each pair hashed in sorted order. The
///         same leaves give the same root and the same proofs as the library (`test_merkle_isStandardMerkleTree`
///         pins one), so the tests post roots in the format the Distributor will really be given.
library Merkle {
    struct Tree {
        bytes32[] nodes;
        /// Where each leaf, by its index in the input, sits among the nodes.
        uint256[] positionOf;
    }

    function build(bytes32[] memory leaves) internal pure returns (Tree memory t) {
        uint256 n = leaves.length;
        require(n > 0, "no leaves");
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; i++) {
            order[i] = i;
        }
        _sort(leaves, order, 0, n);
        t.nodes = new bytes32[](2 * n - 1);
        t.positionOf = new uint256[](n);
        for (uint256 i; i < n; i++) {
            uint256 position = 2 * n - 2 - i;
            t.nodes[position] = leaves[order[i]];
            t.positionOf[order[i]] = position;
        }
        for (uint256 i = n - 1; i > 0; i--) {
            t.nodes[i - 1] = hashPair(t.nodes[2 * i - 1], t.nodes[2 * i]);
        }
    }

    function root(Tree memory t) internal pure returns (bytes32) {
        return t.nodes[0];
    }

    /// @notice The proof of the leaf given at `index`: its sibling at every level, from the leaf up.
    function proof(Tree memory t, uint256 index) internal pure returns (bytes32[] memory p) {
        uint256 position = t.positionOf[index];
        uint256 len;
        for (uint256 q = position; q > 0; q = (q - 1) / 2) {
            len++;
        }
        p = new bytes32[](len);
        uint256 k;
        while (position > 0) {
            p[k++] = t.nodes[position % 2 == 1 ? position + 1 : position - 1];
            position = (position - 1) / 2;
        }
    }

    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Sorts `order[lo, hi)` by the leaf each names, ascending (a quicksort; the gas test sorts 16,384).
    function _sort(bytes32[] memory leaves, uint256[] memory order, uint256 lo, uint256 hi) private pure {
        while (hi - lo > 1) {
            // Lomuto: the middle element as the pivot, moved to the end, then put between the two sides.
            uint256 mid = (lo + hi) / 2;
            (order[mid], order[hi - 1]) = (order[hi - 1], order[mid]);
            bytes32 pivot = leaves[order[hi - 1]];
            uint256 store = lo;
            for (uint256 k = lo; k < hi - 1; k++) {
                if (leaves[order[k]] < pivot) {
                    (order[k], order[store]) = (order[store], order[k]);
                    store++;
                }
            }
            (order[store], order[hi - 1]) = (order[hi - 1], order[store]);
            // Recurse into the smaller side, loop on the larger, so the depth stays logarithmic.
            if (store - lo < hi - store - 1) {
                _sort(leaves, order, lo, store);
                lo = store + 1;
            } else {
                _sort(leaves, order, store + 1, hi);
                hi = store;
            }
        }
    }
}
