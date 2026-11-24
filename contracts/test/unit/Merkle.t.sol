// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {Merkle} from "../utils/Merkle.sol";

/// The tests' tree is OpenZeppelin's `StandardMerkleTree` (#247): the root and proofs below were computed by
/// OpenZeppelin merkle-tree 1.0.8 (npm) from these six-field leaves, `StandardMerkleTree.of(values, ["uint256",
/// "address", "address", "uint256", "address", "uint256"])`, so the Reward Engine (#255) can build its roots
/// with that library and the Distributor's tests already prove claims against such roots.
contract MerkleTest is Test {
    function _leaf(uint256 i) internal pure returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        uint256(4663),
                        address(0x1111),
                        address(0x2222),
                        uint256(7),
                        address(uint160(0xa000 + i)),
                        1000 * (i + 1)
                    )
                )
            )
        );
    }

    function test_merkle_isStandardMerkleTree() public pure {
        bytes32[] memory leaves = new bytes32[](5);
        for (uint256 i; i < 5; i++) {
            leaves[i] = _leaf(i);
        }
        Merkle.Tree memory t = Merkle.build(leaves);
        assertEq(
            Merkle.root(t), 0x1944e800c1fb4bcb7304f0cf5a8186394547a486b10611692e95ae94bf9099e8, "the library's root"
        );

        bytes32[] memory p0 = Merkle.proof(t, 0);
        assertEq(p0.length, 2);
        assertEq(p0[0], 0xc743c6761438388834555e324901ee0602460c3ef736431c43f7894d6ae2c423);
        assertEq(p0[1], 0x77cf7eb7280c8b127eef3411b2d44fe76bb38fbce9aaca9d766ec4590dae0415);
        bytes32[] memory p3 = Merkle.proof(t, 3);
        assertEq(p3.length, 3);
        assertEq(p3[0], 0x92a912157e6f32f2ae8db0d046aa54fdb8e3cf189d0dc4c4407796f37a6e5276);
        assertEq(p3[1], 0xe40e9a914cd8010fb9607ec22ffd6a567c5adf7c40a05e8a97a3df8cb9d40a0d);
        assertEq(p3[2], 0x87f1599ed2a0020bbf0da22a4ccdc26afa2c3d42b04c77950a51af5b6d385c34);
        for (uint256 i; i < 5; i++) {
            assertTrue(MerkleProof.verify(Merkle.proof(t, i), Merkle.root(t), leaves[i]));
        }
    }

    /// The leaves sit in the tree sorted by hash, as the library places them, and every proof verifies.
    function testFuzz_merkle_sortsAndProves(uint256 seed, uint16 count) public pure {
        uint256 n = bound(count, 1, 300);
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i; i < n; i++) {
            leaves[i] = keccak256(abi.encode(seed, i));
        }
        Merkle.Tree memory t = Merkle.build(leaves);
        for (uint256 i = 1; i < n; i++) {
            // The leaf at node 2n - 2 - i is the i-th smallest.
            assertLt(uint256(t.nodes[2 * n - 2 - (i - 1)]), uint256(t.nodes[2 * n - 2 - i]));
        }
        for (uint256 i; i < n; i++) {
            assertTrue(MerkleProof.verify(Merkle.proof(t, i), Merkle.root(t), leaves[i]));
        }
    }
}
