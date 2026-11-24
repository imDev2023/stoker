// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Distributor} from "../../src/Distributor.sol";

/// @notice Stands in for the Tax Vault (#245) until it lands: it hands a coin's holders' part to the
///         Distributor exactly as `IHoldersPart` says the Tax Vault will, from a balance the test gives it.
///         The native asset goes as the call's value; an ERC-20 is approved for exactly the amount just
///         before the call and the allowance cleared after, and the call reverts unless exactly the amount
///         left this contract.
contract TaxVaultStandIn {
    using SafeERC20 for IERC20;

    Distributor public distributor;

    error DepositShort();

    function setDistributor(Distributor distributor_) external {
        distributor = distributor_;
    }

    function pass(address coin, Currency asset, uint256 amount) external {
        if (asset.isAddressZero()) {
            distributor.deposit{value: amount}(coin, asset, amount);
            return;
        }
        IERC20 token = IERC20(Currency.unwrap(asset));
        uint256 before = token.balanceOf(address(this));
        token.forceApprove(address(distributor), amount);
        distributor.deposit(coin, asset, amount);
        if (before - token.balanceOf(address(this)) != amount) revert DepositShort();
        token.forceApprove(address(distributor), 0);
    }

    receive() external payable {}
}
