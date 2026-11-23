// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice A local stand-in for a Stock Token: 18 decimals, ERC-2612 permit, and an issuer's blocklist
///         checked on the sender, the recipient and the caller of every transfer, reverting with the
///         same `Blocked(address)` error the real ones use (selector 0x75e91ce7).
contract MockQuote is ERC20Permit {
    error Blocked(address account);

    mapping(address => bool) public isBlocked;

    constructor() ERC20("Mock Stock", "MOCK") ERC20Permit("Mock Stock") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool blocked) external {
        isBlocked[account] = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isBlocked[from]) revert Blocked(from);
        if (isBlocked[to]) revert Blocked(to);
        if (isBlocked[msg.sender]) revert Blocked(msg.sender);
        super._update(from, to, value);
    }
}
