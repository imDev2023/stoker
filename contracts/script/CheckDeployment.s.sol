// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {DeploymentChecks} from "./deployment/DeploymentChecks.sol";
import {StokerKeys} from "../src/StokerKeys.sol";
import {QuoteRegistry} from "../src/QuoteRegistry.sol";
import {Distributor} from "../src/Distributor.sol";
import {TaxVault} from "../src/TaxVault.sol";
import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";
import {BurnDestination} from "../src/destinations/BurnDestination.sol";
import {LiquidityDestination} from "../src/destinations/LiquidityDestination.sol";
import {HoldersDestination} from "../src/destinations/HoldersDestination.sol";

/// @title CheckDeployment
/// @notice Runs every check of `DeploymentChecks` against a deployment as the chain holds it now (#251): after
///         `Deploy.s.sol` has broadcast, after the Admin has appointed the server keys, and at any later time.
///         It sends nothing and holds no key; what it deploys to compare runtime code stays in its simulation.
/// @dev    CONFIG=script/config/<chain>.json      the chain's settings
///         DEPLOYMENT=<a deployment record>       the addresses (`cache/deployments/<id>.pending.json`, or the
///                                                published `../packages/evm/deployments/<id>.json`)
///         KEYS=appointed                         also require the round key, the ladder key and the Keeper held
///         ADMIN=0x...                            on a fork alone: the Admin expected in place of the file's
///         forge script script/CheckDeployment.s.sol --rpc-url <the chain>      (never with --broadcast)
contract CheckDeployment is Script, DeploymentChecks {
    function run() external {
        Settings memory s = _loadSettings(vm.envString("CONFIG"));
        Decided memory f = _loadDecided("script/config/decided.json");
        address adminOverride = vm.envOr("ADMIN", address(0));
        if (adminOverride != address(0)) s.admin = adminOverride;

        string memory json = vm.readFile(vm.envString("DEPLOYMENT"));
        Deployment memory d;
        d.keys = StokerKeys(vm.parseJsonAddress(json, ".contracts.keys"));
        d.registry = QuoteRegistry(vm.parseJsonAddress(json, ".contracts.registry"));
        d.distributor = Distributor(vm.parseJsonAddress(json, ".contracts.distributor"));
        d.taxVault = TaxVault(payable(vm.parseJsonAddress(json, ".contracts.taxVault")));
        d.factory = StokerFactory(vm.parseJsonAddress(json, ".contracts.factory"));
        d.hook = StokerHook(payable(vm.parseJsonAddress(json, ".contracts.hook")));
        d.burnDestination = BurnDestination(payable(vm.parseJsonAddress(json, ".contracts.burnDestination")));
        d.liquidityDestination =
            LiquidityDestination(payable(vm.parseJsonAddress(json, ".contracts.liquidityDestination")));
        d.holdersDestination = HoldersDestination(payable(vm.parseJsonAddress(json, ".contracts.holdersDestination")));
        d.hookSalt = vm.parseJsonBytes32(json, ".hookSalt");
        address deployer = vm.parseJsonAddress(json, ".deployer");

        bool appointed = keccak256(bytes(vm.envOr("KEYS", string("")))) == keccak256("appointed");
        console2.log("chain:", s.name, block.chainid);
        console2.log("the keys:", appointed ? "all three must be held" : "may be unappointed");
        _checkDeployment(s, f, d, deployer, appointed ? KeysExpected.AllAppointed : KeysExpected.MayBeUnappointed);
        console2.log("every check passed");
    }
}
