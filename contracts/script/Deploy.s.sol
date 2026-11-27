// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {DeploymentChecks} from "./deployment/DeploymentChecks.sol";

/// @title Deploy
/// @notice Deploys Stoker's whole contract set to one EVM chain (#251), in `StokerDeployer`'s order, from the
///         chain's settings file, then runs every check of `DeploymentChecks` on the result. A forge script
///         simulates the whole run before it sends anything, so a deployment that would fail a check is never
///         sent. Run it through `script/deploy.sh`, which also checks the chain afterwards, verifies the
///         sources and publishes the addresses.
/// @dev    CONFIG=script/config/<chain>.json  the chain's settings
///         DEPLOYER_KEY=0x...                 the deployer's key, from the environment and never an argument
///                                            (a process's arguments are public on its machine); without it
///                                            the sender forge was given signs (`--ledger`, `--account`)
///         ADMIN=0x...                        on a fork alone: an Admin in place of the settings file's
///         The deployer is a throwaway: nothing in the set has an owner, so it holds no power afterwards. The
///         Admin is the settings file's address and signs nothing here.
///
///         The record of what was deployed is written only when this run really broadcasts
///         (`ScriptBroadcast`): a run without `--broadcast` executes every file write too, and would leave a
///         record of contracts that were never sent. Even then it is written before the transactions land, so
///         it goes to `cache/deployments/` as pending, and only `script/deploy.sh` publishes it, after
///         `CheckDeployment.s.sol` has found every contract on the chain.
contract Deploy is Script, DeploymentChecks {
    error WrongChain(uint256 expected, uint256 actual);

    function run() external returns (Deployment memory d) {
        string memory configPath = vm.envString("CONFIG");
        Settings memory s = _loadSettings(configPath);
        Decided memory f = _loadDecided("script/config/decided.json");
        if (block.chainid != s.chainId) revert WrongChain(s.chainId, block.chainid);
        address adminOverride = vm.envOr("ADMIN", address(0));
        if (adminOverride != address(0)) {
            console2.log("the Admin is taken from ADMIN, not the settings file (a fork alone):", adminOverride);
            s.admin = adminOverride;
        }

        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        address deployer = key != 0 ? vm.addr(key) : msg.sender;
        console2.log("chain:", s.name, s.chainId);
        console2.log("deployer:", deployer);
        console2.log("Admin:", s.admin);

        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        d = _deployStokerSet(s, deployer);
        vm.stopBroadcast();

        // In the simulation, before anything is sent: a set that fails a check is never broadcast.
        _checkDeployment(s, f, d, deployer, KeysExpected.MayBeUnappointed);

        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            _writePending(configPath, s, d, deployer);
        } else {
            console2.log("no record written: this run does not broadcast");
        }
    }

    function _writePending(string memory configPath, Settings memory s, Deployment memory d, address deployer)
        internal
    {
        string memory c = "contracts";
        vm.serializeAddress(c, "keys", address(d.keys));
        vm.serializeAddress(c, "registry", address(d.registry));
        vm.serializeAddress(c, "distributor", address(d.distributor));
        vm.serializeAddress(c, "taxVault", address(d.taxVault));
        vm.serializeAddress(c, "factory", address(d.factory));
        vm.serializeAddress(c, "hook", address(d.hook));
        vm.serializeAddress(c, "burnDestination", address(d.burnDestination));
        vm.serializeAddress(c, "liquidityDestination", address(d.liquidityDestination));
        string memory contracts = vm.serializeAddress(c, "holdersDestination", address(d.holdersDestination));

        string memory r = "record";
        vm.serializeUint(r, "chainId", s.chainId);
        vm.serializeString(r, "name", s.name);
        vm.serializeAddress(r, "poolManager", s.poolManager);
        vm.serializeAddress(r, "admin", s.admin);
        vm.serializeAddress(r, "deployer", deployer);
        vm.serializeBytes32(r, "hookSalt", d.hookSalt);
        vm.serializeString(r, "settings", vm.readFile(configPath));
        string memory record = vm.serializeString(r, "contracts", contracts);
        string memory path = string.concat("cache/deployments/", vm.toString(s.chainId), ".pending.json");
        vm.writeJson(record, path);
        console2.log("pending record:", path);
    }
}
