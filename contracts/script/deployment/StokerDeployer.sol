// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CommonBase} from "forge-std/Base.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StokerKeys} from "../../src/StokerKeys.sol";
import {QuoteRegistry} from "../../src/QuoteRegistry.sol";
import {Distributor} from "../../src/Distributor.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {BurnDestination} from "../../src/destinations/BurnDestination.sol";
import {LiquidityDestination} from "../../src/destinations/LiquidityDestination.sol";
import {HoldersDestination} from "../../src/destinations/HoldersDestination.sol";

/// @title StokerDeployer
/// @notice Deploys the whole contract set of one EVM chain in the one order that works (#251), from settings
///         read out of that chain's file under `script/config`. `script/Deploy.s.sol` broadcasts it, and the
///         whole-set invariant campaign (`test/invariant/WholeSet.invariant.t.sol`) deploys through this very
///         code, so what the campaign proves is proven of the set as it is deployed.
///
///         The order, and why it cannot be another:
///         1. `StokerKeys`, with the Admin's address.
///         2. `QuoteRegistry`, with the keys and the tick spacing.
///         3. `Distributor`, for the Tax Vault's future address: the vault fixes the Distributor's address in
///            turn, so one of the two is deployed for an address computed beforehand, and nothing on-chain
///            checks it (`DeploymentChecks` does).
///         4. `TaxVault`, for the factory's future address and with the Distributor's.
///         5. `StokerFactory`, whose constructor checks the vault was made for it and deploys the hook at a
///            salt mined so the hook's address carries exactly its permission bits.
///         6. The three Creator Earnings Destinations, each with the hook's address alone.
/// @dev Every contract is created by `deployer` in consecutive transactions, so each future address is the
///      deployer's next nonces. A stray transaction from the deployer between them breaks the prediction;
///      the factory's own check and `DeploymentChecks` then refuse the result.
abstract contract StokerDeployer is CommonBase {
    /// @notice One chain's settings, as its file under `script/config` holds them. No figure of a deployment
    ///         is a constant of a script.
    struct Settings {
        uint256 chainId;
        string name;
        address poolManager;
        address admin;
        int24 tickSpacing;
        uint16 platformFeeBps;
        uint16 creatorShareBps;
        uint16 secondTierShareBps;
        uint16 topTierShareBps;
        uint16 openingFeeStartBps;
        uint32 openingFeeDuration;
        uint16 pieceBps;
        uint32 pieceInterval;
        int24 supportWidthSpacings;
        uint24 referenceRiseTicksPerMinute;
        uint24 referenceFallTicksPerMinute;
        uint24 buyBandTicks;
    }

    /// @notice One deployment of the set.
    struct Deployment {
        StokerKeys keys;
        QuoteRegistry registry;
        Distributor distributor;
        TaxVault taxVault;
        StokerFactory factory;
        StokerHook hook;
        BurnDestination burnDestination;
        LiquidityDestination liquidityDestination;
        HoldersDestination holdersDestination;
        bytes32 hookSalt;
    }

    /// @notice The hook's eight permission bits (`StokerHook.getHookPermissions`), which its address must carry
    ///         in its low 14 bits and no other.
    uint160 internal constant HOOK_PERMISSION_BITS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    error NoAdmin();
    error NoPoolManager();
    error AddressNotAsPredicted(string what, address predicted, address actual);

    /// @notice Reads one chain's settings from its file.
    function _loadSettings(string memory path) internal view returns (Settings memory s) {
        string memory json = vm.readFile(path);
        s.chainId = vm.parseJsonUint(json, ".chainId");
        s.name = vm.parseJsonString(json, ".name");
        s.poolManager = vm.parseJsonAddress(json, ".poolManager");
        s.admin = vm.parseJsonAddress(json, ".admin");
        s.tickSpacing = SafeCast.toInt24(vm.parseJsonInt(json, ".tickSpacing"));
        s.platformFeeBps = SafeCast.toUint16(vm.parseJsonUint(json, ".platformFeeBps"));
        s.creatorShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".creatorShareBps"));
        s.secondTierShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".secondTierShareBps"));
        s.topTierShareBps = SafeCast.toUint16(vm.parseJsonUint(json, ".topTierShareBps"));
        s.openingFeeStartBps = SafeCast.toUint16(vm.parseJsonUint(json, ".openingFeeStartBps"));
        s.openingFeeDuration = SafeCast.toUint32(vm.parseJsonUint(json, ".openingFeeDuration"));
        s.pieceBps = SafeCast.toUint16(vm.parseJsonUint(json, ".pieceBps"));
        s.pieceInterval = SafeCast.toUint32(vm.parseJsonUint(json, ".pieceInterval"));
        s.supportWidthSpacings = SafeCast.toInt24(vm.parseJsonInt(json, ".supportWidthSpacings"));
        s.referenceRiseTicksPerMinute = SafeCast.toUint24(vm.parseJsonUint(json, ".referenceRiseTicksPerMinute"));
        s.referenceFallTicksPerMinute = SafeCast.toUint24(vm.parseJsonUint(json, ".referenceFallTicksPerMinute"));
        s.buyBandTicks = SafeCast.toUint24(vm.parseJsonUint(json, ".buyBandTicks"));
    }

    /// @notice Deploys the whole set, every contract created by `deployer`: the broadcaster of a script, or the
    ///         test contract itself. It holds no power afterwards: nothing in the set has an owner.
    function _deployStokerSet(Settings memory s, address deployer) internal returns (Deployment memory d) {
        if (s.admin == address(0)) revert NoAdmin();
        if (s.poolManager == address(0)) revert NoPoolManager();
        IPoolManager poolManager = IPoolManager(s.poolManager);
        uint64 nonce = vm.getNonce(deployer);

        d.keys = new StokerKeys(s.admin);
        d.registry = new QuoteRegistry(d.keys, s.tickSpacing);

        address vaultAt = vm.computeCreateAddress(deployer, nonce + 3);
        address factoryAt = vm.computeCreateAddress(deployer, nonce + 4);
        d.distributor = new Distributor(d.keys, vaultAt);
        d.taxVault = new TaxVault(
            poolManager,
            factoryAt,
            d.distributor,
            s.pieceBps,
            s.pieceInterval,
            s.supportWidthSpacings,
            s.referenceRiseTicksPerMinute,
            s.referenceFallTicksPerMinute,
            s.buyBandTicks
        );
        if (address(d.taxVault) != vaultAt) revert AddressNotAsPredicted("TaxVault", vaultAt, address(d.taxVault));

        d.hookSalt = _mineHookSalt(
            factoryAt,
            keccak256(abi.encodePacked(type(StokerHook).creationCode, abi.encode(poolManager, d.keys, d.taxVault)))
        );
        d.factory = new StokerFactory(
            poolManager,
            d.registry,
            s.platformFeeBps,
            s.creatorShareBps,
            s.secondTierShareBps,
            s.topTierShareBps,
            d.hookSalt,
            d.taxVault,
            s.openingFeeStartBps,
            s.openingFeeDuration
        );
        if (address(d.factory) != factoryAt) {
            revert AddressNotAsPredicted("StokerFactory", factoryAt, address(d.factory));
        }
        d.hook = d.factory.hook();

        d.burnDestination = new BurnDestination(d.hook);
        d.liquidityDestination = new LiquidityDestination(d.hook);
        d.holdersDestination = new HoldersDestination(d.hook);
    }

    /// @notice The CREATE2 salt at which the factory at `factory_` deploys a hook whose address carries exactly
    ///         the hook's permission bits: about one salt in 16,384 does.
    function _mineHookSalt(address factory_, bytes32 initCodeHash) internal pure returns (bytes32 salt) {
        // 0xff ++ deployer ++ salt ++ keccak256(initCode), hashed in place: the salt's word is rewritten each turn.
        bytes memory preimage = abi.encodePacked(bytes1(0xff), factory_, bytes32(0), initCodeHash);
        uint256 i;
        while (uint160(uint256(keccak256(preimage))) & Hooks.ALL_HOOK_MASK != HOOK_PERMISSION_BITS) {
            i++;
            assembly ("memory-safe") {
                mstore(add(preimage, 0x35), i)
            }
        }
        salt = bytes32(i);
    }
}
