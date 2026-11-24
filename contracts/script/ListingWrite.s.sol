// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {QuoteRegistry} from "../src/QuoteRegistry.sol";

/// @notice The arithmetic of a Listing's start price (ADR 0024, ADR 0028).
library ListingMath {
    /// @notice Every coin's supply in raw units: 1 trillion at 18 decimals.
    uint256 internal constant SUPPLY = 1e12 * 1e18;

    /// @notice The start tick at which the whole supply is worth `openingValue` raw units of the Quote
    ///         Asset (5e9 for $5,000 of a six-decimal dollar), on the registry's tick spacing, rounded to the
    ///         nearest one (a spacing of 200 is a step of about 2%).
    function startTickFor(uint256 openingValue, int24 tickSpacing) internal pure returns (int24) {
        // sqrt(price) * 2^96, where price = openingValue / SUPPLY per raw unit of the coin.
        uint160 sqrtPrice = uint160(Math.sqrt(FullMath.mulDiv(openingValue, uint256(1) << 192, SUPPLY)));
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPrice);
        int24 below = tick - (((tick % tickSpacing) + tickSpacing) % tickSpacing);
        return 2 * (tick - below) >= tickSpacing ? below + tickSpacing : below;
    }
}

/// @title ListingWrite
/// @notice Prepares one Quote Registry write for the Admin's hardware wallet to sign (ADR 0028: the Admin
///         signs every write by hand, so the tool that prepares them is part of the registry's slice). It
///         reads the Listing in force, computes the start tick from an Opening Value, checks the write
///         against the registry's own bounds where it can, and prints the target and the calldata. It sends
///         nothing and holds no key.
/// @dev    REGISTRY=0x... ACTION=list|write|schedule|withdraw|delist QUOTE=0x... (0x0 for the native asset)
///         OPENING_VALUE=<raw units of the Quote Asset for the whole supply> MULTIPLE=20 CAP_BPS=100
///         forge script script/ListingWrite.s.sol --rpc-url <chain>
///         `write` takes OPENING_VALUE alone; `withdraw` and `delist` take QUOTE alone.
contract ListingWrite is Script {
    function run() external view returns (address target, bytes memory data) {
        QuoteRegistry registry = QuoteRegistry(vm.envAddress("REGISTRY"));
        string memory action = vm.envString("ACTION");
        address quote = vm.envAddress("QUOTE");
        (target, data) = prepare(registry, action, quote);
        console2.log("Admin:", registry.keys().admin());
        console2.log("to:", target);
        console2.log("data:");
        console2.logBytes(data);
    }

    function prepare(QuoteRegistry registry, string memory action, address quote)
        public
        view
        returns (address, bytes memory data)
    {
        bytes32 a = keccak256(bytes(action));
        if (a == keccak256("withdraw")) return (address(registry), abi.encodeCall(registry.withdrawChange, (quote)));
        if (a == keccak256("delist")) return (address(registry), abi.encodeCall(registry.delist, (quote)));

        int24 tick = ListingMath.startTickFor(vm.envUint("OPENING_VALUE"), registry.tickSpacing());
        console2.log("start tick:", tick);
        if (a == keccak256("write")) {
            int24 current = registry.listingOf(quote).startTick;
            require(
                tick <= current + registry.MAX_TICKS_UP() && tick >= current - registry.MAX_TICKS_DOWN(),
                "over 25% from the start price in force: schedule it instead"
            );
            console2.log("next write allowed at:", registry.lastWriteAt(quote) + registry.WRITE_INTERVAL());
            return (address(registry), abi.encodeCall(registry.writeStartPrice, (quote, tick)));
        }
        uint16 multiple = uint16(vm.envUint("MULTIPLE"));
        uint16 cap = uint16(vm.envUint("CAP_BPS"));
        if (a == keccak256("list")) {
            return (address(registry), abi.encodeCall(registry.list, (quote, tick, multiple, cap)));
        }
        require(a == keccak256("schedule"), "ACTION is list, write, schedule, withdraw or delist");
        return (address(registry), abi.encodeCall(registry.scheduleChange, (quote, tick, multiple, cap)));
    }
}
