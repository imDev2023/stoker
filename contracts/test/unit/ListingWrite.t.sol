// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LocalBase} from "../utils/LocalBase.sol";
import {ListingMath, ListingWrite} from "../../script/ListingWrite.s.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// The tool that prepares the Admin's registry writes (ADR 0028): the start tick for an Opening Value, and
/// calldata the registry takes when the Admin sends it.
contract ListingWriteTest is LocalBase {
    function test_listingMath_startTickForAnOpeningValue() public pure {
        // $5,000 of a six-decimal dollar (USDG) for the whole supply.
        assertEq(ListingMath.startTickFor(5e9, 200), -467_400);
        // 24.8 of an 18-decimal asset: the local tests' NVDA figure.
        assertEq(ListingMath.startTickFor(24.8e18, 200), -244_200);
        // On a spacing of 1 the tick is the price's own, to the nearest.
        assertEq(ListingMath.startTickFor(1e30, 1), 0, "the whole supply worth itself: price 1");
    }

    function test_listingWrite_preparesCalldataTheRegistryTakes() public {
        ListingWrite tool = new ListingWrite();
        vm.setEnv("OPENING_VALUE", "5000000000");
        vm.setEnv("MULTIPLE", "20");
        vm.setEnv("CAP_BPS", "100");
        address usdg = address(0x5fC5);
        (address to, bytes memory data) = tool.prepare(registry, "list", usdg);
        assertEq(to, address(registry));
        vm.prank(platform);
        (bool ok,) = to.call(data);
        assertTrue(ok, "the Admin's write goes through");
        assertEq(registry.listingOf(usdg).startTick, -467_400);
        assertEq(registry.listingOf(usdg).graduationMultiple, 20);

        // A routine write the tool refuses to prepare beyond 25%, and one it prepares within.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.setEnv("OPENING_VALUE", "10000000000");
        vm.expectRevert(bytes("over 25% from the start price in force: schedule it instead"));
        tool.prepare(registry, "write", usdg);
        vm.setEnv("OPENING_VALUE", "6000000000");
        (to, data) = tool.prepare(registry, "write", usdg);
        vm.prank(platform);
        (ok,) = to.call(data);
        assertTrue(ok);
        assertEq(registry.listingOf(usdg).startTick, ListingMath.startTickFor(6e9, 200));

        // A figure too large for its field is refused, never wrapped into another valid Listing
        // (65,636 would wrap to a cap of 100; 65,556 to a multiple of 20).
        vm.setEnv("CAP_BPS", "65636");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 16, 65_636));
        tool.prepare(registry, "schedule", usdg);
        vm.setEnv("CAP_BPS", "100");
        vm.setEnv("MULTIPLE", "65556");
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 16, 65_556));
        tool.prepare(registry, "schedule", usdg);

        (, data) = tool.prepare(registry, "delist", usdg);
        assertEq(data, abi.encodeCall(QuoteRegistry.delist, (usdg)));
    }
}
