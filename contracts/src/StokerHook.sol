// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SafeCast as OZSafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title StokerHook
/// @notice The Uniswap v4 hook of every Stoker coin's pool on an EVM chain. It keeps the books and does
///         nothing else (ADR 0025): on every swap it takes the Platform Fee on the Quote Asset's side and
///         records it as Credits, the Creator's share to the Launch's Creator Earnings Destination and the
///         rest to the platform. It calls no recipient, buys nothing and adds no liquidity inside a swap.
///
///         The fees stay in the PoolManager as this hook's ERC-6909 claims, which back every Credit one
///         for one; the hook never holds an ERC-20. A Payout Call, which anyone can make, pays Credits to
///         their owners, and a Credit owed to an address the Quote Asset refuses stays owed to it.
///
///         The hook also guards the pool: only the factory opens a pool on it and adds liquidity to it,
///         no liquidity is ever removed, and donations are refused.
/// @dev Reads no clock in this slice; Graduation (#244) will read `block.timestamp` only, never
///      `block.number`, which is an estimate of the L1 block on Robinhood Chain and Arbitrum.
contract StokerHook is BaseHook, IUnlockCallback {
    using SafeCast for uint256;

    uint256 internal constant BPS = 10_000;

    /// @notice The gas a native payment to anyone but the caller carries (#242): enough for a smart wallet's
    ///         receive, too little to matter to the caller's batch. An owner whose receive needs more is
    ///         paid in full when they pull their own, with all the gas they bring.
    uint256 public constant NATIVE_PAYOUT_GAS = 50_000;
    /// @dev What the call itself costs the caller beyond the gas it forwards: a cold account (2,600), the
    ///      value transfer (9,000) and a new account (25,000), with room to spare.
    uint256 internal constant NATIVE_CALL_OVERHEAD = 40_000;

    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// @dev The Payout Call's re-entry guard, in transient storage: keccak256("stoker.hook.payout") - 1.
    bytes32 internal constant PAYOUT_LOCK_SLOT = 0xd04e813222e68601f425a39df2273a82d60dee2d93f26d04571d85a6074013f3;

    /// @dev What one of the hook's own unlocks is for.
    enum Action {
        PayERC20,
        TakeNative,
        ReturnNative
    }

    /// @notice The factory that deployed this hook: the only address that opens pools on it and adds
    ///         liquidity to them.
    address public immutable factory;

    /// @notice Where the platform's share of every Platform Fee is credited (the Admin's address, ADR 0030;
    ///         its two-step replacement is #243's).
    address public immutable platform;

    /// @notice A Launch's terms, written once by the factory before its pool opens and never changed.
    /// @param creatorDestination The Creator Earnings Destination credited with the Creator's share.
    /// @param platformFeeBps The Platform Fee, of the Quote Asset's side of every swap.
    /// @param creatorShareBps The Creator's share of the Platform Fee (the Creator Ladder's tier, ADR 0027).
    /// @param quoteIsCurrency0 Which side of the pool the Quote Asset is.
    struct Terms {
        address creatorDestination;
        uint16 platformFeeBps;
        uint16 creatorShareBps;
        bool quoteIsCurrency0;
        bool registered;
    }

    mapping(PoolId => Terms) internal _terms;

    /// @notice Credits owed, by owner and Quote Asset.
    mapping(address owner => mapping(Currency currency => uint256)) internal _credits;

    /// @notice The sum of every Credit owed in a currency, equal to this hook's claims on it.
    mapping(Currency currency => uint256) public totalCredits;

    event LaunchRegistered(
        PoolId indexed poolId,
        address indexed creatorDestination,
        uint16 platformFeeBps,
        uint16 creatorShareBps,
        bool quoteIsCurrency0
    );
    /// @notice One swap's Platform Fee and the two Credits it was recorded as.
    event FeeCredited(
        PoolId indexed poolId,
        Currency indexed currency,
        address indexed creatorDestination,
        uint256 fee,
        uint256 creatorCredit,
        uint256 platformCredit
    );
    event CreditPaid(address indexed owner, Currency indexed currency, uint256 amount);
    /// @notice The Quote Asset refused to pay `owner` (a blocklist, a pause); the Credit stays owed to it.
    event CreditRefused(address indexed owner, Currency indexed currency, uint256 amount);

    error OnlyFactory();
    error AlreadyRegistered();
    error NotRegistered();
    error SeedPositionLocked();
    error DonationsRefused();
    error SwapTooSmall();
    error SwapStoppedEarly();
    error ZeroAddress();
    error PayoutReentered();
    /// @notice The Payout Call was given too little gas to carry a native payment's full allowance.
    error PayoutGasTooLow();

    constructor(IPoolManager poolManager_, address platform_) BaseHook(poolManager_) {
        if (platform_ == address(0)) revert ZeroAddress();
        factory = msg.sender;
        platform = platform_;
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ the factory

    /// @notice Writes a Launch's terms before its pool opens. Called once per pool, by the factory alone.
    function registerLaunch(PoolKey calldata key, Terms calldata terms) external {
        if (msg.sender != factory) revert OnlyFactory();
        PoolId id = key.toId();
        if (_terms[id].registered) revert AlreadyRegistered();
        Terms memory t = terms;
        t.registered = true;
        _terms[id] = t;
        emit LaunchRegistered(id, t.creatorDestination, t.platformFeeBps, t.creatorShareBps, t.quoteIsCurrency0);
    }

    // ------------------------------------------------------------------ the pool's guards

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != factory) revert OnlyFactory();
        if (!_terms[key.toId()].registered) revert NotRegistered();
        return this.beforeInitialize.selector;
    }

    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        return this.beforeAddLiquidity.selector;
    }

    /// @dev v4 routes every decrease, and a zero-liquidity "poke", through here: all are refused, whoever
    ///      sends them, the factory included.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert SeedPositionLocked();
    }

    /// @dev A donation would accrue as fees to a position nobody can collect from (the spike's finding 1).
    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert DonationsRefused();
    }

    // ------------------------------------------------------------------ the fee

    /// @dev When the Quote Asset is the swap's specified currency the fee is taken here, on the specified
    ///      amount: an exact-in buy (the trader pays the amount, fee included) or an exact-out sell (the
    ///      trader receives the amount, the pool pays the fee on top).
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Terms memory t = _termsOf(id);
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn == params.zeroForOne;
        if (specifiedIsCurrency0 != t.quoteIsCurrency0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 fee = _feeOnSpecified(params.amountSpecified, t.platformFeeBps);
        // Never consume the whole specified amount: a swap the hook swallowed would be a NoOp swap.
        if (exactIn && fee >= OZSafeCast.toUint256(-params.amountSpecified)) revert SwapTooSmall();
        _book(id, key, t, fee);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev When the Quote Asset is the unspecified currency the fee is taken here, once the pool's Quote
    ///      Asset amount is known: an exact-in sell (the pool's output, the fee taken from it) or an exact-out
    ///      buy (the pool's input, the trader pays the fee on top). When it is the specified currency this
    ///      only checks that the pool traded the whole amount the fee was taken on.
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Terms memory t = _termsOf(id);
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn == params.zeroForOne;
        int128 quoteDelta = t.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
        if (specifiedIsCurrency0 == t.quoteIsCurrency0) {
            // The fee was taken in `_beforeSwap`, on the whole specified amount, so the pool must have
            // traded all of it. A swap its own price limit stopped early would have paid the fee on
            // Quote Asset it never traded, so it is refused; the same trade with the coin as the specified
            // side goes through, since its fee is taken below on what really moved.
            int256 feeTaken = OZSafeCast.toInt256(_feeOnSpecified(params.amountSpecified, t.platformFeeBps));
            if (int256(quoteDelta) != params.amountSpecified + feeTaken) revert SwapStoppedEarly();
            return (this.afterSwap.selector, 0);
        }

        uint256 fee;
        if (exactIn) {
            // A sell: the pool owes the trader `quoteDelta` (positive), the gross, before the fee.
            fee = quoteDelta > 0 ? _feeOnGross(OZSafeCast.toUint256(quoteDelta), t.platformFeeBps) : 0;
        } else {
            // A buy: the trader owes the pool `-quoteDelta`, the net, before the fee.
            fee = quoteDelta < 0 ? _feeOnNet(OZSafeCast.toUint256(-int256(quoteDelta)), t.platformFeeBps) : 0;
        }
        if (fee == 0) return (this.afterSwap.selector, 0);
        _book(id, key, t, fee);
        return (this.afterSwap.selector, fee.toInt128());
    }

    /// @dev Takes `fee` of the Quote Asset as this hook's claims and records it as two Credits.
    ///      The claims are minted against the delta the hook is owed by the swap, so nothing is transferred.
    function _book(PoolId id, PoolKey calldata key, Terms memory t, uint256 fee) internal {
        if (fee == 0) return;
        Currency currency = t.quoteIsCurrency0 ? key.currency0 : key.currency1;
        poolManager.mint(address(this), currency.toId(), fee);
        uint256 creatorCredit = fee * t.creatorShareBps / BPS;
        uint256 platformCredit = fee - creatorCredit;
        _credits[t.creatorDestination][currency] += creatorCredit;
        _credits[platform][currency] += platformCredit;
        totalCredits[currency] += fee;
        // The only call before it is the PoolManager's own `mint`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeeCredited(id, currency, t.creatorDestination, fee, creatorCredit, platformCredit);
    }

    /// @dev The fee when the Quote Asset is the swap's specified currency: on the gross for an exact-in buy
    ///      (a negative amount), on the net for an exact-out sell (a positive one).
    function _feeOnSpecified(int256 amountSpecified, uint16 feeBps) internal pure returns (uint256) {
        return amountSpecified < 0
            ? _feeOnGross(OZSafeCast.toUint256(-amountSpecified), feeBps)
            : _feeOnNet(OZSafeCast.toUint256(amountSpecified), feeBps);
    }

    /// @dev 1.00% (or the Launch's rate) of a known gross amount, rounded up in the platform's favour.
    function _feeOnGross(uint256 gross, uint16 feeBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(gross, feeBps, BPS);
    }

    /// @dev The fee on a known net amount, so that it is the rate of net plus fee, rounded up.
    function _feeOnNet(uint256 net, uint16 feeBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(net, feeBps, BPS - feeBps);
    }

    function _termsOf(PoolId id) internal view returns (Terms memory t) {
        t = _terms[id];
        if (!t.registered) revert NotRegistered();
    }

    // ------------------------------------------------------------------ the Payout Call

    /// @notice Pays each owner's whole Credit in `currency` to that owner, and to nobody else. Anyone may
    ///         call it, for any owners; the Keeper calls it on a schedule, and an owner may pull their own.
    ///         An owner the currency refuses keeps their Credit, and the others are still paid.
    /// @dev An ERC-20 is paid by the PoolManager's `take` inside the unlock, which calls the asset and no
    ///      recipient. The native asset is paid by a call to the recipient, so it is paid only once the
    ///      PoolManager is locked again: see `_payoutNative`.
    function payout(Currency currency, address[] calldata owners) external {
        if (_payoutLocked()) revert PayoutReentered();
        _setPayoutLock(true);
        if (currency.isAddressZero()) {
            _payoutNative(owners);
        } else {
            // The callback returns nothing worth reading; every outcome is an event.
            // forge-lint: disable-next-line(unused-return)
            poolManager.unlock(abi.encode(Action.PayERC20, abi.encode(currency, owners)));
        }
        _setPayoutLock(false);
    }

    /// @dev The native asset's Payout Call, in three steps (#242):
    ///      1. Every owner's Credit is cleared and their sum taken out of the PoolManager into this hook, in
    ///         one unlock, against the hook's claims.
    ///      2. With the PoolManager locked again, each owner is sent their Credit by a call carrying
    ///         `NATIVE_PAYOUT_GAS` (all the gas there is when the owner is the caller, pulling their own).
    ///         A recipient that reverts, re-enters or burns its gas fails its own call alone: its Credit is
    ///         added back to it. A re-entering recipient meets a locked PoolManager, so it cannot swap or
    ///         take as a recipient paid inside an unlock could, and this function's own guard.
    ///      3. What was refused goes back into the PoolManager as the hook's claims, in a second unlock, so
    ///         the claims again back every Credit one for one and the hook keeps no native asset.
    ///      `take` of the native asset inside the unlock would call the recipient with all the gas left and
    ///      the PoolManager unlocked: a recipient could burn the batch's gas, or leave a delta of its own
    ///      that reverts everyone's payment. Neither is possible here.
    function _payoutNative(address[] calldata owners) internal {
        uint256[] memory amounts = new uint256[](owners.length);
        uint256 total;
        for (uint256 i; i < owners.length; i++) {
            uint256 amount = _credits[owners[i]][NATIVE];
            if (amount == 0) continue;
            _credits[owners[i]][NATIVE] = 0;
            amounts[i] = amount;
            total += amount;
        }
        if (total == 0) return;
        totalCredits[NATIVE] -= total;
        // forge-lint: disable-next-line(unused-return)
        poolManager.unlock(abi.encode(Action.TakeNative, abi.encode(total)));

        uint256 refused;
        for (uint256 i; i < owners.length; i++) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            address owner = owners[i];
            bool paid;
            if (owner == msg.sender) {
                // An owner pulling their own may spend all the gas they brought on receiving it.
                assembly ("memory-safe") {
                    paid := call(gas(), owner, amount, 0, 0, 0, 0)
                }
            } else {
                // Never let a caller starve a recipient into a refusal: without the full allowance in hand
                // the whole call reverts and every Credit stays as it was.
                if (gasleft() < NATIVE_PAYOUT_GAS * 64 / 63 + NATIVE_CALL_OVERHEAD) revert PayoutGasTooLow();
                // No return data is copied, so a recipient's revert reason costs the caller nothing.
                assembly ("memory-safe") {
                    paid := call(NATIVE_PAYOUT_GAS, owner, amount, 0, 0, 0, 0)
                }
            }
            if (paid) {
                // forge-lint: disable-next-line(reentrancy-events)
                emit CreditPaid(owner, NATIVE, amount);
            } else {
                // Added back, never overwritten: a Credit booked meanwhile by a swap is kept.
                _credits[owner][NATIVE] += amount;
                refused += amount;
                // forge-lint: disable-next-line(reentrancy-events)
                emit CreditRefused(owner, NATIVE, amount);
            }
        }
        if (refused > 0) {
            totalCredits[NATIVE] += refused;
            // forge-lint: disable-next-line(unused-return)
            poolManager.unlock(abi.encode(Action.ReturnNative, abi.encode(refused)));
        }
    }

    /// @dev Runs inside the hook's own unlocks, from `payout` alone.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.PayERC20) {
            (Currency currency, address[] memory owners) = abi.decode(args, (Currency, address[]));
            _payERC20(currency, owners);
        } else if (action == Action.TakeNative) {
            uint256 total = abi.decode(args, (uint256));
            poolManager.burn(address(this), NATIVE.toId(), total);
            poolManager.take(NATIVE, address(this), total);
        } else {
            uint256 refused = abi.decode(args, (uint256));
            // A recipient paid in step 2 may have left the PoolManager synced to an ERC-20, which would
            // make a native settle revert; syncing the native asset clears it.
            poolManager.sync(NATIVE);
            // forge-lint: disable-next-line(unused-return)
            poolManager.settle{value: refused}();
            poolManager.mint(address(this), NATIVE.toId(), refused);
        }
        return "";
    }

    /// @dev Each payment is isolated: a failed `take` rolls back that payment alone and the Credit is
    ///      restored. The Credit is cleared before the transfer and the claims burned after it, and a
    ///      restored Credit is added back, never overwritten, so a Credit recorded by a swap made inside
    ///      the transfer (only a hostile Quote Asset could) is kept. The loop's calls are the PoolManager's
    ///      and the Quote Asset's; the caller pays for as many owners as they pass.
    function _payERC20(Currency currency, address[] memory owners) internal {
        uint256 id = currency.toId();
        for (uint256 i; i < owners.length; i++) {
            address owner = owners[i];
            uint256 amount = _credits[owner][currency];
            if (amount == 0) continue;
            _credits[owner][currency] = 0;
            totalCredits[currency] -= amount;
            // forge-lint: disable-next-line(reentrancy-no-eth, calls-loop)
            try poolManager.take(currency, owner, amount) {
                // forge-lint: disable-next-line(calls-loop)
                poolManager.burn(address(this), id, amount);
                // forge-lint: disable-next-line(reentrancy-events)
                emit CreditPaid(owner, currency, amount);
            } catch {
                _credits[owner][currency] += amount;
                totalCredits[currency] += amount;
                // forge-lint: disable-next-line(reentrancy-events)
                emit CreditRefused(owner, currency, amount);
            }
        }
    }

    /// @dev The PoolManager pays the hook the native asset in step 1 of `_payoutNative`; nobody else may,
    ///      so every wei the hook ever holds is a Credit on its way out.
    receive() external payable onlyPoolManager {}

    function _payoutLocked() internal view returns (bool locked) {
        assembly ("memory-safe") {
            locked := tload(PAYOUT_LOCK_SLOT)
        }
    }

    function _setPayoutLock(bool locked) internal {
        assembly ("memory-safe") {
            tstore(PAYOUT_LOCK_SLOT, locked)
        }
    }

    // ------------------------------------------------------------------ views

    /// @notice The Credit `owner` is owed in `currency`.
    function creditOf(address owner, Currency currency) external view returns (uint256) {
        return _credits[owner][currency];
    }

    /// @notice A Launch's terms, by its pool.
    function termsOf(PoolId id) external view returns (Terms memory) {
        return _terms[id];
    }
}
