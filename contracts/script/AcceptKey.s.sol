// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {StokerKeys} from "../src/StokerKeys.sol";

/// @title AcceptKey
/// @notice The second of a server key's two steps (ADR 0030): once the Admin has proposed an address for the
///         round key, the ladder key or the Keeper (`StokerKeys.proposeKey`, from the hardware wallet), that
///         address accepts, and holds the role from then on. Run once per key, with that key, before it is
///         stored as a Worker secret.
/// @dev    KEYS=0x...           the deployment's StokerKeys
///         ROLE=round|ladder|keeper
///         SERVER_KEY=0x...     the key that accepts, from the environment and never an argument
///         forge script script/AcceptKey.s.sol --rpc-url <chain> --broadcast
contract AcceptKey is Script {
    error NotProposed(address proposed, address accepting);

    function run() external {
        StokerKeys keys = StokerKeys(vm.envAddress("KEYS"));
        bytes32 name = keccak256(bytes(vm.envString("ROLE")));
        StokerKeys.Role role;
        if (name == keccak256("round")) role = StokerKeys.Role.RoundKey;
        else if (name == keccak256("ladder")) role = StokerKeys.Role.LadderKey;
        else if (name == keccak256("keeper")) role = StokerKeys.Role.Keeper;
        else revert("ROLE is round, ladder or keeper");
        uint256 key = vm.envUint("SERVER_KEY");
        address who = vm.addr(key);
        if (keys.pendingHolderOf(role) != who) revert NotProposed(keys.pendingHolderOf(role), who);
        vm.broadcast(key);
        keys.acceptKey(role);
        console2.log("holds the role:", who);
    }
}
