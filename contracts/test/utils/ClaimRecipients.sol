// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Distributor} from "../../src/Distributor.sol";

/// Holders that misbehave when a round in the native asset pays them (#247), beside the Credit owners of
/// `Recipients.sol`, which serve here too (a revert, a gas burn, a return bomb, an exacting receive).

/// Re-enters `claim` from inside its payment to be paid twice. It replays the claim it was given, so the
/// re-entry is a valid claim and only the guard can stop it. Strict, it refuses the payment when the
/// re-entry fails; lenient, it records the error the re-entry met and accepts.
contract ReentrantClaimRecipient {
    Distributor internal immutable distributor;
    bool internal immutable lenient;
    Distributor.Claim[] internal _again;
    bytes4 public met;

    constructor(Distributor distributor_, bool lenient_) {
        distributor = distributor_;
        lenient = lenient_;
    }

    function arm(Distributor.Claim calldata c) external {
        delete _again;
        _again.push(c);
    }

    receive() external payable {
        if (!lenient) {
            distributor.claim(_again);
            return;
        }
        try distributor.claim(_again) {
            met = bytes4(0xffffffff);
        } catch (bytes memory reason) {
            met = bytes4(reason);
        }
    }
}

/// A holder whose receive needs more gas than a payment pushed to it carries (a heavy smart wallet): it is
/// paid when it claims for itself, with all the gas it brings.
contract HeavyHolder {
    uint256 internal constant NEEDS = 200_000;

    receive() external payable {
        if (gasleft() < NEEDS) revert("too little gas");
    }

    function claimOwn(Distributor distributor, Distributor.Claim[] calldata claims) external {
        distributor.claim(claims);
    }
}

/// Refuses every payment until it is told to accept, so a test can show a refused holder stays owed and
/// is paid later.
contract SwitchableHolder {
    bool public accepting;

    function accept() external {
        accepting = true;
    }

    receive() external payable {
        if (!accepting) revert("not yet");
    }
}
