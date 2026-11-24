// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";

/// The Admin is one address (ADR 0030): it is handed over only when the new address accepts, it replaces a
/// server key only when the new holder accepts, and the platform's share of every fee booked after a
/// handover is the new Admin's while every Credit booked before stays owed to the address it was booked to.
contract KeysTest is LocalBase {
    address internal nextAdmin = makeAddr("nextAdmin");
    address internal roundKey = makeAddr("roundKey");

    StokerKeys.Role[3] internal roles = [StokerKeys.Role.RoundKey, StokerKeys.Role.LadderKey, StokerKeys.Role.Keeper];

    function test_keys_theAdminIsTheDeployedAddress_noServerKeyYet() public view {
        assertEq(keys.admin(), platform);
        assertEq(keys.pendingAdmin(), address(0));
        for (uint256 i; i < roles.length; i++) {
            assertEq(keys.holderOf(roles[i]), address(0));
        }
    }

    function test_keys_refusesTheZeroAddressAsTheFirstAdmin() public {
        vm.expectRevert(StokerKeys.ZeroAddress.selector);
        new StokerKeys(address(0));
    }

    // ------------------------------------------------ the Admin's own handover

    function test_keys_adminHandover_needsTheNewAddressToAccept() public {
        vm.expectEmit(true, true, true, true, address(keys));
        emit StokerKeys.AdminProposed(platform, nextAdmin);
        vm.prank(platform);
        keys.proposeAdmin(nextAdmin);
        // Proposed, not handed over: the Admin is unchanged and still the only writer.
        assertEq(keys.admin(), platform);
        assertEq(keys.pendingAdmin(), nextAdmin);

        // Nobody but the proposed address accepts, the Admin included.
        address[3] memory others = [platform, stranger, creator];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(StokerKeys.NotProposed.selector);
            keys.acceptAdmin();
        }

        vm.expectEmit(true, true, true, true, address(keys));
        emit StokerKeys.AdminHandedOver(platform, nextAdmin);
        vm.prank(nextAdmin);
        keys.acceptAdmin();
        assertEq(keys.admin(), nextAdmin);
        assertEq(keys.pendingAdmin(), address(0));

        // The old Admin has no power left; the new one has it all.
        vm.prank(platform);
        vm.expectRevert(StokerKeys.NotAdmin.selector);
        keys.proposeAdmin(platform);
        vm.prank(platform);
        vm.expectRevert(QuoteRegistry.NotAdmin.selector);
        registry.list(address(0xA55E7), START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        vm.prank(nextAdmin);
        registry.list(address(0xA55E7), START_TICK, GRADUATION_MULTIPLE, REFERRER_FEE_CAP_BPS);
        assertTrue(registry.listingOf(address(0xA55E7)).listed);
    }

    function test_keys_adminHandover_onlyTheAdminProposes_andCanWithdrawIt() public {
        vm.prank(stranger);
        vm.expectRevert(StokerKeys.NotAdmin.selector);
        keys.proposeAdmin(stranger);

        vm.prank(platform);
        keys.proposeAdmin(nextAdmin);
        // A mistyped address is withdrawn by proposing another, or nobody.
        vm.prank(platform);
        keys.proposeAdmin(address(0));
        vm.prank(nextAdmin);
        vm.expectRevert(StokerKeys.NotProposed.selector);
        keys.acceptAdmin();
        assertEq(keys.admin(), platform);
    }

    // ------------------------------------------------ the server keys

    function test_keys_serverKey_replacedOnlyWhenTheNewHolderAccepts() public {
        for (uint256 i; i < roles.length; i++) {
            StokerKeys.Role role = roles[i];
            address first = makeAddr(string.concat("first", vm.toString(i)));
            address second = makeAddr(string.concat("second", vm.toString(i)));

            // Only the Admin proposes.
            vm.prank(stranger);
            vm.expectRevert(StokerKeys.NotAdmin.selector);
            keys.proposeKey(role, first);

            vm.expectEmit(true, true, true, true, address(keys));
            emit StokerKeys.KeyProposed(role, first);
            vm.prank(platform);
            keys.proposeKey(role, first);
            assertEq(keys.holderOf(role), address(0), "not held until accepted");
            assertEq(keys.pendingHolderOf(role), first);

            // Only the proposed address accepts, the Admin included.
            vm.prank(platform);
            vm.expectRevert(StokerKeys.NotProposed.selector);
            keys.acceptKey(role);
            vm.prank(second);
            vm.expectRevert(StokerKeys.NotProposed.selector);
            keys.acceptKey(role);

            vm.expectEmit(true, true, true, true, address(keys));
            emit StokerKeys.KeyReplaced(role, address(0), first);
            vm.prank(first);
            keys.acceptKey(role);
            assertEq(keys.holderOf(role), first);

            // A replacement: the old holder keeps the role until the new one accepts.
            vm.prank(platform);
            keys.proposeKey(role, second);
            assertEq(keys.holderOf(role), first, "the old holder until the new one accepts");
            vm.prank(second);
            keys.acceptKey(role);
            assertEq(keys.holderOf(role), second);
            assertEq(keys.pendingHolderOf(role), address(0));
        }
        // Each role is its own: three different holders.
        assertTrue(keys.holderOf(roles[0]) != keys.holderOf(roles[1]));
    }

    function test_keys_serverKey_acceptingOneRoleGivesNoOther() public {
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.RoundKey, roundKey);
        vm.prank(roundKey);
        vm.expectRevert(StokerKeys.NotProposed.selector);
        keys.acceptKey(StokerKeys.Role.LadderKey);
        vm.prank(roundKey);
        keys.acceptKey(StokerKeys.Role.RoundKey);
        assertEq(keys.holderOf(StokerKeys.Role.LadderKey), address(0));
    }

    /// A stolen server key is taken away at once: revoking hands the role to nobody, which the two steps
    /// exist to guard against only for a real address.
    function test_keys_serverKey_revokedAtOnceByTheAdminAlone() public {
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.RoundKey, roundKey);
        vm.prank(roundKey);
        keys.acceptKey(StokerKeys.Role.RoundKey);

        vm.prank(roundKey);
        vm.expectRevert(StokerKeys.NotAdmin.selector);
        keys.revokeKey(StokerKeys.Role.RoundKey);

        vm.expectEmit(true, true, true, true, address(keys));
        emit StokerKeys.KeyRevoked(StokerKeys.Role.RoundKey, roundKey);
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.RoundKey);
        assertEq(keys.holderOf(StokerKeys.Role.RoundKey), address(0));
    }

    function test_keys_serverKey_aRevokeAlsoWithdrawsAProposal() public {
        vm.prank(platform);
        keys.proposeKey(StokerKeys.Role.Keeper, roundKey);
        vm.prank(platform);
        keys.revokeKey(StokerKeys.Role.Keeper);
        vm.prank(roundKey);
        vm.expectRevert(StokerKeys.NotProposed.selector);
        keys.acceptKey(StokerKeys.Role.Keeper);
    }

    // ------------------------------------------------ the platform's share follows the Admin, forward only

    /// The platform's share is paid to the Admin's address (ADR 0030). A Credit is its owner's from the
    /// trade's own block and no key may move it (ADR 0025), so a handover changes only where the platform's
    /// share of later fees is booked: what the old Admin was owed stays owed to the old Admin.
    function test_keys_handover_platformCreditsBookedBeforeStayWithTheOldAdmin() public {
        (, PoolKey memory key) = _launch(true, 0);
        _swap(key, trader, true, true, 10 ether);
        uint256 before = _credit(platform);
        assertGt(before, 0);

        vm.prank(platform);
        keys.proposeAdmin(nextAdmin);
        // Proposed but not accepted: the platform's share is still booked to the current Admin.
        _swap(key, trader, true, true, 10 ether);
        uint256 beforeAcceptance = _credit(platform);
        assertGt(beforeAcceptance, before);
        assertEq(_credit(nextAdmin), 0);

        vm.prank(nextAdmin);
        keys.acceptAdmin();
        assertEq(_credit(platform), beforeAcceptance, "the handover moved no Credit");
        assertEq(hook.platform(), nextAdmin, "the hook names the Admin of the moment");

        uint256 fee = _feeOnGross(10 ether);
        _swap(key, trader, true, true, 10 ether);
        assertEq(_credit(platform), beforeAcceptance, "the old Admin's Credit is unchanged by later swaps");
        assertEq(_credit(nextAdmin), fee - fee * CREATOR_SHARE_BPS / 10_000, "later shares are the new Admin's");

        // The old Admin is still paid what it was owed, to itself and nobody else, by anyone's Payout Call.
        address[] memory owners = new address[](2);
        owners[0] = platform;
        owners[1] = nextAdmin;
        vm.prank(stranger);
        hook.payout(Currency.wrap(address(quote)), owners);
        assertEq(quote.balanceOf(platform), beforeAcceptance);
        assertEq(quote.balanceOf(nextAdmin), fee - fee * CREATOR_SHARE_BPS / 10_000);
        assertEq(_hookClaims(), _credit(creator));
    }
}
