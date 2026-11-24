// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {ForkGraduationBase} from "./ForkGraduationBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// The spike review's forced Graduation (`spike/evm-robinhood-fork/test/Review.t.sol`, test A), kept as a
/// regression that must now fail to graduate (#244): one wallet buys across the Graduation Target through the
/// Universal Router and sells every coin back, in the same block or in the same transaction, on the real
/// PoolManager. Under #231's first-touch rule the coin stayed graduated with nothing left in the pool; under
/// the Graduation Hold it never graduates.
/// forge-config: default.isolate = true
contract ForkGraduationRoundTripTest is ForkGraduationBase {
    address internal attacker = makeAddr("attacker");

    function _fund(PoolKey memory key) internal returns (uint256 start) {
        if (_isNative(key)) vm.deal(attacker, 100 ether);
        else deal(NVDA, attacker, 1_000 ether);
        _approveFor(UNIVERSAL_ROUTER, attacker, key);
        _approveFor(UNIVERSAL_ROUTER, trader, key);
        start = _quoteBalance(key, attacker);
    }

    /// An hour and more later, a swap and the public call still find no hold to graduate the coin by.
    function _assertNeverGraduates(PoolKey memory key) internal {
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _buy(UNIVERSAL_ROUTER, trader, key, _dust(key));
        assertEq(_graduation(key).graduatedAt, 0, "not graduated by the next swap");
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, 0));
        hook.graduate(key.toId());
    }

    function _sameBlock(uint256 pairing) internal {
        PoolKey memory key = _launchPairing(pairing);
        uint256 start = _fund(key);
        uint256 creatorBefore = _creditIn(key, creator);

        _buy(UNIVERSAL_ROUTER, attacker, key, _crossing(key));
        assertTrue(_atOrAbove(key), "the buy crossed the target");
        assertEq(_holdNow(key), vm.getBlockTimestamp(), "and started the hold");
        _sellAll(UNIVERSAL_ROUTER, attacker, key);
        assertFalse(_atOrAbove(key), "the sell went back under");
        assertEq(_holdNow(key), 0, "and cleared the hold in the same block");
        assertEq(_graduation(key).graduatedAt, 0, "not graduated");

        // The review's figures, as it logged them: what the round trip cost, half of the fees to the Creator.
        emit log_named_decimal_uint("Quote Asset spent to cross", _crossing(key), 18);
        emit log_named_decimal_uint("lost on the round trip", start - _quoteBalance(key, attacker), 18);
        emit log_named_decimal_uint("of which credited to the Creator", _creditIn(key, creator) - creatorBefore, 18);
        _assertNeverGraduates(key);
    }

    function _sameTransaction(uint256 pairing) internal {
        PoolKey memory key = _launchPairing(pairing);
        uint256 start = _fund(key);
        _roundTripInOneCall(UNIVERSAL_ROUTER, attacker, key, _crossing(key));
        assertEq(_coinOf(key).balanceOf(attacker), 0, "every coin bought was sold back");
        assertGt(start - _quoteBalance(key, attacker), 0, "the round trip cost its fees");
        assertFalse(_atOrAbove(key), "back under the target");
        assertEq(_holdNow(key), 0, "no hold survives the call");
        _assertNeverGraduates(key);
    }

    function test_fork_review_forcedGraduation_sameBlock_coinIsCurrency0() public {
        _sameBlock(0);
    }

    function test_fork_review_forcedGraduation_sameBlock_quoteIsCurrency0() public {
        _sameBlock(1);
    }

    function test_fork_review_forcedGraduation_sameBlock_native() public {
        _sameBlock(2);
    }

    function test_fork_review_forcedGraduation_sameTransaction_coinIsCurrency0() public {
        _sameTransaction(0);
    }

    function test_fork_review_forcedGraduation_sameTransaction_quoteIsCurrency0() public {
        _sameTransaction(1);
    }

    function test_fork_review_forcedGraduation_sameTransaction_native() public {
        _sameTransaction(2);
    }
}

