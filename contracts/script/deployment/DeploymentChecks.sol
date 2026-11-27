// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StokerDeployer} from "./StokerDeployer.sol";
import {StokerKeys} from "../../src/StokerKeys.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {Distributor} from "../../src/Distributor.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {BurnDestination} from "../../src/destinations/BurnDestination.sol";
import {LiquidityDestination} from "../../src/destinations/LiquidityDestination.sol";
import {HoldersDestination} from "../../src/destinations/HoldersDestination.sol";

/// @title DeploymentChecks
/// @notice What the deployment's gate asserts on the chain (#251): everything a wrong constructor argument
///         would leave for good, and what nothing in the contracts checks. Run inside `Deploy.s.sol`'s
///         simulation before a transaction is sent, and by `CheckDeployment.s.sol` against the chain after
///         them, at any later time.
///
///         It proves that the nine contracts name each other, that every setting is the chain file's, that
///         the figures the ADRs fix are those figures, that the hook's address carries exactly its permission
///         bits, that the roles are kept apart, and that eight of the nine run this build's code. It does not
///         prove the factory's runtime code (see `_checkCode`), that the Admin's address is a hardware wallet
///         (only its owner can), or anything about a Listing.
/// @dev Every check is counted and printed; the run fails at the end, so one run names every failure.
abstract contract DeploymentChecks is StokerDeployer {
    /// @notice The figures ADR 0020, 0025, 0027, 0024 and 0029 fix for every chain, read from
    ///         `script/config/decided.json`: no chain's file may carry another, whatever it says.
    struct Decided {
        uint16 platformFeeBps;
        uint16 creatorShareBps;
        uint16 secondTierShareBps;
        uint16 topTierShareBps;
        uint16 pieceBps;
        uint256 roundDelay;
        uint256 graduationHold;
    }

    /// @notice How far the server keys must be appointed for the check to pass.
    enum KeysExpected {
        /// Straight after the deployment: a role nobody holds yet is said, not failed.
        MayBeUnappointed,
        /// Before any Launch: the round key, the ladder key and the Keeper are each held.
        AllAppointed
    }

    error DeploymentChecksFailed(uint256 failures);

    string[] internal _failures;
    uint256 internal _checksMade;
    bool internal _quietChecks;

    function _loadDecided(string memory path) internal view returns (Decided memory f) {
        string memory json = vm.readFile(path);
        f.platformFeeBps = SafeCast.toUint16(vm.parseJsonUint(json, ".platformFeeBps"));
        f.creatorShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".creatorShareBps"));
        f.secondTierShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".secondTierShareBps"));
        f.topTierShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".topTierShareBps"));
        f.pieceBps = SafeCast.toUint16(vm.parseJsonUint(json, ".pieceBps"));
        f.roundDelay = vm.parseJsonUint(json, ".roundDelay");
        f.graduationHold = vm.parseJsonUint(json, ".graduationHold");
    }

    /// @notice Every check, in one pass. Reverts with the number that failed, each named in the log and in
    ///         `_failures`.
    function _checkDeployment(
        Settings memory s,
        Decided memory f,
        Deployment memory d,
        address deployer,
        KeysExpected keysExpected
    ) internal {
        uint256 failures = _runChecks(s, f, d, deployer, keysExpected);
        if (failures != 0) revert DeploymentChecksFailed(failures);
    }

    /// @notice The same pass without the revert: how many checks failed, each named in `_failures`. A test of
    ///         the gate itself reads them.
    function _runChecks(
        Settings memory s,
        Decided memory f,
        Deployment memory d,
        address deployer,
        KeysExpected keysExpected
    ) internal returns (uint256) {
        delete _failures;
        _checksMade = 0;
        _need(block.chainid == s.chainId, "the chain is the settings file's chain");
        // A contract that is not there answers no view: the rest would revert with nothing to read.
        if (!_everyContractHasCode(s, d)) return _failures.length;
        _checkKeys(s, d, deployer, keysExpected);
        _checkWiring(s, d);
        _checkSettings(s, f, d);
        _checkHook(s, f, d);
        _checkCode(s, d);
        if (!_quietChecks) console2.log("checks made:", _checksMade, "failed:", _failures.length);
        return _failures.length;
    }

    function _everyContractHasCode(Settings memory s, Deployment memory d) internal returns (bool) {
        uint256 before = _failures.length;
        _need(s.poolManager.code.length != 0, "the PoolManager has code at the settings file's address");
        _need(address(d.keys).code.length != 0, "StokerKeys has code");
        _need(address(d.registry).code.length != 0, "QuoteRegistry has code");
        _need(address(d.distributor).code.length != 0, "Distributor has code");
        _need(address(d.taxVault).code.length != 0, "TaxVault has code");
        _need(address(d.factory).code.length != 0, "StokerFactory has code");
        _need(address(d.hook).code.length != 0, "StokerHook has code");
        _need(address(d.burnDestination).code.length != 0, "BurnDestination has code");
        _need(address(d.liquidityDestination).code.length != 0, "LiquidityDestination has code");
        _need(address(d.holdersDestination).code.length != 0, "HoldersDestination has code");
        return _failures.length == before;
    }

    /// @dev The Admin is the settings file's, nobody waits to take its place, and the roles are kept apart:
    ///      the contracts refuse the Admin as the ladder key and as the round key by name, and the gate also
    ///      refuses the deployer and one address in two roles, which no contract checks.
    function _checkKeys(Settings memory s, Deployment memory d, address deployer, KeysExpected keysExpected) internal {
        address admin = d.keys.admin();
        _need(admin == s.admin, "the Admin is the settings file's address");
        _need(d.keys.pendingAdmin() == address(0), "no address waits to take the Admin's place");
        _need(admin != deployer, "the Admin is not the deployer");
        _need(admin.code.length == 0, "the Admin's address has no code (ADR 0030: one hardware wallet)");

        address round = d.keys.holderOf(StokerKeys.Role.RoundKey);
        address ladder = d.keys.holderOf(StokerKeys.Role.LadderKey);
        address keeper = d.keys.holderOf(StokerKeys.Role.Keeper);
        _need(round != admin, "the round key is not the Admin");
        _need(ladder != admin, "the ladder key is not the Admin");
        _need(keeper != admin, "the Keeper is not the Admin");
        if (keysExpected == KeysExpected.AllAppointed) {
            _need(round != address(0), "the round key is held");
            _need(ladder != address(0), "the ladder key is held");
            _need(keeper != address(0), "the Keeper is held");
        } else if (!_quietChecks) {
            if (round == address(0)) console2.log("  note: nobody holds the round key yet");
            if (ladder == address(0)) console2.log("  note: nobody holds the ladder key yet");
            if (keeper == address(0)) console2.log("  note: nobody holds the Keeper's role yet");
        }
        _need(round == address(0) || (round != ladder && round != keeper), "the round key holds no other role");
        _need(ladder == address(0) || ladder != keeper, "the ladder key holds no other role");
        _need(round == address(0) || round != deployer, "the round key is not the deployer");
        _need(ladder == address(0) || ladder != deployer, "the ladder key is not the deployer");
    }

    /// @dev Each contract names the others it was made for. `distributor.taxVault()` is the one no
    ///      constructor checks: the Distributor is deployed before the vault, for an address computed ahead.
    function _checkWiring(Settings memory s, Deployment memory d) internal {
        _need(address(d.registry.keys()) == address(d.keys), "the Quote Registry reads the Admin from these keys");

        _need(address(d.distributor.keys()) == address(d.keys), "the Distributor reads its keys from these keys");
        _need(d.distributor.taxVault() == address(d.taxVault), "distributor.taxVault() is the real Tax Vault");

        _need(address(d.taxVault.poolManager()) == s.poolManager, "the Tax Vault's PoolManager is the chain's");
        _need(d.taxVault.factory() == address(d.factory), "taxVault.factory() is the real factory");
        _need(
            address(d.taxVault.distributor()) == address(d.distributor),
            "taxVault.distributor() is the real Distributor"
        );

        _need(address(d.factory.poolManager()) == s.poolManager, "the factory's PoolManager is the chain's");
        _need(address(d.factory.registry()) == address(d.registry), "the factory reads this Quote Registry");
        _need(d.factory.taxVault() == address(d.taxVault), "the factory refuses this Tax Vault as a Destination");
        _need(d.factory.distributor() == address(d.distributor), "the factory refuses this Distributor as one");
        _need(address(d.factory.hook()) == address(d.hook), "the factory's hook is this hook");

        _need(d.hook.factory() == address(d.factory), "the hook's factory is this factory");
        _need(address(d.hook.keys()) == address(d.keys), "the hook reads the Admin and the ladder key from these keys");
        _need(d.hook.taxVault() == address(d.taxVault), "the hook mints every tax to this Tax Vault");
        _need(d.hook.distributor() == address(d.distributor), "the hook refuses this Distributor as a referrer");
        _need(address(d.hook.poolManager()) == s.poolManager, "the hook's PoolManager is the chain's");
        _need(d.hook.platform() == s.admin, "the platform's share is booked to the Admin");

        _need(address(d.burnDestination.hook()) == address(d.hook), "the burn's Destination serves this hook");
        _need(address(d.burnDestination.taxVault()) == address(d.taxVault), "and funds this Tax Vault");
        _need(address(d.liquidityDestination.hook()) == address(d.hook), "the liquidity's Destination serves this hook");
        _need(address(d.liquidityDestination.taxVault()) == address(d.taxVault), "and funds this Tax Vault");
        _need(address(d.holdersDestination.hook()) == address(d.hook), "the holders' Destination serves this hook");
        _need(
            address(d.holdersDestination.distributor()) == address(d.distributor), "and fills this Distributor's pots"
        );
    }

    /// @dev Every setting is the chain file's, and the figures the ADRs fix are those figures: a piece of 100
    ///      basis points, which the vault's own bound allows, would move a price about as much as a round trip
    ///      costs, and a wrong share would be every later Launch's for good.
    function _checkSettings(Settings memory s, Decided memory f, Deployment memory d) internal {
        _need(d.registry.tickSpacing() == s.tickSpacing, "the registry's tick spacing");
        _need(d.factory.tickSpacing() == s.tickSpacing, "the factory's tick spacing");

        _need(d.factory.platformFeeBps() == s.platformFeeBps, "the Platform Fee is the settings file's");
        _need(d.factory.creatorShareBps() == s.creatorShareBps, "the first Creator Tier's share is the file's");
        _need(d.factory.secondTierShareBps() == s.secondTierShareBps, "the second Creator Tier's share is the file's");
        _need(d.factory.topTierShareBps() == s.topTierShareBps, "the top Creator Tier's share is the file's");
        _need(d.factory.openingFeeStartBps() == s.openingFeeStartBps, "the Opening Fee's start figure");
        _need(d.factory.openingFeeDuration() == s.openingFeeDuration, "the Opening Fee's duration");

        _need(d.taxVault.pieceBps() == s.pieceBps, "the Tax Vault's piece is the settings file's");
        _need(d.taxVault.pieceInterval() == s.pieceInterval, "the Tax Vault's interval");
        _need(d.taxVault.supportWidthSpacings() == s.supportWidthSpacings, "Support Liquidity's width");
        _need(d.taxVault.referenceRiseTicksPerMinute() == s.referenceRiseTicksPerMinute, "the Reference Price's rise");
        _need(d.taxVault.referenceFallTicksPerMinute() == s.referenceFallTicksPerMinute, "the Reference Price's fall");
        _need(d.taxVault.buyBandTicks() == s.buyBandTicks, "the buys' band above the Reference Price");

        _need(d.factory.platformFeeBps() == f.platformFeeBps, "the Platform Fee is the decided figure (ADR 0027)");
        _need(d.factory.creatorShareBps() == f.creatorShareBps, "the first tier's share is the decided one (ADR 0020)");
        _need(d.factory.secondTierShareBps() == f.secondTierShareBps, "the second tier's share is the decided one");
        _need(d.factory.topTierShareBps() == f.topTierShareBps, "the top tier's share is the decided one");
        _need(d.taxVault.pieceBps() == f.pieceBps, "pieceBps is the decided figure (ADR 0025)");
        _need(d.distributor.ROUND_DELAY() == f.roundDelay, "the Round Delay is the decided one (ADR 0029)");
    }

    /// @dev The hook's address carries exactly the bits of the permissions it reports, and it is the address
    ///      the factory makes from this build's hook creation code at the mined salt: a CREATE2 address commits
    ///      to its creation code, so this proves the hook's code without an explorer.
    function _checkHook(Settings memory s, Decided memory f, Deployment memory d) internal {
        Hooks.Permissions memory p = d.hook.getHookPermissions();
        uint160 reported = (p.beforeInitialize ? Hooks.BEFORE_INITIALIZE_FLAG : 0)
            | (p.afterInitialize ? Hooks.AFTER_INITIALIZE_FLAG : 0)
            | (p.beforeAddLiquidity ? Hooks.BEFORE_ADD_LIQUIDITY_FLAG : 0)
            | (p.afterAddLiquidity ? Hooks.AFTER_ADD_LIQUIDITY_FLAG : 0)
            | (p.beforeRemoveLiquidity ? Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG : 0)
            | (p.afterRemoveLiquidity ? Hooks.AFTER_REMOVE_LIQUIDITY_FLAG : 0)
            | (p.beforeSwap ? Hooks.BEFORE_SWAP_FLAG : 0) | (p.afterSwap ? Hooks.AFTER_SWAP_FLAG : 0)
            | (p.beforeDonate ? Hooks.BEFORE_DONATE_FLAG : 0) | (p.afterDonate ? Hooks.AFTER_DONATE_FLAG : 0)
            | (p.beforeSwapReturnDelta ? Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG : 0)
            | (p.afterSwapReturnDelta ? Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG : 0)
            | (p.afterAddLiquidityReturnDelta ? Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG : 0)
            | (p.afterRemoveLiquidityReturnDelta ? Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG : 0);
        uint160 carried = uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK;
        _need(carried == reported, "the hook's address carries exactly the permission bits it reports");
        _need(reported == HOOK_PERMISSION_BITS, "and they are the eight this build's hook uses");

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(StokerHook).creationCode, abi.encode(s.poolManager, d.keys, address(d.taxVault)))
        );
        address fromThisBuild = vm.computeCreate2Address(d.hookSalt, initCodeHash, address(d.factory));
        _need(address(d.hook) == fromThisBuild, "the hook is this build's creation code at the mined salt");
        _need(d.hook.GRADUATION_HOLD() == f.graduationHold, "the Graduation Hold is the decided hour (ADR 0024)");
    }

    /// @dev Seven contracts are deployed again inside this run, from this build and the arguments the chain
    ///      reports, and each must have exactly the deployed one's runtime code, its immutables included.
    ///      Nothing here is sent: it is a simulation. The hook is proven by its CREATE2 address above. The
    ///      factory cannot be proven this way (a second factory would make its hook at another address, which
    ///      the mined salt does not fit), so its code rests on the explorer's verification of its source.
    function _checkCode(Settings memory s, Deployment memory d) internal {
        _need(
            address(new StokerKeys(s.admin)).codehash == address(d.keys).codehash, "StokerKeys runs this build's code"
        );
        _need(
            address(new QuoteRegistry(d.keys, s.tickSpacing)).codehash == address(d.registry).codehash,
            "QuoteRegistry runs this build's code"
        );
        _need(
            address(new Distributor(d.keys, address(d.taxVault))).codehash == address(d.distributor).codehash,
            "Distributor runs this build's code"
        );
        TaxVault vault = new TaxVault(
            d.taxVault.poolManager(),
            address(d.factory),
            d.distributor,
            s.pieceBps,
            s.pieceInterval,
            s.supportWidthSpacings,
            s.referenceRiseTicksPerMinute,
            s.referenceFallTicksPerMinute,
            s.buyBandTicks
        );
        _need(address(vault).codehash == address(d.taxVault).codehash, "TaxVault runs this build's code");
        _need(
            address(new BurnDestination(d.hook)).codehash == address(d.burnDestination).codehash,
            "BurnDestination runs this build's code"
        );
        _need(
            address(new LiquidityDestination(d.hook)).codehash == address(d.liquidityDestination).codehash,
            "LiquidityDestination runs this build's code"
        );
        _need(
            address(new HoldersDestination(d.hook)).codehash == address(d.holdersDestination).codehash,
            "HoldersDestination runs this build's code"
        );
    }

    function _need(bool ok, string memory what) internal {
        _checksMade++;
        if (ok) {
            if (!_quietChecks) console2.log("  ok    ", what);
            return;
        }
        _failures.push(what);
        console2.log("  FAILED", what);
    }
}
