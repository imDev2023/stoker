// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {StokerHook} from "../StokerHook.sol";
import {Distributor} from "../Distributor.sol";
import {EarningsDestination} from "./EarningsDestination.sol";

/// @title HoldersDestination
/// @notice The Creator Earnings Destination of the holders (ADR 0011's `holders`, on an EVM chain, #248): a
///         coin's Creator earnings are paid to the coin's holders as Holder Dividends, in the Quote Asset.
///
///         It pays nobody itself. It hands each coin's earnings to that coin's earnings pot in the
///         Distributor (`Distributor.depositEarnings`), which admits a coin's own Destination alone; the
///         round key posts Round Roots of source `earnings` for that pot, and they wait the Round Delay, can
///         be cancelled by the Guard and are claimed exactly as a Reward Round's (ADR 0029). The pot is
///         apart from the coin's Reward Tax, so a Reward Launch that names this contract pays both, each from
///         its own.
contract HoldersDestination is EarningsDestination {
    /// @notice The Distributor the hook's Tax Vault hands the holders' part to.
    Distributor public immutable distributor;

    constructor(StokerHook hook_) EarningsDestination(hook_) {
        distributor = Distributor(hook_.distributor());
    }

    function _apply(PoolKey calldata key, Currency asset, uint256 amount) internal override {
        if (asset.isAddressZero()) {
            distributor.depositEarnings{value: amount}(key, amount);
            return;
        }
        uint256 before = _approve(asset, address(distributor), amount);
        distributor.depositEarnings(key, amount);
        _settled(asset, address(distributor), amount, before);
    }
}
