// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LocalBase} from "../utils/LocalBase.sol";

/// Many Launches share one hook: each swap books to its own Launch's Creator, and the claims back the
/// sum of every Credit across them.
contract SharedHookTest is LocalBase {
    function test_sharedHook_eachPoolBooksToItsOwnCreator() public {
        (, PoolKey memory keyA) = _launch(true, 0);
        address creatorA = creator;
        (creator, creatorKey) = makeAddrAndKey("creatorB");
        mockQuote.mint(creator, 10 ether);
        (, PoolKey memory keyB) = _launch(false, 0);
        address creatorB = creator;

        for (uint256 i; i < 3; i++) {
            _swap(keyA, trader, true, true, 7 ether);
            _swap(keyB, trader, true, true, 3 ether);
        }
        uint256 feeA = 3 * _feeOnGross(7 ether);
        uint256 feeB = 3 * _feeOnGross(3 ether);
        assertEq(_credit(creatorA), 3 * (_feeOnGross(7 ether) * CREATOR_SHARE_BPS / 10_000));
        assertEq(_credit(creatorB), 3 * (_feeOnGross(3 ether) * CREATOR_SHARE_BPS / 10_000));
        assertEq(_hookClaims(), feeA + feeB, "claims back every Credit");
        assertEq(_credit(creatorA) + _credit(creatorB) + _credit(platform), feeA + feeB);
    }
}
