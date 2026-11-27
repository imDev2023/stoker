// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {StokerHook} from "../StokerHook.sol";

/// @title EarningsDestination
/// @notice What every Creator Earnings Destination other than a wallet is built on (ADR 0027, #248): a
///         contract a Launch names as the owner of its Creator's Credits, which applies each coin's own
///         earnings to that coin by a call anyone can make. One contract of a kind serves every coin that
///         names it.
///
///         To the launch core it is an address: the factory writes it into the Launch's terms like any
///         wallet, the hook records the Creator's Credits to it, and the Payout Call pays it like any owner.
///         Nothing in the factory or the hook knows what stands behind it.
///
///         A Credit is booked by address and asset, never by pool, so this contract's Credits are every
///         one of its coins' earnings together. It tells them apart by the hook's own book: the hook keeps,
///         per pool, the running total of what that pool's swaps have credited its Destination
///         (`creatorCreditedOf`). `applyEarnings` for a coin first pulls this contract's own Credits in that
///         coin's Quote Asset, then applies exactly what the hook says that coin earned, less what was
///         applied for it before. So one coin's earnings can never be applied to another, whoever calls and
///         for whichever coin.
/// @dev No owner, no setter, no proxy, no pause. Its receive takes the native asset from the hook alone and
///      does nothing else, so it fits the gas a Payout Call gives a recipient; all the work is in
///      `applyEarnings`. It reads no clock.
abstract contract EarningsDestination {
    using SafeERC20 for IERC20;

    /// @dev The re-entry guard, in transient storage: keccak256("stoker.destination.lock") - 1.
    bytes32 internal constant LOCK_SLOT = 0x6076ae555abe934d98108d502682b11a92ced83669e271b37ea7d4c2f16be537;

    /// @notice The hook whose Launches may name this contract, and whose book of each pool's Creator Credits
    ///         it reads.
    StokerHook public immutable hook;

    /// @notice What this contract has applied of each coin's earnings so far, by its pool, in its Quote Asset.
    mapping(PoolId => uint256) public appliedOf;

    /// @notice `amount` of a coin's Creator earnings, in its Quote Asset, was applied to that coin.
    event EarningsApplied(PoolId indexed poolId, Currency indexed asset, uint256 amount);

    error ZeroAddress();
    error NotHook();
    error Reentered();
    /// @notice The pool is not ours, or its Launch names another Creator Earnings Destination.
    error NotThisCoinsDestination();
    error NothingToApply();
    /// @notice The Quote Asset refused to pay this contract its Credit (a blocklist, a pause): the earnings
    ///         stay owed to it in the hook, and nothing is applied until they arrive.
    error CreditNotReceived(uint256 owed);
    /// @notice What this contract was told to hand over did not leave it exactly.
    error HandOverShort();

    constructor(StokerHook hook_) {
        if (address(hook_) == address(0)) revert ZeroAddress();
        hook = hook_;
    }

    /// @notice Applies a coin's Creator earnings to that coin: everything its swaps have credited this
    ///         contract and that was not applied before. Anyone may call it, for any coin that names this
    ///         contract; the Keeper does on a schedule.
    /// @return amount What was applied, in the coin's Quote Asset.
    function applyEarnings(PoolKey calldata key) external returns (uint256 amount) {
        _lock();
        PoolId id = key.toId();
        Currency asset = _quoteOf(key, id);
        // This contract's own Credits in the asset, every coin's together: an owner pulling their own. The
        // Payout Call refuses to run inside another Payout Call or another unlock, and so does this.
        address[] memory me = new address[](1);
        me[0] = address(this);
        hook.payout(asset, me);
        uint256 owed = hook.creditOf(address(this), asset);
        if (owed != 0) revert CreditNotReceived(owed);

        amount = hook.creatorCreditedOf(id) - appliedOf[id];
        if (amount == 0) revert NothingToApply();
        appliedOf[id] += amount;
        _apply(key, asset, amount);
        // The calls before it are our own hook's, and what `_apply` hands the amount to.
        // forge-lint: disable-next-line(reentrancy-events)
        emit EarningsApplied(id, asset, amount);
        _unlock();
    }

    /// @notice What a coin has earned for this contract and `applyEarnings` has not applied yet, paid out of
    ///         the hook or not. Zero for a coin that names another Destination.
    function waitingOf(PoolKey calldata key) external view returns (uint256) {
        PoolId id = key.toId();
        if (hook.termsOf(id).creatorDestination != address(this)) return 0;
        return hook.creatorCreditedOf(id) - appliedOf[id];
    }

    /// @dev What this kind of Destination does with `amount` of the coin's Quote Asset, which this contract
    ///      holds: hand it to the contract that does the work, for this coin and no other.
    function _apply(PoolKey calldata key, Currency asset, uint256 amount) internal virtual;

    /// @dev The pool's Quote Asset, for a pool of ours whose Launch names this contract.
    function _quoteOf(PoolKey calldata key, PoolId id) internal view returns (Currency) {
        StokerHook.Terms memory t = hook.termsOf(id);
        // The pool id hashes every field of the key, so only a pool our factory opened has terms at all: any
        // other key names nobody.
        if (t.creatorDestination != address(this)) revert NotThisCoinsDestination();
        return t.quoteIsCurrency0 ? key.currency0 : key.currency1;
    }

    /// @dev Approves `spender` for exactly `amount` of an ERC-20 before a hand-over that pulls it.
    function _approve(Currency asset, address spender, uint256 amount) internal returns (uint256 balanceBefore) {
        IERC20 token = IERC20(Currency.unwrap(asset));
        balanceBefore = token.balanceOf(address(this));
        token.forceApprove(spender, amount);
    }

    /// @dev After a hand-over of an ERC-20: exactly `amount` left, and no allowance stays behind.
    function _settled(Currency asset, address spender, uint256 amount, uint256 balanceBefore) internal {
        IERC20 token = IERC20(Currency.unwrap(asset));
        // Exactly the amount, on purpose: the books of whoever took it count that much.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (balanceBefore - token.balanceOf(address(this)) != amount) revert HandOverShort();
        token.forceApprove(spender, 0);
    }

    function _lock() internal {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
        if (locked) revert Reentered();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
    }

    function _unlock() internal {
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    /// @dev The hook pays this contract its native Credits; nobody else may send it the native asset, so what
    ///      it holds is its coins' earnings on their way. Nothing is written and nothing is called: the Payout
    ///      Call gives a recipient 50,000 gas, and reads of `creditOf` from in here would be of a call half
    ///      made.
    receive() external payable {
        if (msg.sender != address(hook)) revert NotHook();
    }
}