/// The Graduation Hold on the real PoolManager, through both Universal Routers, in every pairing (#244):
/// 59 minutes does not graduate and an hour does, by the next swap or by the public call; a swap under the
/// target restarts the hour; and Graduation, once recorded, survives the price falling to the start.
/// forge-config: default.isolate = true
contract ForkGraduationHoldTest is ForkGraduationBase {
    function _start(uint256 pairing, address router) internal returns (PoolKey memory key, uint256 start) {
        key = _launchPairing(pairing);
        _approveFor(router, trader, key);
        _buy(router, trader, key, _crossing(key));
        start = vm.getBlockTimestamp();
        assertEq(_holdNow(key), start, "the hold runs");
    }

    function _byTheNextSwap(uint256 pairing) internal {
        address[2] memory routers = [UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_V2_1_2];
        for (uint256 r; r < 2; r++) {
            uint256 snap = vm.snapshotState();
            (PoolKey memory key, uint256 start) = _start(pairing, routers[r]);
            vm.warp(start + 59 minutes);
            _buy(routers[r], trader, key, _dust(key));
            assertEq(_graduation(key).graduatedAt, 0, "59 minutes");
            vm.warp(start + 1 hours);
            vm.expectEmit(true, false, false, true, address(hook));
            emit StokerHook.Graduated(key.toId(), start + 1 hours, start);
            _buy(routers[r], trader, key, _dust(key));
            assertEq(_graduation(key).graduatedAt, start + 1 hours, "the hour, by the next swap");
            vm.revertToState(snap);
        }
    }

    function _byThePublicCall(uint256 pairing) internal {
        (PoolKey memory key, uint256 start) = _start(pairing, UNIVERSAL_ROUTER);
        vm.warp(start + 59 minutes);
        vm.expectRevert(abi.encodeWithSelector(StokerHook.GraduationHoldNotComplete.selector, start));
        vm.prank(stranger);
        hook.graduate(key.toId());
        vm.warp(start + 1 hours);
        vm.prank(stranger);
        hook.graduate(key.toId());
        assertEq(_graduation(key).graduatedAt, start + 1 hours, "the hour, by anyone's call");
    }

    function _restarts(uint256 pairing) internal {
        (PoolKey memory key, uint256 first) = _start(pairing, UNIVERSAL_ROUTER);
        vm.warp(first + 30 minutes);
        _sellAll(UNIVERSAL_ROUTER, trader, key);
        assertEq(_holdNow(key), 0, "a sell under the target clears it");
        _buy(UNIVERSAL_ROUTER, trader, key, _crossing(key));
        uint256 second = first + 30 minutes;
        assertEq(_holdNow(key), second, "the hour starts again");

        vm.warp(first + 1 hours);
        _buy(UNIVERSAL_ROUTER, trader, key, _dust(key));
        assertEq(_graduation(key).graduatedAt, 0, "an hour after the first start is not an hour held");
        vm.warp(second + 1 hours);
        _buy(UNIVERSAL_ROUTER, trader, key, _dust(key));
        assertEq(_graduation(key).graduatedAt, second + 1 hours, "an hour after the second");
    }

    function _survives(uint256 pairing) internal {
        PoolKey memory key = _launchPairing(pairing);
        uint160 openPrice = _priceOf(key);
        _approveFor(UNIVERSAL_ROUTER, trader, key);
        _buy(UNIVERSAL_ROUTER, trader, key, _crossing(key));
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 1 hours);
        hook.graduate(key.toId());
        uint256 graduatedAt = _graduation(key).graduatedAt;

        _sellAll(UNIVERSAL_ROUTER, trader, key);
        assertApproxEqRel(_priceOf(key), openPrice, 1e9, "back at the start price");
        assertFalse(_atOrAbove(key), "under the target");
        assertEq(_graduation(key).graduatedAt, graduatedAt, "still graduated");

        _buy(UNIVERSAL_ROUTER, trader, key, _crossing(key));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        _buy(UNIVERSAL_ROUTER, trader, key, _dust(key));
        vm.expectRevert(StokerHook.AlreadyGraduated.selector);
        hook.graduate(key.toId());
        assertEq(_graduation(key).graduatedAt, graduatedAt, "its timestamp never changes");
        assertEq(_graduation(key).holdSince, start, "nor the hold that graduated it");
    }

    function test_fork_hold_anHourByTheNextSwap_coinIsCurrency0() public {
        _byTheNextSwap(0);
    }

    function test_fork_hold_anHourByTheNextSwap_quoteIsCurrency0() public {
        _byTheNextSwap(1);
    }

    function test_fork_hold_anHourByTheNextSwap_native() public {
        _byTheNextSwap(2);
    }

    function test_fork_hold_anHourByThePublicCall_coinIsCurrency0() public {
        _byThePublicCall(0);
    }

    function test_fork_hold_anHourByThePublicCall_quoteIsCurrency0() public {
        _byThePublicCall(1);
    }

    function test_fork_hold_anHourByThePublicCall_native() public {
        _byThePublicCall(2);
    }

    function test_fork_hold_aSwapUnderTheTargetRestartsTheHour_coinIsCurrency0() public {
        _restarts(0);
    }

    function test_fork_hold_aSwapUnderTheTargetRestartsTheHour_quoteIsCurrency0() public {
        _restarts(1);
    }

    function test_fork_hold_aSwapUnderTheTargetRestartsTheHour_native() public {
        _restarts(2);
    }

    function test_fork_graduation_survivesTheFallToTheStart_coinIsCurrency0() public {
        _survives(0);
    }

    function test_fork_graduation_survivesTheFallToTheStart_quoteIsCurrency0() public {
        _survives(1);
    }

    function test_fork_graduation_survivesTheFallToTheStart_native() public {
        _survives(2);
    }
}
