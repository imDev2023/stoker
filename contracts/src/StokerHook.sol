// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
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

import {StokerKeys} from "./StokerKeys.sol";
import {IReferenceSettings} from "./interfaces/IReferenceSettings.sol";

/// @title StokerHook
/// @notice The Uniswap v4 hook of every Stoker coin's pool on an EVM chain. It keeps the books and does
///         nothing else (ADR 0025): on every swap it takes the Platform Fee on the Quote Asset's side and
///         records it as Credits, the Creator's share to the Launch's Creator Earnings Destination and the
///         rest to the platform (the Admin's address, ADR 0030). A trade may name a referrer and a Referrer
///         Fee up to its Launch's cap in its `hookData`; that fee is taken on top, on the same side, and
///         recorded as the referrer's Credit (ADR 0027). It calls no recipient, buys nothing and adds no
///         liquidity inside a swap.
///
///         The fees stay in the PoolManager as this hook's ERC-6909 claims, which back every Credit one
///         for one; the hook never holds an ERC-20. A Payout Call, which anyone can make, pays Credits to
///         their owners, and a Credit owed to an address the Quote Asset refuses stays owed to it.
///
///         A Reward Launch's Reward Tax and a Stoke Launch's Stoke Tax (#245) are taken beside these fees, on
///         the same side, and minted as ERC-6909 claims to the Tax Vault, with a running total per pool
///         (`taxBooked`); the hook does nothing else with them inside a swap.
///
///         It keeps a Reference Price for every taxed pool (#271): a price that follows the pool's price
///         slowly, by how long each price has stood, so the Tax Vault never spends a coin's tax at a price
///         that was only just reached (`referenceTick`).
///
///         The hook also guards the pool: only the factory opens a pool on it, only the factory and the Tax
///         Vault add liquidity to it, no liquidity is ever removed, and donations are refused.
/// @dev Reads the clock through `block.timestamp` only, never `block.number`, which is an estimate of the
///      L1 block on Robinhood Chain and Arbitrum.
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

    /// @notice Where the Admin is read: the platform's share of every Platform Fee is booked to the Admin of
    ///         the moment the fee is taken (ADR 0030).
    StokerKeys public immutable keys;

    /// @notice The Tax Vault: it receives every Reward Tax and Stoke Tax as claims, and is the only address
    ///         beside the factory that may add liquidity to a pool on this hook (Support Liquidity, #245).
    address public immutable taxVault;

    /// @notice How fast a taxed pool's Reference Price may follow the pool's price (#271), in ticks per minute
    ///         the price stood: slowly toward a dearer coin, faster toward a cheaper one. Read from the Tax
    ///         Vault at deployment and fixed.
    uint24 internal immutable referenceRiseTicksPerMinute;
    uint24 internal immutable referenceFallTicksPerMinute;

    /// @dev A Reference Price is kept in sixty-thousandths of a tick, so that a rate in ticks a minute times
    ///      the seconds elapsed moves it exactly (a thousandth of the rate per second), with no rounding.
    int256 internal constant REFERENCE_SCALE = 60_000;

    /// @notice The three Launch types (#231 story 8). `Liquidity` is the Stoke Launch.
    enum LaunchType {
        Standard,
        Reward,
        Liquidity
    }

    /// @notice What a Reward Launch's holders are paid in (ADR 0029): the Quote Asset as it was collected,
    ///         or the coin, bought with the holders' part by the Tax Vault's capped buy.
    enum PayoutAsset {
        QuoteAsset,
        Coin
    }

    /// @notice A Launch's terms, written once by the factory before its pool opens and never changed: every
    ///         figure of its Listing is copied here, so no write to the Quote Registry reaches a launched coin.
    /// @param creatorDestination The Creator Earnings Destination credited with the Creator's share.
    /// @param platformFeeBps The Platform Fee, of the Quote Asset's side of every swap.
    /// @param creatorShareBps The Creator's share of the Platform Fee (the Creator Ladder's tier, ADR 0027).
    /// @param referrerFeeCapBps The most a trade may name as its Referrer Fee (the Listing's cap at launch).
    /// @param quoteIsCurrency0 Which side of the pool the Quote Asset is.
    /// @param startTick The Listing's start price at launch, as a tick of Quote Asset per coin.
    /// @param graduationMultiple The Listing's Graduation multiple at launch.
    /// @param graduationSqrtPriceX96 The Graduation Target, the start price times the multiple, as the pool's
    ///        own sqrt price (#244 reads it; with the Quote Asset as currency0 the pool's price falls as the
    ///        coin's rises, so the target is below the open price there).
    /// @param launchType Standard, Reward or Liquidity (the Stoke Launch).
    /// @param taxBps The Reward Tax or the Stoke Tax, of the Quote Asset's side of every swap; 0 on a
    ///        standard Launch.
    /// @param burnShareBps The Reward Burn's share of the tax.
    /// @param liquidityShareBps The share of the tax that becomes Support Liquidity: the Reward Liquidity's
    ///        on a Reward Launch, all of it on a Stoke Launch. The rest is the holders' part.
    /// @param payoutAsset A Reward Launch's Payout Asset.
    struct Terms {
        address creatorDestination;
        uint16 platformFeeBps;
        uint16 creatorShareBps;
        uint16 referrerFeeCapBps;
        bool quoteIsCurrency0;
        bool registered;
        int24 startTick;
        uint16 graduationMultiple;
        uint160 graduationSqrtPriceX96;
        LaunchType launchType;
        uint16 taxBps;
        uint16 burnShareBps;
        uint16 liquidityShareBps;
        PayoutAsset payoutAsset;
    }

    mapping(PoolId => Terms) internal _terms;

    /// @notice Credits owed, by owner and Quote Asset.
    mapping(address owner => mapping(Currency currency => uint256)) internal _credits;

    /// @notice The sum of every Credit owed in a currency, equal to this hook's claims on it.
    mapping(Currency currency => uint256) public totalCredits;

    /// @notice Every Reward Tax or Stoke Tax a pool's swaps have paid, in its Quote Asset, since launch. Each
    ///         one was minted to the Tax Vault as claims in the same swap, so it is the Tax Vault's exact book
    ///         of what that coin's tax gave it.
    mapping(PoolId => uint256) public taxBooked;

    /// @notice A taxed pool's Reference Price (#271), as the last swap left it.
    /// @param scaledTick The price, as a pool tick in sixty-thousandths of a tick.
    /// @param updatedAt When it was last moved: the time of the last swap in the pool, or zero before the
    ///        pool's first swap.
    struct Reference {
        int64 scaledTick;
        uint40 updatedAt;
    }

    mapping(PoolId => Reference) internal _references;

    event LaunchRegistered(
        PoolId indexed poolId,
        address indexed creatorDestination,
        uint16 platformFeeBps,
        uint16 creatorShareBps,
        uint16 referrerFeeCapBps,
        bool quoteIsCurrency0,
        int24 startTick,
        uint16 graduationMultiple,
        uint160 graduationSqrtPriceX96
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
    /// @notice One swap's Referrer Fee, taken on top of the Platform Fee and credited to the referrer the
    ///         trade named.
    event ReferrerFeeCredited(PoolId indexed poolId, Currency indexed currency, address indexed referrer, uint256 fee);
    /// @notice A Launch's tax terms, written with the rest of its terms.
    event TaxTermsRegistered(
        PoolId indexed poolId,
        LaunchType launchType,
        uint16 taxBps,
        uint16 burnShareBps,
        uint16 liquidityShareBps,
        PayoutAsset payoutAsset
    );
    /// @notice One swap's Reward Tax or Stoke Tax, minted to the Tax Vault as claims.
    event TaxBooked(PoolId indexed poolId, Currency indexed currency, uint256 tax);
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
    /// @notice A trade's `hookData` was neither empty nor exactly a referrer and a Referrer Fee.
    error MalformedHookData();
    /// @notice A trade named a Referrer Fee over its Launch's cap.
    error ReferrerFeeOverCap(uint256 feeBps, uint16 capBps);
    /// @notice A trade named this hook, the factory or the PoolManager as its referrer, none of which can be
    ///         paid usefully.
    error InvalidReferrer(address referrer);

    constructor(IPoolManager poolManager_, StokerKeys keys_, address taxVault_) BaseHook(poolManager_) {
        if (address(keys_) == address(0) || taxVault_ == address(0)) revert ZeroAddress();
        factory = msg.sender;
        keys = keys_;
        taxVault = taxVault_;
        // The Tax Vault holds the settings of the price it trusts; the hook keeps them as its own.
        referenceRiseTicksPerMinute = IReferenceSettings(taxVault_).referenceRiseTicksPerMinute();
        referenceFallTicksPerMinute = IReferenceSettings(taxVault_).referenceFallTicksPerMinute();
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
        emit LaunchRegistered(
            id,
            t.creatorDestination,
            t.platformFeeBps,
            t.creatorShareBps,
            t.referrerFeeCapBps,
            t.quoteIsCurrency0,
            t.startTick,
            t.graduationMultiple,
            t.graduationSqrtPriceX96
        );
        emit TaxTermsRegistered(id, t.launchType, t.taxBps, t.burnShareBps, t.liquidityShareBps, t.payoutAsset);
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
        // The factory places the Seed Position; the Tax Vault adds Support Liquidity (#245). Neither has code
        // that removes liquidity, and the hook refuses every removal below in any case.
        if (sender != factory && sender != taxVault) revert OnlyFactory();
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

    /// @dev When the Quote Asset is the swap's specified currency the fees are taken here, on the specified
    ///      amount: an exact-in buy (the trader pays the amount, fees included) or an exact-out sell (the
    ///      trader receives the amount, the pool pays the fees on top). A trade's referrer is read here for
    ///      every swap, so a malformed `hookData` or a fee over the cap reverts before the pool runs. The fees
    ///      are the Platform Fee, the Referrer Fee and the Launch's tax (#245), each its own rate.
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Terms memory t = _termsOf(id);
        // Before the pool moves: the price it reads is the one that has stood since the last swap.
        if (_keepsReference(t)) _followReference(id, t.quoteIsCurrency0);
        (address referrer, uint256 referrerBps) = _referral(hookData, t);
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn == params.zeroForOne;
        if (specifiedIsCurrency0 != t.quoteIsCurrency0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        (uint256 fee, uint256 referrerFee, uint256 tax) =
            _feesOnSpecified(params.amountSpecified, t.platformFeeBps, referrerBps, _taxBps(sender, t));
        uint256 taken = fee + referrerFee + tax;
        // Never consume the whole specified amount: a swap the hook swallowed would be a NoOp swap.
        if (exactIn && taken >= OZSafeCast.toUint256(-params.amountSpecified)) revert SwapTooSmall();
        _book(id, key, t, fee, referrer, referrerFee);
        _bookTax(id, key, t, tax);
        return (this.beforeSwap.selector, toBeforeSwapDelta(taken.toInt128(), 0), 0);
    }

    /// @dev When the Quote Asset is the unspecified currency the fees are taken here, once the pool's Quote
    ///      Asset amount is known: an exact-in sell (the pool's output, the fees taken from it) or an exact-out
    ///      buy (the pool's input, the trader pays the fees on top). When it is the specified currency this
    ///      only checks that the pool traded the whole amount the fees were taken on.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        Terms memory t = _termsOf(id);
        (address referrer, uint256 referrerBps) = _referral(hookData, t);
        uint256 taxBps = _taxBps(sender, t);
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn == params.zeroForOne;
        int128 quoteDelta = t.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
        if (specifiedIsCurrency0 == t.quoteIsCurrency0) {
            // The fees were taken in `_beforeSwap`, on the whole specified amount, so the pool must have
            // traded all of it. A swap its own price limit stopped early would have paid them on Quote Asset
            // it never traded, so it is refused; the same trade with the coin as the specified side goes
            // through, since its fees are taken below on what really moved.
            (uint256 feeTaken, uint256 referrerFeeTaken, uint256 taxTaken) =
                _feesOnSpecified(params.amountSpecified, t.platformFeeBps, referrerBps, taxBps);
            if (
                int256(quoteDelta)
                    != params.amountSpecified + OZSafeCast.toInt256(feeTaken + referrerFeeTaken + taxTaken)
            ) {
                revert SwapStoppedEarly();
            }
            return (this.afterSwap.selector, 0);
        }

        uint256 fee = 0;
        uint256 referrerFee = 0;
        uint256 tax = 0;
        if (exactIn) {
            // A sell: the pool owes the trader `quoteDelta` (positive), the gross, before the fees.
            if (quoteDelta > 0) {
                uint256 gross = OZSafeCast.toUint256(quoteDelta);
                fee = _feeOnGross(gross, t.platformFeeBps);
                referrerFee = _feeOnGross(gross, referrerBps);
                tax = _feeOnGross(gross, taxBps);
                // Never more than the pool pays out: the trader would pay to sell. Only a referrer's fee or a
                // tax beside the Platform Fee can reach past a gross of 1, so a swap with neither is untouched.
                if (fee + referrerFee + tax > gross) revert SwapTooSmall();
            }
        } else if (quoteDelta < 0) {
            // A buy: the trader owes the pool `-quoteDelta`, the net, before the fees.
            uint256 net = OZSafeCast.toUint256(-int256(quoteDelta));
            uint256 totalBps = uint256(t.platformFeeBps) + referrerBps + taxBps;
            fee = _feeOnNet(net, t.platformFeeBps, totalBps);
            referrerFee = _feeOnNet(net, referrerBps, totalBps);
            tax = _feeOnNet(net, taxBps, totalBps);
        }
        uint256 taken = fee + referrerFee + tax;
        if (taken == 0) return (this.afterSwap.selector, 0);
        _book(id, key, t, fee, referrer, referrerFee);
        _bookTax(id, key, t, tax);
        return (this.afterSwap.selector, taken.toInt128());
    }

    /// @dev Takes `fee + referrerFee` of the Quote Asset as this hook's claims and records it as Credits:
    ///      the Platform Fee split between the Creator and the Admin of the moment, the Referrer Fee to the
    ///      referrer. The claims are minted against the delta the hook is owed by the swap, so nothing is
    ///      transferred.
    function _book(PoolId id, PoolKey calldata key, Terms memory t, uint256 fee, address referrer, uint256 referrerFee)
        internal
    {
        uint256 taken = fee + referrerFee;
        if (taken == 0) return;
        Currency currency = t.quoteIsCurrency0 ? key.currency0 : key.currency1;
        poolManager.mint(address(this), currency.toId(), taken);
        uint256 creatorCredit = fee * t.creatorShareBps / BPS;
        uint256 platformCredit = fee - creatorCredit;
        _credits[t.creatorDestination][currency] += creatorCredit;
        // The Admin of this moment: a handover changes where later shares are booked, never an earlier one.
        _credits[keys.admin()][currency] += platformCredit;
        totalCredits[currency] += taken;
        if (referrerFee > 0) {
            _credits[referrer][currency] += referrerFee;
            // The calls before it are the PoolManager's `mint` and our own keys' view.
            // forge-lint: disable-next-line(reentrancy-events)
            emit ReferrerFeeCredited(id, currency, referrer, referrerFee);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeeCredited(id, currency, t.creatorDestination, fee, creatorCredit, platformCredit);
    }

    /// @dev The trade's referrer and Referrer Fee from its `hookData`, which reaches the hook from any router
    ///      and any caller, so it is read defensively. Empty, it names nobody. Otherwise it must be exactly
    ///      `abi.encode(address referrer, uint256 feeBps)`: two words, the first a clean address, the second
    ///      at most the Launch's cap; anything else reverts by name and credits nobody. A fee of zero, or
    ///      the zero address with no fee, is no referrer. `sender` (the router) is never read.
    function _referral(bytes calldata hookData, Terms memory t) internal view returns (address, uint256) {
        if (hookData.length == 0) return (address(0), 0);
        if (hookData.length != 64) revert MalformedHookData();
        uint256 word0 = 0;
        uint256 feeBps = 0;
        assembly ("memory-safe") {
            word0 := calldataload(hookData.offset)
            feeBps := calldataload(add(hookData.offset, 32))
        }
        if (word0 >> 160 != 0) revert MalformedHookData();
        // Its upper 96 bits are zero by the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        address referrer = address(uint160(word0));
        if (feeBps > t.referrerFeeCapBps) revert ReferrerFeeOverCap(feeBps, t.referrerFeeCapBps);
        if (feeBps == 0) return (address(0), 0);
        if (referrer == address(0)) revert MalformedHookData();
        if (referrer == address(this) || referrer == factory || referrer == address(poolManager)) {
            revert InvalidReferrer(referrer);
        }
        return (referrer, feeBps);
    }

    /// @dev Mints `tax` of the Quote Asset to the Tax Vault as claims, against the delta the hook is owed by
    ///      the swap, and adds it to the pool's running total. Nothing is transferred and nothing is called
    ///      but the PoolManager's own `mint`, which cannot fail here.
    function _bookTax(PoolId id, PoolKey calldata key, Terms memory t, uint256 tax) internal {
        if (tax == 0) return;
        Currency currency = t.quoteIsCurrency0 ? key.currency0 : key.currency1;
        poolManager.mint(taxVault, currency.toId(), tax);
        taxBooked[id] += tax;
        // The only call before it is the PoolManager's own `mint`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TaxBooked(id, currency, tax);
    }

    /// @dev The tax a swap pays: the Launch's rate, except on the Tax Vault's own buys (the Reward Burn's
    ///      and a Payout Asset of the coin's), which pay the Platform Fee like any buy but no tax: taxing
    ///      the tax would send part of the burn's share back to the holders and the liquidity, mixing parts
    ///      the Launch fixed. `sender` is compared with the Tax Vault's address and never read otherwise.
    function _taxBps(address sender, Terms memory t) internal view returns (uint256) {
        return sender == taxVault ? 0 : t.taxBps;
    }

    /// @dev The three fees when the Quote Asset is the swap's specified currency (the Platform Fee, the
    ///      Referrer Fee and the tax): of the gross for an exact-in buy (a negative amount), on the net for an
    ///      exact-out sell (a positive one).
    function _feesOnSpecified(int256 amountSpecified, uint16 feeBps, uint256 referrerBps, uint256 taxBps)
        internal
        pure
        returns (uint256 fee, uint256 referrerFee, uint256 tax)
    {
        if (amountSpecified < 0) {
            uint256 gross = OZSafeCast.toUint256(-amountSpecified);
            return (_feeOnGross(gross, feeBps), _feeOnGross(gross, referrerBps), _feeOnGross(gross, taxBps));
        }
        uint256 net = OZSafeCast.toUint256(amountSpecified);
        uint256 totalBps = uint256(feeBps) + referrerBps + taxBps;
        return
            (_feeOnNet(net, feeBps, totalBps), _feeOnNet(net, referrerBps, totalBps), _feeOnNet(net, taxBps, totalBps));
    }

    /// @dev A rate of a known gross amount, rounded up in the platform's favour.
    function _feeOnGross(uint256 gross, uint256 feeBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(gross, feeBps, BPS);
    }

    /// @dev A rate of a gross amount known only as its net, when the fees taken from it together are
    ///      `totalBps`: so that each fee is its rate of net plus every fee, rounded up. With no referrer and
    ///      no tax `totalBps` is the Platform Fee alone, as before #243 and #245.
    function _feeOnNet(uint256 net, uint256 feeBps, uint256 totalBps) internal pure returns (uint256) {
        return FullMath.mulDivRoundingUp(net, feeBps, BPS - totalBps);
    }

    function _termsOf(PoolId id) internal view returns (Terms memory t) {
        t = _terms[id];
        if (!t.registered) revert NotRegistered();
    }

    // ------------------------------------------------------------------ the Reference Price (#271)

    /// @dev Whether a pool keeps a Reference Price: a taxed one, whose tax the Tax Vault spends. A standard
    ///      coin has nothing for the vault to spend, so its swaps skip it and pay nothing for it.
    function _keepsReference(Terms memory t) internal pure returns (bool) {
        return t.taxBps != 0;
    }

    /// @dev Called by every swap in a taxed pool before the pool moves. The pool's price now is the one that
    ///      has stood since the last swap (nothing else moves it: no removal, no donation, and the Tax Vault
    ///      adds Support Liquidity only beside the price), so the time since then is credited to it. A swap
    ///      in the same second as the last moves nothing, so a price lifted or dropped and undone inside one
    ///      block leaves no mark. The pool's first swap starts the reference at the price the pool opened at,
    ///      which has stood since the launch.
    function _followReference(PoolId id, bool quoteIsCurrency0) internal {
        Reference memory r = _references[id];
        // forge-lint: disable-next-line(block-timestamp)
        if (r.updatedAt == block.timestamp) return;
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        int256 next = r.updatedAt == 0 ? int256(tick) * REFERENCE_SCALE : _referenceNow(r, tick, quoteIsCurrency0);
        // A tick in sixty-thousandths fits 64 bits a hundred thousand times over; the time fits 40 bits
        // until the year 36812.
        _references[id] =
            Reference({scaledTick: OZSafeCast.toInt64(next), updatedAt: OZSafeCast.toUint40(block.timestamp)});
    }

    /// @dev Where the reference stands now, given the price that has stood since it was last moved: toward
    ///      that price by at most the rate times the seconds elapsed, rising slowly toward a dearer coin and
    ///      falling faster toward a cheaper one. With the coin as currency0 a dearer coin is a higher tick;
    ///      with the Quote Asset as currency0 (the native asset always is) a lower one.
    function _referenceNow(Reference memory r, int24 tick, bool quoteIsCurrency0) internal view returns (int256) {
        int256 target = int256(tick) * REFERENCE_SCALE;
        int256 current = r.scaledTick;
        if (target == current) return current;
        bool coinDearer = (target > current) != quoteIsCurrency0;
        uint256 rate = coinDearer ? referenceRiseTicksPerMinute : referenceFallTicksPerMinute;
        // A rate of ticks a minute is a thousandth of it a second in sixty-thousandths of a tick. At most
        // 2^24 * 2^40 * 1000, far inside 255 bits.
        int256 step = OZSafeCast.toInt256(rate * (block.timestamp - r.updatedAt) * 1_000);
        if (target > current) return current + step < target ? current + step : target;
        return current - step > target ? current - step : target;
    }

    /// @notice A taxed pool's Reference Price now, as a pool tick: where the next swap would find it, the time
    ///         since the last swap credited to the price that stood. Rounded toward the cheaper coin. A pool
    ///         that keeps none (a standard coin) or has not traded yet answers its own tick.
    function referenceTick(PoolId id) external view returns (int24) {
        Terms memory t = _termsOf(id);
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        Reference memory r = _references[id];
        if (!_keepsReference(t) || r.updatedAt == 0) return tick;
        int256 scaled = _referenceNow(r, tick, t.quoteIsCurrency0);
        int256 whole = scaled / REFERENCE_SCALE;
        // Solidity divides toward zero; the cheaper coin is the lower tick with the coin as currency0 and the
        // higher one with the Quote Asset as currency0.
        int256 rest = scaled % REFERENCE_SCALE;
        if (!t.quoteIsCurrency0 && rest < 0) whole -= 1;
        if (t.quoteIsCurrency0 && rest > 0) whole += 1;
        return OZSafeCast.toInt24(whole);
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
    ///         take inside the hook's unlock as a recipient paid there could, and this function's own guard.
    ///         It can open an unlock of its own and trade as anyone can (an owner pulling their own has the
    ///         gas for it); that trade books its Credits beside this call's, which only ever adds.
    ///      3. What was refused goes back into the PoolManager as the hook's claims, in a second unlock, so
    ///         the claims again back every Credit one for one and the hook keeps no native asset.
    ///      `take` of the native asset inside the unlock would call the recipient with all the gas left and
    ///      the PoolManager unlocked: a recipient could burn the batch's gas, or leave a delta of its own
    ///      that reverts everyone's payment. Neither is possible here.
    function _payoutNative(address[] calldata owners) internal {
        uint256[] memory amounts = new uint256[](owners.length);
        uint256 total = 0;
        for (uint256 i; i < owners.length; i++) {
            uint256 amount = _credits[owners[i]][NATIVE];
            if (amount == 0) continue;
            _credits[owners[i]][NATIVE] = 0;
            amounts[i] = amount;
            total += amount;
        }
        if (total == 0) return;
        totalCredits[NATIVE] -= total;
        // The call is the PoolManager's, which calls back only this hook's own `unlockCallback`; a Credit
        // is written after it only to add back a refused payment, never to overwrite one.
        // forge-lint: disable-next-line(unused-return, reentrancy-no-eth)
        poolManager.unlock(abi.encode(Action.TakeNative, abi.encode(total)));

        uint256 refused = 0;
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
                // the whole call reverts and every Credit stays as it was, which is why it reverts in the loop.
                // forge-lint: disable-next-line(require-revert-in-loop)
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
    /// @dev Read from inside a native payment of the same Payout Call (a recipient's own code), it answers
    ///      zero for every owner of that call not yet paid or refused: a contract that acts on a Credit
    ///      must not do so from inside a payment.
    function creditOf(address owner, Currency currency) external view returns (uint256) {
        return _credits[owner][currency];
    }

    /// @notice A Launch's terms, by its pool.
    function termsOf(PoolId id) external view returns (Terms memory) {
        return _terms[id];
    }

    /// @notice Where the platform's share of a Platform Fee taken now is booked: the Admin's address.
    function platform() external view returns (address) {
        return keys.admin();
    }
}
