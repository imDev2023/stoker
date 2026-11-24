// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {ForkRouteBase} from "./ForkRouteBase.sol";
import {RouterLib, IUniversalRouter} from "./RouterLib.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// @notice What the fork tests of Graduation and the Creator Lock share (#244): the three pairings, trades
///         through the Universal Router, and the coin's price read against its Graduation Target.
abstract contract ForkGraduationBase is ForkRouteBase {
    using StateLibrary for IPoolManager;

    /// The Universal Router's SWEEP command, and the address that stands for the router's caller.
    uint8 internal constant SWEEP = 0x04;
    address internal constant MSG_SENDER = address(1);

    // ------------------------------------------------ the pairings

    /// 0: NVDA with the coin as currency0; 1: NVDA as currency0; 2: native ETH (always currency0).
    function _launchPairing(uint256 pairing) internal returns (PoolKey memory key) {
        if (pairing == 2) (, key) = _launchNative(0, address(0));
        else (, key) = _launch(pairing == 1, 0);
    }

    /// Quote Asset that buys across the target from the start price, with room to spare: the spike review's
    /// 115 NVDA, and 7 ETH (the target needs about 86 NVDA and 5.8 ETH of net buying).
    function _crossing(PoolKey memory key) internal pure returns (uint256) {
        return _isNative(key) ? 7 ether : 115 ether;
    }

    function _dust(PoolKey memory key) internal pure returns (uint256) {
        return _isNative(key) ? 0.001 ether : 0.01 ether;
    }

    // ------------------------------------------------ the coin's price against the target

    function _graduation(PoolKey memory key) internal view returns (StokerHook.Graduation memory) {
        return hook.graduationOf(key.toId());
    }

    function _priceOf(PoolKey memory key) internal view returns (uint160 p) {
        (p,,,) = pm.getSlot0(key.toId());
    }

    function _atOrAbove(PoolKey memory key) internal view returns (bool) {
        StokerHook.Terms memory t = hook.termsOf(key.toId());
        uint160 p = _priceOf(key);
        return t.quoteIsCurrency0 ? p <= t.graduationSqrtPriceX96 : p >= t.graduationSqrtPriceX96;
    }

    // ------------------------------------------------ trades through a router, no slippage bound

    function _buy(address router, address who, PoolKey memory key, uint256 amount) internal {
        _route(router, who, key, Trade(true, true, amount), 0, "");
    }

    function _sellAll(address router, address who, PoolKey memory key) internal {
        _route(router, who, key, Trade(false, true, _coinOf(key).balanceOf(who)), 0, "");
    }

    /// One router call that buys `amount` across the target and sells every coin it bought straight back,
    /// in one unlock: the sell's amount is the router's open credit in the coin, and only the round trip's
    /// cost is settled. Native value left over is swept back to the caller.
    function _roundTripInOneCall(address router, address who, PoolKey memory key, uint256 amount) internal {
        bool buyZeroForOne = _zeroForOne(key, true);
        Currency q = _quoteOf(key);
        bytes memory actions =
            abi.encodePacked(RouterLib.SWAP_EXACT_IN_SINGLE, RouterLib.SWAP_EXACT_IN_SINGLE, RouterLib.SETTLE_ALL);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(RouterLib.ExactInputSingleParams(key, buyZeroForOne, uint128(amount), 0, 0, ""));
        // An amount in of zero is the router's OPEN_DELTA: everything it is owed in the coin, here all of it.
        params[1] = abi.encode(RouterLib.ExactInputSingleParams(key, !buyZeroForOne, 0, 0, 0, ""));
        params[2] = abi.encode(q, type(uint256).max);
        bytes[] memory inputs;
        bytes memory commands;
        if (_isNative(key)) {
            commands = abi.encodePacked(RouterLib.V4_SWAP, SWEEP);
            inputs = new bytes[](2);
            inputs[1] = abi.encode(address(0), MSG_SENDER, uint256(0));
        } else {
            commands = abi.encodePacked(RouterLib.V4_SWAP);
            inputs = new bytes[](1);
        }
        inputs[0] = abi.encode(actions, params);
        vm.prank(who);
        IUniversalRouter(router).execute{value: _isNative(key) ? amount : 0}(
            commands, inputs, vm.getBlockTimestamp() + 60
        );
    }
}
