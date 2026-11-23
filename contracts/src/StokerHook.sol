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
    error ZeroAddress();

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
        uint256 fee;
        if (exactIn) {
            uint256 gross = OZSafeCast.toUint256(-params.amountSpecified);
            fee = _feeOnGross(gross, t.platformFeeBps);
            // Never consume the whole specified amount: a swap the hook swallowed would be a NoOp swap.
            if (fee >= gross) revert SwapTooSmall();
        } else {
            fee = _feeOnNet(OZSafeCast.toUint256(params.amountSpecified), t.platformFeeBps);
        }
        _book(id, key, t, fee);
        return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev When the Quote Asset is the unspecified currency the fee is taken here, once the pool's Quote
    ///      Asset amount is known: an exact-in sell (the pool's output, the fee taken from it) or an exact-out
    ///      buy (the pool's input, the trader pays the fee on top).
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        Terms memory t = _termsOf(id);
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn == params.zeroForOne;
        if (specifiedIsCurrency0 == t.quoteIsCurrency0) return (this.afterSwap.selector, 0);

        int128 quoteDelta = t.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
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
    function payout(Currency currency, address[] calldata owners) external {
        // The callback returns nothing worth reading; every outcome is an event.
        // forge-lint: disable-next-line(unused-return)
        poolManager.unlock(abi.encode(currency, owners));
    }

    /// @dev Each payment is isolated: a failed `take` rolls back that payment alone and the Credit is
    ///      restored. The Credit is cleared before the transfer and the claims burned after it, and a
    ///      restored Credit is added back, never overwritten, so a Credit recorded by a swap made inside
    ///      the transfer (only a hostile Quote Asset could) is kept. The loop's calls are the PoolManager's
    ///      and the Quote Asset's; the caller pays for as many owners as they pass.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Currency currency, address[] memory owners) = abi.decode(data, (Currency, address[]));
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
        return "";
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
