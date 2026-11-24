// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StokerHook} from "./StokerHook.sol";

/// @title StokerCreatorLock
/// @notice One Launch's Creator Lock on an EVM chain (#244, ADR 0024; Solana's is ADR 0023): coins held out
///         of the Seed Position for the Creator, released after Graduation by terms fixed at launch.
///         Nothing is released before the coin graduates. From Graduation a cliff runs, then the rest
///         unlocks in a straight line over the unlock time, rounded down; with no unlock time all of it is
///         released at the cliff's end. The Creator's own address, and no other, claims what has been
///         released, and the coins go to it.
/// @dev The factory deploys one per Launch that asks for a lock and sends it the coins; it has no owner, no
///      setter and no other way out for them. Its terms are immutables. It reads Graduation from the hook,
///      which records it once and never changes it, and reads the time from `block.timestamp` alone.
///      Coins anyone else sends it stay in it for good.
contract StokerCreatorLock {
    using SafeERC20 for IERC20;

    /// @notice The locked coin.
    IERC20 public immutable coin;
    /// @notice The hook that records the coin's Graduation.
    StokerHook public immutable hook;
    /// @notice The coin's pool, by which the hook records its Graduation.
    PoolId public immutable poolId;
    /// @notice The Creator: the address that launched the coin, the only one that claims, and where the
    ///         coins go.
    address public immutable creator;
    /// @notice The coins locked at launch.
    uint256 public immutable amount;
    /// @notice Seconds from Graduation before anything is released.
    uint256 public immutable cliff;
    /// @notice Seconds after the cliff over which the coins are released in a straight line; zero releases
    ///         them all at the cliff's end.
    uint256 public immutable unlock;

    /// @notice The coins claimed so far.
    uint256 public claimed;

    event Claimed(address indexed creator, uint256 amount);

    error NotCreator();
    error NotGraduated();
    error NothingToClaim();

    constructor(
        IERC20 coin_,
        StokerHook hook_,
        PoolId poolId_,
        // The factory alone deploys a lock, with the launch's own caller as the Creator, never zero.
        // forge-lint: disable-next-line(missing-zero-check)
        address creator_,
        uint256 amount_,
        uint256 cliff_,
        uint256 unlock_
    ) {
        coin = coin_;
        hook = hook_;
        poolId = poolId_;
        creator = creator_;
        amount = amount_;
        cliff = cliff_;
        unlock = unlock_;
    }

    /// @notice Pays the Creator every coin released and not yet claimed. Only the Creator may call it.
    function claim() external returns (uint256 paid) {
        if (msg.sender != creator) revert NotCreator();
        if (graduatedAt() == 0) revert NotGraduated();
        paid = released() - claimed;
        if (paid == 0) revert NothingToClaim();
        claimed += paid;
        coin.safeTransfer(creator, paid);
        emit Claimed(creator, paid);
    }

    /// @notice When the coin graduated, as the hook recorded it; zero until it has.
    function graduatedAt() public view returns (uint256) {
        return hook.graduationOf(poolId).graduatedAt;
    }

    /// @notice The coins the schedule has released by now, claimed or not.
    function released() public view returns (uint256) {
        uint256 graduated = graduatedAt();
        if (graduated == 0) return 0;
        uint256 start = graduated + cliff;
        // The schedule is the clock's, in days: a sequencer's few seconds move it by as much and no more.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < start) return 0;
        // forge-lint: disable-next-line(block-timestamp)
        if (unlock == 0 || block.timestamp >= start + unlock) return amount;
        return amount * (block.timestamp - start) / unlock;
    }

    /// @notice The coins the Creator could claim now.
    function claimable() external view returns (uint256) {
        return released() - claimed;
    }
}
