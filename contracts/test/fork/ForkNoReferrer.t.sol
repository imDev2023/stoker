// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkRouteBase} from "./ForkRouteBase.sol";

/// A swap naming no referrer costs the trader exactly what it did before the Referrer Fee existed (#243),
/// through both Universal Routers, on the real PoolManager: the four trades in NVDA in both currency
/// orders and in native ETH, at the V4 Quoter's figure, against figures recorded from `main` at ce0975a
/// (the contracts of 242af52) before the hook changed. Each row is the Quoter's figure, the Quote Asset
/// the trader paid or received, the coins received or paid, and what the hook took.
contract ForkNoReferrerTest is ForkRouteBase {
    function _assertBothRouters(PoolKey memory key, uint256[4][4] memory recorded) internal {
        address[2] memory routers = [UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_V2_1_2];
        for (uint256 r; r < 2; r++) {
            uint256 snap = vm.snapshotState();
            _approveFor(routers[r], trader, key);
            for (uint256 i; i < 4; i++) {
                _assertTrade(routers[r], key, _fourTrades(key)[i], recorded[i]);
            }
            vm.revertToState(snap);
        }
    }

    function _assertTrade(address router, PoolKey memory key, Trade memory t, uint256[4] memory recorded) internal {
        (uint256 figure, Seen memory s) = _routeAndSee(router, key, t, "");
        assertEq(figure, recorded[0], "the Quoter's figure");
        assertEq(s.quoteMoved, recorded[1], "the Quote Asset the trader paid or received");
        assertEq(s.coinsMoved, recorded[2], "the coins the trader received or paid");
        assertEq(s.fee, recorded[3], "what the hook took");
    }

    function test_fork_noReferrer_nvda_quoteIsCurrency0_costsWhatItDidBefore() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _assertBothRouters(
            key,
            [
                [
                    uint256(266495690144372810211535404599),
                    10000000000000000000,
                    266495690144372810211535404599,
                    100000000000000000
                ],
                [uint256(526666613974452258), 526666613974452258, 10000000000000000000000000000, 5266666139744523],
                [uint256(516185948356360656), 516185948356360656, 10000000000000000000000000000, 5213999478347078],
                [
                    uint256(41667479922258564195014969389),
                    2000000000000000000,
                    41667479922258564195014969389,
                    20202020202020203
                ]
            ]
        );
    }

    function test_fork_noReferrer_nvda_quoteIsCurrency1_costsWhatItDidBefore() public {
        (, PoolKey memory key) = _launch(false, 1 ether);
        _assertBothRouters(
            key,
            [
                [
                    uint256(266495690144372810211534773869),
                    10000000000000000000,
                    266495690144372810211534773869,
                    100000000000000000
                ],
                [uint256(526666613974452258), 526666613974452258, 10000000000000000000000000000, 5266666139744523],
                [uint256(516185948356360656), 516185948356360656, 10000000000000000000000000000, 5213999478347078],
                [
                    uint256(41667479922258564195015894492),
                    2000000000000000000,
                    41667479922258564195015894492,
                    20202020202020203
                ]
            ]
        );
    }

    function test_fork_noReferrer_native_costsWhatItDidBefore() public {
        (, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        _assertBothRouters(
            key,
            [
                [
                    uint256(338827510871955966874821686543),
                    1000000000000000000,
                    338827510871955966874821686543,
                    10000000000000000
                ],
                [uint256(46810910526937819), 46810910526937819, 10000000000000000000000000000, 468109105269379],
                [uint256(45879373407451754), 45879373407451754, 10000000000000000000000000000, 463428014216685],
                [
                    uint256(11287936636079240158844992599),
                    50000000000000000,
                    11287936636079240158844992599,
                    505050505050506
                ]
            ]
        );
    }
}
