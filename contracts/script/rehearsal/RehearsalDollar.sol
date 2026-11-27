// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title RehearsalDollar
/// @notice The rehearsal's own stand-in for USDG, which testnet 46630 does not have (#249, #251): a dollar
///         of six decimals with ERC-2612 permit and its issuer's powers as USDG's were read, held by one
///         address: a freeze checked on the sender, the recipient and the caller of every transfer, a pause
///         that stops every transfer, and a mint. It is deployed on a testnet and on forks alone, so a frozen
///         Credit and a paused pool are rehearsed against our contracts; it is never a Quote Asset on a live
///         chain, and nothing under `src` knows it.
contract RehearsalDollar is ERC20Permit {
    address public immutable issuer;
    bool public paused;
    mapping(address => bool) public isFrozen;

    event Frozen(address indexed account, bool frozen);
    event Paused(bool paused);

    error NotIssuer();
    error AddressFrozen(address account);
    error TransfersPaused();

    constructor() ERC20("Rehearsal Dollar", "RUSD") ERC20Permit("Rehearsal Dollar") {
        issuer = msg.sender;
    }

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert NotIssuer();
        _;
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external onlyIssuer {
        _mint(to, amount);
    }

    function setFrozen(address account, bool frozen) external onlyIssuer {
        isFrozen[account] = frozen;
        emit Frozen(account, frozen);
    }

    function setPaused(bool paused_) external onlyIssuer {
        paused = paused_;
        emit Paused(paused_);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TransfersPaused();
        if (isFrozen[from]) revert AddressFrozen(from);
        if (isFrozen[to]) revert AddressFrozen(to);
        if (isFrozen[msg.sender]) revert AddressFrozen(msg.sender);
        super._update(from, to, value);
    }
}
