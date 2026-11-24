// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkGraduationBase} from "./ForkGraduationBase.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerCreatorLock} from "../../src/StokerCreatorLock.sol";

/// The Creator Lock on the real PoolManager, in every pairing (#244): a lock of a fifth seeds four fifths; a
/// lock above a fifth, or shorter than seven days, reverts; nothing is claimed before Graduation, and after it
/// the Creator alone claims exactly what the schedule has released.
contract ForkCreatorLockTest is ForkGraduationBase {
    uint16 internal constant A_FIFTH = 2_000;
    uint256 internal _n;

    function _lockedParams(uint256 pairing, uint16 bps, uint32 cliff, uint32 unlock)
        internal
        returns (StokerFactory.LaunchParams memory p)
    {
        if (pairing == 2) {
            p = _nativeParams(0, address(0));
        } else {
            p = _params(pairing == 1, 0);
            p.name = string.concat("Locked ", vm.toString(++_n));
            p.salt = _saltFor(pairing == 1, creator, p.name, p.symbol);
        }
        p.creatorLockBps = bps;
        p.creatorLockCliff = cliff;
        p.creatorLockUnlock = unlock;
    }

    function _keyOf(uint256 pairing, address coin) internal view returns (PoolKey memory) {
        return pairing == 2 ? _nativeKey(coin) : _keyFor(coin);
    }

    function _aFifthSeedsFourFifths(uint256 pairing) internal {
        vm.prank(creator);
        (address coin, PoolId id) = factory.launch(_lockedParams(pairing, A_FIFTH, 7 days, 23 days));
        PoolKey memory key = _keyOf(pairing, coin);
        StokerCreatorLock lock = StokerCreatorLock(factory.creatorLockOf(id));
        IERC20 c = IERC20(coin);
        assertEq(c.balanceOf(address(lock)), SUPPLY / 5, "a fifth in the lock");
        assertEq(c.balanceOf(address(pm)) + SUPPLY / 5, c.totalSupply(), "the rest in the pool");
        assertLe(c.balanceOf(address(pm)), SUPPLY * 4 / 5, "four fifths seeded");
        assertLe(SUPPLY - c.totalSupply(), 1e12, "only the seed's dust burned");

        // Nothing before Graduation; then the Creator alone claims what the schedule released.
        _approveFor(UNIVERSAL_ROUTER, trader, key);
        _buy(UNIVERSAL_ROUTER, trader, key, _crossing(key));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.expectRevert(StokerCreatorLock.NotGraduated.selector);
        vm.prank(creator);
        lock.claim();
        hook.graduate(id);
        uint256 g = _graduation(key).graduatedAt;

        vm.warp(g + 7 days + 23 days / 2);
        vm.expectRevert(StokerCreatorLock.NotCreator.selector);
        vm.prank(platform);
        lock.claim();
        vm.prank(creator);
        assertEq(lock.claim(), SUPPLY / 5 * (23 days / 2) / 23 days, "half the unlock time, half the lock");
        vm.warp(g + 30 days);
        vm.prank(creator);
        lock.claim();
        assertEq(c.balanceOf(creator), SUPPLY / 5, "all of it, to the Creator");
        assertEq(c.balanceOf(address(lock)), 0);
    }

    function _outOfBounds(uint256 pairing) internal {
        uint32[2][3] memory bad = [[uint32(7 days), uint32(0)], [uint32(3 days), uint32(4 days - 1)], [uint32(0), 0]];
        uint16[3] memory bps = [A_FIFTH + 1, A_FIFTH, A_FIFTH];
        for (uint256 i; i < 3; i++) {
            StokerFactory.LaunchParams memory p = _lockedParams(pairing, bps[i], bad[i][0], bad[i][1]);
            vm.expectRevert(
                abi.encodeWithSelector(StokerFactory.InvalidCreatorLock.selector, bps[i], bad[i][0], bad[i][1])
            );
            vm.prank(creator);
            factory.launch(p);
        }
    }

    function test_fork_lock_aFifthSeedsFourFifths_andPaysTheCreatorBySchedule_coinIsCurrency0() public {
        _aFifthSeedsFourFifths(0);
    }

    function test_fork_lock_aFifthSeedsFourFifths_andPaysTheCreatorBySchedule_quoteIsCurrency0() public {
        _aFifthSeedsFourFifths(1);
    }

    function test_fork_lock_aFifthSeedsFourFifths_andPaysTheCreatorBySchedule_native() public {
        _aFifthSeedsFourFifths(2);
    }

    function test_fork_lock_overAFifthOrUnderSevenDays_reverts() public {
        _outOfBounds(0);
        _outOfBounds(1);
        _outOfBounds(2);
    }
}
