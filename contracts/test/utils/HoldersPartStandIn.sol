// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHoldersPart} from "../../src/interfaces/IHoldersPart.sol";

/// @notice Stands in for the Distributor (#247) behind `IHoldersPart`: it takes each deposit as the
///         interface says (the native asset as value, an ERC-20 pulled with `transferFrom`) and counts it per
///         coin and asset. `shortBy` makes it pull less than it is told, for the Tax Vault's own check.
contract HoldersPartStandIn is IHoldersPart {
    mapping(address coin => mapping(Currency asset => uint256)) public deposited;
    uint256 public shortBy;

    event Deposited(address indexed coin, Currency indexed asset, uint256 amount);

    function setShortBy(uint256 shortBy_) external {
        shortBy = shortBy_;
    }

    function deposit(address coin, Currency asset, uint256 amount) external payable {
        if (asset.isAddressZero()) {
            require(msg.value == amount, "value");
        } else {
            require(msg.value == 0, "no value with an ERC-20");
            require(IERC20(Currency.unwrap(asset)).transferFrom(msg.sender, address(this), amount - shortBy), "pull");
        }
        deposited[coin][asset] += amount;
        emit Deposited(coin, asset, amount);
    }
}
