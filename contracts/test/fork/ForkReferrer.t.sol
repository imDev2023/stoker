// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {ForkRouteBase} from "./ForkRouteBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// A swap naming a referrer and a Referrer Fee under the Listing's cap, through both Universal Routers on
/// the real PoolManager (#243): the referrer is credited that fee on top of the 1.00% Platform Fee, the V4
/// Quoter given the same hookData quotes it to the wei, and a fee over the cap reverts by name.
contract ForkReferrerTest is ForkRouteBase {
    address internal referrer = makeAddr("frontEnd");
    uint256 internal constant REF_BPS = 75; // 0.75%, under the cap of 1.00%

    function _assertReferredTrades(PoolKey memory key) internal {
        address[2] memory routers = [UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_V2_1_2];
        bytes memory hookData = _referral(referrer, REF_BPS);
        for (uint256 r; r < 2; r++) {
            uint256 snap = vm.snapshotState();
            _approveFor(routers[r], trader, key);
            for (uint256 i; i < 4; i++) {
                _assertReferredTrade(routers[r], key, _fourTrades(key)[i], hookData);
            }
            vm.revertToState(snap);
        }
    }

    function _assertReferredTrade(address router, PoolKey memory key, Trade memory t, bytes memory hookData) internal {
        uint256 ref0 = _creditIn(key, referrer);
        uint256 rb0 = _quoteBalance(key, referrer);
        (uint256 figure, Seen memory s) = _routeAndSee(router, key, t, hookData);

        // The Quoter's figure, given the same hookData, is what the router delivered, to the wei.
        if (t.exactIn) assertEq(t.buy ? s.coinsMoved : s.quoteMoved, figure, "exact in: the Quoter's output");
        else assertEq(t.buy ? s.quoteMoved : s.coinsMoved, figure, "exact out: the Quoter's input");

        (uint256 pf, uint256 rf) = _expectedFees(t, s);
        assertEq(_creditIn(key, referrer) - ref0, rf, "the Referrer Fee, credited to the referrer");
        assertEq(s.fee, pf + rf, "taken on top of the 1.00% Platform Fee");
        uint256 side = t.buy ? s.quoteMoved : s.quoteMoved + s.fee;
        assertApproxEqAbs(pf * 10_000, side * PLATFORM_FEE_BPS, 10_000, "the Platform Fee is 1.00% of the side");
        assertEq(_quoteBalance(key, referrer), rb0, "nothing paid to the referrer inside the swap");
    }

    /// Both fees are their rates of the Quote Asset's side, the Referrer Fee on top of the Platform Fee.
    function _expectedFees(Trade memory t, Seen memory s) internal pure returns (uint256 pf, uint256 rf) {
        uint256 total = PLATFORM_FEE_BPS + REF_BPS;
        if (t.buy && t.exactIn) {
            return (_feeOnGrossAt(t.amount, PLATFORM_FEE_BPS), _feeOnGrossAt(t.amount, REF_BPS));
        }
        if (t.buy) {
            uint256 net = s.quoteMoved - s.fee;
            return (_feeOnNetWith(net, PLATFORM_FEE_BPS, total), _feeOnNetWith(net, REF_BPS, total));
        }
        if (t.exactIn) {
            uint256 gross = s.quoteMoved + s.fee;
            return (_feeOnGrossAt(gross, PLATFORM_FEE_BPS), _feeOnGrossAt(gross, REF_BPS));
        }
        return (_feeOnNetWith(t.amount, PLATFORM_FEE_BPS, total), _feeOnNetWith(t.amount, REF_BPS, total));
    }

    function test_fork_referrer_nvda_quoteIsCurrency0_creditedAndQuoted() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        _assertReferredTrades(key);
    }

    function test_fork_referrer_nvda_quoteIsCurrency1_creditedAndQuoted() public {
        (, PoolKey memory key) = _launch(false, 1 ether);
        _assertReferredTrades(key);
    }

    function test_fork_referrer_native_creditedAndQuoted() public {
        (, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        _assertReferredTrades(key);
    }

    /// A fee over the Listing's cap reverts by name through either router, as the PoolManager wraps the
    /// hook's revert.
    function test_fork_referrer_feeOverTheCap_revertsByName() public {
        (, PoolKey memory nvda) = _launch(true, 1 ether);
        (, PoolKey memory native) = _launchNative(0.1 ether, address(0));
        PoolKey[2] memory keys_ = [nvda, native];
        address[2] memory routers = [UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_V2_1_2];
        uint256 over = REFERRER_FEE_CAP_BPS + 1;
        bytes memory expected = abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(StokerHook.ReferrerFeeOverCap.selector, over, REFERRER_FEE_CAP_BPS),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
        for (uint256 k; k < 2; k++) {
            for (uint256 r; r < 2; r++) {
                _approveFor(routers[r], trader, keys_[k]);
                Trade memory t = _fourTrades(keys_[k])[0];
                vm.expectRevert(expected);
                _route(routers[r], trader, keys_[k], t, 0, _referral(referrer, over));
            }
        }
    }
}
