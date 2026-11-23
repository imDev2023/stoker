// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launched coin: a plain ERC-20 with a fixed supply, no owner, no mint after the
///         constructor, no transfer tax and no blocklist. Holders may burn their own coins,
///         which is how the Reward Burn removes supply (spike choice; see the README).
contract StokerCoin is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000_000 ether; // 1 trillion at 18 decimals

    constructor(string memory name_, string memory symbol_, address to) ERC20(name_, symbol_) {
        _mint(to, SUPPLY);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
