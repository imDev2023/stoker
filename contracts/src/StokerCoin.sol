// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title StokerCoin
/// @notice A coin launched on Stoker on an EVM chain: a plain ERC-20 of 1 trillion at 18 decimals, minted
///         once to the factory that deploys it (ADR 0024). It has no owner, no mint, no transfer tax and
///         no blocklist. A holder may burn their own coins and nobody else's, so a burn lowers the supply.
contract StokerCoin is ERC20 {
    /// @notice The whole supply, minted once at deployment.
    uint256 public constant SUPPLY = 1e12 * 1e18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, SUPPLY);
    }

    /// @notice Burns `amount` of the caller's own coins.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
