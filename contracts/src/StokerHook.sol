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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @notice What the hook reads from the Tax Vault at its deployment: where the holders' part goes.
interface IHoldersPartHolder {
    function distributor() external view returns (address);
}

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
///         The Creator's share of the Platform Fee follows the Creator Ladder (#248, ADR 0027): the first
///         Creator Tier's share with no key involved, and the ladder key may raise one coin's tier to the
///         second or the third and can do nothing else. The hook keeps, per coin, a running total of what
///         its swaps have credited its Creator Earnings Destination (`creatorCreditedOf`), so a Destination
///         contract that serves many coins can tell their earnings apart.
///
///         Every Launch opens with an Opening Fee (#246, ADR 0026): for its first seconds a buy pays an extra
///         fee, falling in a straight line to nothing, minted to the Tax Vault as claims with a running total
///         per pool (`openingFeeBooked`), all of it the coin's Support Liquidity. The Creator's First Buy is
///         exempt; sells never pay it; no Credit grows by it.
///
///         It keeps a Reference Price for every pool (#271): a price that follows the pool's price slowly,
///         by how long each price has stood, so the Tax Vault never spends at a price that was only just
///         reached (`referenceTick`). Every pool, since anyone may fund any coin's burn or Support Liquidity
///         in the Tax Vault (#248), a standard coin's among them.
///
///         The hook also guards the pool: only the factory opens a pool on it, only the factory and the Tax
///         Vault add liquidity to it, no liquidity is ever removed, and donations are refused.
///
///         It keeps each coin's Graduation Hold (#244, ADR 0024): the time the price its transactions have
///         left has stood at or above the Graduation Target, unbroken; an hour of it graduates the coin, once
///         and for good. A swap inside a transaction is never judged on its own, only the price the whole
///         transaction leaves, so a round trip inside one transaction, in either direction, neither forces
///         nor resets the hold.
/// @dev Reads the clock through `block.timestamp` only (the Opening Fee, #246; the Reference Price, #271), never
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

    /// @notice Where the Admin is read: the platform's share of every Platform Fee is booked to the Admin of
    ///         the moment the fee is taken (ADR 0030).
    StokerKeys public immutable keys;

    /// @notice The Tax Vault: it receives every Reward Tax and Stoke Tax as claims, and is the only address
    ///         beside the factory that may add liquidity to a pool on this hook (Support Liquidity, #245).
    address public immutable taxVault;

    /// @notice The Distributor the Tax Vault hands the holders' part to (#247), read from the Tax Vault at
    ///         deployment: with the Tax Vault, an address no trade may name as its referrer (#248).
    address public immutable distributor;

    /// @notice The Creator Ladder's tiers (ADR 0020, ADR 0027): every coin starts on the first, and the
    ///         ladder key may raise it to the second or the top.
    uint8 public constant FIRST_TIER = 1;
    uint8 public constant TOP_TIER = 3;

    /// @notice How fast a pool's Reference Price may follow the pool's price (#271), in ticks per minute
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
    /// @param creatorShareBps The Creator's share of the Platform Fee on the Creator Ladder's first tier, which
    ///        every coin holds from launch with no key involved (ADR 0027).
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
    /// @param launchedAt The Launch's own second, `block.timestamp` when its terms were registered, written by
    ///        the hook itself whatever the factory passes (#246).
    /// @param openingFeeStartBps What a buy's fees take together at the launch's own second (99.00%): the
    ///        Opening Fee is the part above the Launch's standing fees (#246, ADR 0026).
    /// @param openingFeeDuration The seconds over which the Opening Fee falls in a straight line to nothing.
    /// @param secondTierShareBps The Creator's share on the second Creator Tier (#248).
    /// @param topTierShareBps The Creator's share on the top Creator Tier.
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
        uint64 launchedAt;
        uint16 openingFeeStartBps;
        uint32 openingFeeDuration;
        uint16 secondTierShareBps;
        uint16 topTierShareBps;
    }

    mapping(PoolId => Terms) internal _terms;

    /// @notice A coin's own state on the Creator Ladder, beside its terms (#248).
    /// @param raised How many tiers above the first the ladder key has raised the coin: 0, 1 or 2. It only
    ///        ever grows.
    /// @param credited Every Credit this pool's swaps have recorded to its Creator Earnings Destination, in
    ///        its Quote Asset, since launch. It only ever grows, and no call but a swap moves it.
    struct CreatorBook {
        uint8 raised;
        uint248 credited;
    }

    mapping(PoolId => CreatorBook) internal _creatorBooks;

    /// @notice Credits owed, by owner and Quote Asset.
    mapping(address owner => mapping(Currency currency => uint256)) internal _credits;

    /// @notice The sum of every Credit owed in a currency, equal to this hook's claims on it.
    mapping(Currency currency => uint256) public totalCredits;

    /// @notice Every Reward Tax or Stoke Tax a pool's swaps have paid, in its Quote Asset, since launch. Each
    ///         one was minted to the Tax Vault as claims in the same swap, so it is the Tax Vault's exact book
    ///         of what that coin's tax gave it.
    mapping(PoolId => uint256) public taxBooked;

    /// @notice Every Opening Fee a pool's buys have paid, in its Quote Asset, since launch (#246). Each one was
    ///         minted to the Tax Vault as claims in the same swap, so it is the Tax Vault's exact book of what
    ///         that coin's Opening Fee gave it, all of it Support Liquidity.
    mapping(PoolId => uint256) public openingFeeBooked;

    /// @notice A pool's Reference Price (#271), as the last swap left it.
    /// @param scaledTick The price, as a pool tick in sixty-thousandths of a tick.
    /// @param updatedAt When it was last moved: the time of the last swap in the pool, or zero before the
    ///        pool's first swap.
    struct Reference {
        int64 scaledTick;
        uint40 updatedAt;
    }

    mapping(PoolId => Reference) internal _references;

    /// @notice How long a coin's price must stay at or above its Graduation Target, without a break, before
    ///         the coin graduates: the Graduation Hold (ADR 0024, the owner's hour).
    uint64 public constant GRADUATION_HOLD = 1 hours;

    /// @notice A coin's Graduation Hold and its Graduation (#244), as last judged. The hook judges the price a
    ///         transaction left when the next transaction first swaps the pool, or when `graduate` is called,
    ///         so `holdSince` here can lag the price by one transaction; `graduationNow` judges it now.
    /// @param holdSince When the transaction that left the price at or above the target was made, if the
    ///        price has stood there since; zero while it stands under. Kept once the coin has graduated: the
    ///        hold that graduated it.
    /// @param graduatedAt When the coin graduated, `holdSince` plus the hour, whoever recorded it and
    ///        however late; zero until then, and never changed after.
    /// @param lastSwapAt When a transaction last swapped the pool: since then the price it left has stood.
    struct Graduation {
        uint64 holdSince;
        uint64 graduatedAt;
        uint64 lastSwapAt;
    }

    mapping(PoolId => Graduation) internal _graduations;

    /// @dev Whether a pool has been swapped in this transaction, in transient storage (EIP-1153): the base of
    ///      each pool's slot, keccak256("stoker.hook.swappedThisTransaction") - 1.
    bytes32 internal constant SWAPPED_SLOT = bytes32(uint256(keccak256("stoker.hook.swappedThisTransaction")) - 1);

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
    /// @notice The three shares of a Launch's Creator Ladder, written with the rest of its terms (#248).
    event CreatorLadderRegistered(
        PoolId indexed poolId, uint16 firstTierShareBps, uint16 secondTierShareBps, uint16 topTierShareBps
    );
    /// @notice The ladder key raised a coin's Creator Tier: from this block the Creator's part of every
    ///         Platform Fee its swaps pay is `creatorShareBps`.
    event CreatorTierRaised(PoolId indexed poolId, uint8 fromTier, uint8 toTier, uint16 creatorShareBps);
    /// @notice One swap's Reward Tax or Stoke Tax, minted to the Tax Vault as claims.
    event TaxBooked(PoolId indexed poolId, Currency indexed currency, uint256 tax);
    /// @notice A Launch's Opening Fee terms (#246): from `launchedAt` a buy's fees take `startBps` together,
    ///         the Opening Fee falling to nothing over `duration` seconds.
    event OpeningFeeTermsRegistered(PoolId indexed poolId, uint64 launchedAt, uint16 startBps, uint32 duration);
    /// @notice One buy's Opening Fee, minted to the Tax Vault as claims (#246).
    event OpeningFeeBooked(PoolId indexed poolId, Currency indexed currency, uint256 fee);
    event CreditPaid(address indexed owner, Currency indexed currency, uint256 amount);
    /// @notice The Quote Asset refused to pay `owner` (a blocklist, a pause); the Credit stays owed to it.
    event CreditRefused(address indexed owner, Currency indexed currency, uint256 amount);
    /// @notice A swap left the price at or above the Graduation Target with no hold running: the hour runs
    ///         from `since`.
    event GraduationHoldStarted(PoolId indexed poolId, uint256 since);
    /// @notice A swap left the price under the Graduation Target: the hold that ran from `since` is over, and
    ///         the next one starts the hour again.
    event GraduationHoldCleared(PoolId indexed poolId, uint256 since);
    /// @notice The coin graduated at `graduatedAt`, an hour after the hold that began at `holdSince`. Emitted
    ///         once per coin, by the first swap or public call after the hour.
    event Graduated(PoolId indexed poolId, uint256 graduatedAt, uint256 holdSince);

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
    /// @notice A trade named this hook, the factory, the PoolManager, the Tax Vault or the Distributor as its
    ///         referrer, none of which can be paid usefully.
    error InvalidReferrer(address referrer);
    /// @notice A raise by anyone but the ladder key of the moment; a revoked key reads as nobody.
    error NotLadderKey();
    /// @notice A raise to the tier the coin holds or to one below it, or past the top.
    error InvalidTier(uint8 current, uint8 asked);
    /// @notice A raise by the Admin, which appoints the ladder key and never raises itself: an Admin that
    ///         named itself the ladder key still cannot.
    error AdminCannotRaise();
    /// @notice A raise for a coin whose Graduation is not recorded. Active Days are counted from Graduation
    ///         (ADR 0027), so no coin can have reached a tier before it.
    error NotGraduated();
    /// @notice The coin has graduated already; Graduation is recorded once.
    error AlreadyGraduated();
    /// @notice The price has not stood at or above the target for the hour; `holdSince` is zero when no hold
    ///         is running.
    error GraduationHoldNotComplete(uint256 holdSince);
    /// @notice `graduate` was called in a transaction that has swapped the pool, whose price is not yet one a
    ///         transaction has left.
    error SwappedThisTransaction();

    constructor(IPoolManager poolManager_, StokerKeys keys_, address taxVault_) BaseHook(poolManager_) {
        if (address(keys_) == address(0) || taxVault_ == address(0)) revert ZeroAddress();
        factory = msg.sender;
        keys = keys_;
        taxVault = taxVault_;
        distributor = IHoldersPartHolder(taxVault_).distributor();
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
        // The Launch's own second is the hook's to read: the Opening Fee runs from it (#246).
        t.launchedAt = OZSafeCast.toUint64(block.timestamp);
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
        emit OpeningFeeTermsRegistered(id, t.launchedAt, t.openingFeeStartBps, t.openingFeeDuration);
        emit CreatorLadderRegistered(id, t.creatorShareBps, t.secondTierShareBps, t.topTierShareBps);
    }

    // ------------------------------------------------------------------ the Creator Ladder's key (#248)

    /// @notice Raises one coin's Creator Tier to the second or the top, by the ladder key of the moment alone
    ///         (`keys.holderOf(Role.LadderKey)`, so a replacement or a revoke takes effect at once), and only
    ///         for a coin whose Graduation is recorded. From this block the Creator's part of every Platform
    ///         Fee the coin's swaps pay is the new tier's share, as written in the Launch's terms; what the
    ///         trader pays does not change, and nothing already credited moves. This is the whole of the key's
    ///         power: it cannot lower a tier, raise past the top, raise a coin that has not graduated, or
    ///         touch a pool, a Seed Position, a Credit or a coin's terms.
    /// @dev The Admin appoints the ladder key and is refused by name, as the Distributor refuses the Guard
    ///      as the round key: a cold key that could raise would be one more power on the hardware wallet, and
    ///      an Admin that named itself the key would otherwise hold it. The Graduation read is the recorded
    ///      one (`graduationOf(id).graduatedAt`), so a coin whose hold has run its hour is raised only after
    ///      a swap or `graduate` has recorded it.
    /// @param tier The tier to raise the coin to: 2 or 3, above the one it holds.
    function raiseTier(PoolId id, uint8 tier) external {
        // A revoked key reads as nobody, which no caller is.
        if (msg.sender != keys.holderOf(StokerKeys.Role.LadderKey)) revert NotLadderKey();
        if (msg.sender == keys.admin()) revert AdminCannotRaise();
        Terms memory t = _termsOf(id);
        // Active Days are counted from Graduation, so a raise before it is never one the ladder asks for:
        // refusing it bounds a stolen key to coins that have graduated.
        if (_graduations[id].graduatedAt == 0) revert NotGraduated();
        uint8 current = FIRST_TIER + _creatorBooks[id].raised;
        if (tier <= current || tier > TOP_TIER) revert InvalidTier(current, tier);
        _creatorBooks[id].raised = tier - FIRST_TIER;
        // The calls before it are our own keys' views.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CreatorTierRaised(id, current, tier, _tierShareBps(t, tier - FIRST_TIER));
    }

    /// @dev The Creator's share of the Platform Fee on a tier, from the Launch's own terms: no share is a
    ///      constant of this contract.
    function _tierShareBps(Terms memory t, uint8 raised) internal pure returns (uint16) {
        if (raised == 0) return t.creatorShareBps;
        return raised == 1 ? t.secondTierShareBps : t.topTierShareBps;
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
    ///      are the Platform Fee, the Referrer Fee and the Launch's tax (#245), each its own rate, and on a buy
    ///      inside the Launch's opening seconds the Opening Fee (#246).
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Terms memory t = _termsOf(id);
        // Before the pool moves, and ahead of every return below. The Reference Price (#271) and the Graduation
        // Hold (#244) each read the price that has stood since the last swap and write only their own record,
        // so their order changes nothing: the reference credits the time since the last swap to that price,
        // and a pool's first swap in a transaction judges the hold by the price the last transaction left.
        // Every pool keeps a reference, a standard coin's too (#248).
        _followReference(id, t.quoteIsCurrency0);
        _judgeHold(id, t);
        (address referrer, uint256 referrerBps) = _referral(hookData, t);
        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsCurrency0 = exactIn == params.zeroForOne;
        if (specifiedIsCurrency0 != t.quoteIsCurrency0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 taxBps = _taxBps(sender, t);
        // The quote side specified is a buy when exact in; an exact-out sell never pays the Opening Fee.
        uint256 openingBps = exactIn ? _openingBps(sender, t, taxBps) : 0;
        referrerBps = _referrerBpsUnderTheStart(t, referrerBps, taxBps, openingBps);
        (uint256 fee, uint256 referrerFee, uint256 tax, uint256 opening) =
            _feesOnSpecified(params.amountSpecified, t.platformFeeBps, referrerBps, taxBps, openingBps);
        uint256 taken = fee + referrerFee + tax + opening;
        // Never consume the whole specified amount: a swap the hook swallowed would be a NoOp swap.
        if (exactIn && taken >= OZSafeCast.toUint256(-params.amountSpecified)) revert SwapTooSmall();
        _book(id, key, t, fee, referrer, referrerFee);
        _bookTax(id, key, t, tax);
        _bookOpeningFee(id, key, t, opening);
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
            // The same block, so the same Opening Fee as `_beforeSwap` took, on an exact-in buy alone.
            uint256 openingBps = exactIn ? _openingBps(sender, t, taxBps) : 0;
            (uint256 feeTaken, uint256 referrerFeeTaken, uint256 taxTaken, uint256 openingTaken) = _feesOnSpecified(
                params.amountSpecified,
                t.platformFeeBps,
                _referrerBpsUnderTheStart(t, referrerBps, taxBps, openingBps),
                taxBps,
                openingBps
            );
            if (
                int256(quoteDelta)
                    != params.amountSpecified
                        + OZSafeCast.toInt256(feeTaken + referrerFeeTaken + taxTaken + openingTaken)
            ) {
                revert SwapStoppedEarly();
            }
            return (this.afterSwap.selector, 0);
        }

        uint256 fee = 0;
        uint256 referrerFee = 0;
        uint256 tax = 0;
        uint256 opening = 0;
        if (exactIn) {
            // A sell: the pool owes the trader `quoteDelta` (positive), the gross, before the fees. A sell
            // never pays the Opening Fee.
            if (quoteDelta > 0) {
                uint256 gross = OZSafeCast.toUint256(quoteDelta);
                (fee, referrerFee, tax, opening) = _feesOnGross(gross, t.platformFeeBps, referrerBps, taxBps, 0);
                // Never more than the pool pays out: the trader would pay to sell. Only a referrer's fee or a
                // tax beside the Platform Fee can reach past a gross of 1, so a swap with neither is untouched.
                if (fee + referrerFee + tax + opening > gross) revert SwapTooSmall();
            }
        } else if (quoteDelta < 0) {
            // A buy: the trader owes the pool `-quoteDelta`, the net, before the fees, and inside the Launch's
            // opening seconds the Opening Fee on top.
            uint256 net = OZSafeCast.toUint256(-int256(quoteDelta));
            uint256 openingBps = _openingBps(sender, t, taxBps);
            (fee, referrerFee, tax, opening) = _feesOnNet(
                net, t.platformFeeBps, _referrerBpsUnderTheStart(t, referrerBps, taxBps, openingBps), taxBps, openingBps
            );
        }
        uint256 taken = fee + referrerFee + tax + opening;
        if (taken == 0) return (this.afterSwap.selector, 0);
        _book(id, key, t, fee, referrer, referrerFee);
        _bookTax(id, key, t, tax);
        _bookOpeningFee(id, key, t, opening);
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
        // The Creator's share is the share of the tier the coin holds now (#248); the platform's is the rest.
        CreatorBook memory book = _creatorBooks[id];
        uint256 creatorCredit = fee * _tierShareBps(t, book.raised) / BPS;
        uint256 platformCredit = fee - creatorCredit;
        _credits[t.creatorDestination][currency] += creatorCredit;
        if (creatorCredit > 0) {
            // At most the fee, which fits an int128; the sum is checked.
            // forge-lint: disable-next-line(unsafe-typecast)
            _creatorBooks[id].credited = book.credited + uint248(creatorCredit);
        }
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
        if (
            referrer == address(this) || referrer == factory || referrer == address(poolManager) || referrer == taxVault
                || referrer == distributor
        ) revert InvalidReferrer(referrer);
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

    /// @dev The four fees when the Quote Asset is the swap's specified currency (the Platform Fee, the
    ///      Referrer Fee, the tax and the Opening Fee): of the gross for an exact-in buy (a negative amount), on
    ///      the net for an exact-out sell (a positive one, whose `openingBps` is zero).
    function _feesOnSpecified(
        int256 amountSpecified,
        uint16 feeBps,
        uint256 referrerBps,
        uint256 taxBps,
        uint256 openingBps
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        if (amountSpecified < 0) {
            return _feesOnGross(OZSafeCast.toUint256(-amountSpecified), feeBps, referrerBps, taxBps, openingBps);
        }
        return _feesOnNet(OZSafeCast.toUint256(amountSpecified), feeBps, referrerBps, taxBps, openingBps);
    }

    /// @dev The four fees of a known gross amount. Outside the window each is its rate of it, rounded up.
    ///      Inside it (an Opening Fee rate above zero) the Platform Fee and the tax are their rates, rounded
    ///      up; the Opening Fee is what those two rates and its own take together, rounded up once, less the
    ///      two as each was rounded; and the Referrer Fee (its rate already held to the room under the start
    ///      figure) is what adding its rate to the three takes beyond that. So inside the window a buy pays
    ///      its combined rate rounded up once, the Opening Fee is the same to the wei whether or not a
    ///      referrer is named, and naming one costs the buyer exactly the referrer's fee.
    function _feesOnGross(uint256 gross, uint16 feeBps, uint256 referrerBps, uint256 taxBps, uint256 openingBps)
        internal
        pure
        returns (uint256 fee, uint256 referrerFee, uint256 tax, uint256 opening)
    {
        fee = _feeOnGross(gross, feeBps);
        tax = _feeOnGross(gross, taxBps);
        if (openingBps == 0) return (fee, _feeOnGross(gross, referrerBps), tax, 0);
        uint256 withoutReferrer = _feeOnGross(gross, uint256(feeBps) + taxBps + openingBps);
        opening = _openingRest(withoutReferrer, fee + tax);
        referrerFee = _feeOnGross(gross, uint256(feeBps) + taxBps + openingBps + referrerBps) - withoutReferrer;
    }

    /// @dev The four fees of a gross amount known only as its net: each its rate of net plus every fee, by
    ///      the same split as `_feesOnGross` inside the window (the Opening Fee from the Platform Fee's, the
    ///      tax's and its own rates rounded once, the Referrer Fee what its rate adds beyond them). The
    ///      Platform Fee thus stays 1.00% of what the buyer pays, the Opening Fee included, as on an exact-in
    ///      buy of the same amount.
    function _feesOnNet(uint256 net, uint16 feeBps, uint256 referrerBps, uint256 taxBps, uint256 openingBps)
        internal
        pure
        returns (uint256 fee, uint256 referrerFee, uint256 tax, uint256 opening)
    {
        uint256 totalBps = uint256(feeBps) + referrerBps + taxBps + openingBps;
        fee = _feeOnNet(net, feeBps, totalBps);
        tax = _feeOnNet(net, taxBps, totalBps);
        if (openingBps == 0) return (fee, _feeOnNet(net, referrerBps, totalBps), tax, 0);
        uint256 withoutReferrer = _feeOnNet(net, uint256(feeBps) + taxBps + openingBps, totalBps);
        opening = _openingRest(withoutReferrer, fee + tax);
        referrerFee = _feeOnNet(net, totalBps, totalBps) - withoutReferrer;
    }

    /// @dev What the combined rate takes beyond the Platform Fee and the tax, never below zero: on a buy too
    ///      small for their own roundings to leave room, the Opening Fee is nothing and the buy pays those.
    function _openingRest(uint256 allTaken, uint256 standing) internal pure returns (uint256) {
        return allTaken > standing ? allTaken - standing : 0;
    }

    /// @dev The Opening Fee's rate on a buy at this second (#246, ADR 0026), read from the Launch's own terms
    ///      and the block's time alone: at the launch's own second the buy's fees together take
    ///      `openingFeeStartBps`, the Opening Fee being the part above the Platform Fee and the tax the buy
    ///      pays, and that part falls in a straight line to nothing at `openingFeeDuration` seconds, rounded
    ///      up to the basis point, so it never rises with time and never passes the start figure. A Referrer
    ///      Fee is never counted here: it takes only the room the schedule has left (see
    ///      `_referrerBpsUnderTheStart`), so naming a referrer never lowers the Opening Fee. The Creator's
    ///      First Buy, the one swap the factory ever makes, inside the launch, is exempt; `sender` is compared
    ///      with the factory and read for nothing else. Every block of one second reads the same rate.
    function _openingBps(address sender, Terms memory t, uint256 taxBps) internal view returns (uint256) {
        if (sender == factory) return 0;
        uint256 duration = t.openingFeeDuration;
        uint256 end = uint256(t.launchedAt) + duration;
        // Time is the only clock these contracts read; a sequencer's skew of seconds moves the fee by as much.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= end) return 0;
        uint256 standing = uint256(t.platformFeeBps) + taxBps;
        if (t.openingFeeStartBps <= standing) return 0;
        // Never more than the whole duration, so the start figure bounds the fee even on a clock that ran back.
        uint256 left = Math.min(end - block.timestamp, duration);
        return Math.ceilDiv((t.openingFeeStartBps - standing) * left, duration);
    }

    /// @dev The Referrer Fee a buy pays, its rate: outside the window (an Opening Fee rate of zero) the rate
    ///      the trade named, whole; inside it no more than the room the Platform Fee, the tax and the Opening
    ///      Fee leave under the start figure. So at the launch's own second it is nothing, it grows as the
    ///      schedule falls, it is whole once the schedule has fallen far enough, and the fees together never
    ///      pass the start figure. A referrer is credited only what the buyer pays on top for naming it, and
    ///      never a share of the Opening Fee (#246 review).
    function _referrerBpsUnderTheStart(Terms memory t, uint256 referrerBps, uint256 taxBps, uint256 openingBps)
        internal
        pure
        returns (uint256)
    {
        if (openingBps == 0) return referrerBps;
        // `_openingBps` returned above zero, so the start figure is above the Platform Fee and the tax, and
        // never below them and the Opening Fee together.
        uint256 room = uint256(t.openingFeeStartBps) - t.platformFeeBps - taxBps - openingBps;
        return Math.min(referrerBps, room);
    }

    /// @dev Mints `opening` of the Quote Asset to the Tax Vault as claims, against the delta the hook is owed
    ///      by the swap, and adds it to the pool's running total of Opening Fees, which the vault adds to the
    ///      coin's Support Liquidity alone. No Credit grows by it.
    function _bookOpeningFee(PoolId id, PoolKey calldata key, Terms memory t, uint256 opening) internal {
        if (opening == 0) return;
        Currency currency = t.quoteIsCurrency0 ? key.currency0 : key.currency1;
        poolManager.mint(taxVault, currency.toId(), opening);
        openingFeeBooked[id] += opening;
        // The only call before it is the PoolManager's own `mint`.
        // forge-lint: disable-next-line(reentrancy-events)
        emit OpeningFeeBooked(id, currency, opening);
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

    // ------------------------------------------------------------------ the Graduation Hold

    /// @notice Records the coin's Graduation once the price its transactions have left has stood at or above
    ///         the Graduation Target for the hour, when no swap has come to record it. Anyone may call it; the
    ///         Keeper does. It reverts for a pool that is not a Launch's, a coin already graduated, a hold
    ///         short of the hour or not running (a price left under the target never graduates, whatever was
    ///         judged before), and inside a transaction that has swapped the pool.
    function graduate(PoolId id) external {
        Terms memory t = _termsOf(id);
        if (_swappedThisTransaction(id)) revert SwappedThisTransaction();
        Graduation memory g = _graduations[id];
        if (g.graduatedAt != 0) revert AlreadyGraduated();
        Graduation memory judged = _judged(g, _atOrAbove(id, t));
        if (judged.graduatedAt == 0) revert GraduationHoldNotComplete(judged.holdSince);
        _graduations[id] = judged;
        _emitJudgement(id, g, judged);
    }

    /// @dev Called by every swap in a Launch's pool, before the pool moves. Only a pool's first swap in a
    ///      transaction judges: the price standing then is the one the last transaction to swap the pool left,
    ///      at `lastSwapAt` (only a swap moves a v4 pool's price; added liquidity never does, and removals and
    ///      donations are refused). The swaps after it in the same transaction are not judged, so a flash
    ///      round trip, across the target and back or under it and back, leaves the hold exactly where the
    ///      price it ends at says, as if it had never been made.
    function _judgeHold(PoolId id, Terms memory t) internal {
        if (_swappedThisTransaction(id)) return;
        bytes32 slot = _swappedSlot(id);
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        Graduation memory g = _graduations[id];
        Graduation memory judged = _judged(g, _atOrAbove(id, t));
        // A timestamp, which fits 64 bits for 584 billion years.
        // forge-lint: disable-next-line(unsafe-typecast)
        judged.lastSwapAt = uint64(block.timestamp);
        _graduations[id] = judged;
        _emitJudgement(id, g, judged);
    }

    /// @dev The record judged against the price standing now, which has stood since `g.lastSwapAt`: under the
    ///      target, no hold; at or above it, the hold that runs, or one from `lastSwapAt`; and a hold that has
    ///      run the hour graduates the coin at the hour's end, so the same hold graduates it at the same moment
    ///      whoever records it and however late. The hour is the clock's: a sequencer's few seconds move it by
    ///      as much and no more.
    function _judged(Graduation memory g, bool atOrAbove) internal view returns (Graduation memory j) {
        j = _copy(g);
        if (j.graduatedAt != 0) return j;
        if (!atOrAbove) {
            j.holdSince = 0;
            return j;
        }
        if (j.holdSince == 0) j.holdSince = j.lastSwapAt;
        // forge-lint: disable-next-line(block-timestamp)
        if (j.holdSince != 0 && block.timestamp >= j.holdSince + GRADUATION_HOLD) {
            j.graduatedAt = j.holdSince + GRADUATION_HOLD;
        }
    }

    function _emitJudgement(PoolId id, Graduation memory before, Graduation memory j) internal {
        // The only call before these events is the PoolManager's `extsload` view of the price.
        if (before.holdSince != j.holdSince) {
            // forge-lint: disable-next-line(reentrancy-events)
            if (before.holdSince != 0) emit GraduationHoldCleared(id, before.holdSince);
            // forge-lint: disable-next-line(reentrancy-events)
            if (j.holdSince != 0) emit GraduationHoldStarted(id, j.holdSince);
        }
        // forge-lint: disable-next-line(reentrancy-events)
        if (before.graduatedAt == 0 && j.graduatedAt != 0) emit Graduated(id, j.graduatedAt, j.holdSince);
    }

    /// @dev Whether the pool's price now stands at or above its Graduation Target. The pool's price is currency1
    ///      per currency0: with the coin as currency0 a dearer coin is a higher price; with the Quote Asset as
    ///      currency0 (the native asset always is) it is a lower one.
    function _atOrAbove(PoolId id, Terms memory t) internal view returns (bool) {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, id);
        return t.quoteIsCurrency0 ? sqrtPriceX96 <= t.graduationSqrtPriceX96 : sqrtPriceX96 >= t.graduationSqrtPriceX96;
    }

    function _swappedSlot(PoolId id) internal pure returns (bytes32) {
        return keccak256(abi.encode(SWAPPED_SLOT, id));
    }

    function _swappedThisTransaction(PoolId id) internal view returns (bool swapped) {
        bytes32 slot = _swappedSlot(id);
        assembly ("memory-safe") {
            swapped := tload(slot)
        }
    }

    function _copy(Graduation memory g) internal pure returns (Graduation memory) {
        return Graduation({holdSince: g.holdSince, graduatedAt: g.graduatedAt, lastSwapAt: g.lastSwapAt});
    }

    // ------------------------------------------------------------------ the Reference Price (#271)

    /// @dev Called by every swap in a pool of ours before the pool moves. Every pool keeps a Reference Price
    ///      for its whole life, a standard coin's too. #271 kept one for taxed pools, and #246 for every pool
    ///      while its Opening Fee ran and after it only if one was booked. Since #248 the Tax Vault spends
    ///      for any coin that anyone has funded, at any time, and a reference that stopped being followed
    ///      would, when next read, have caught up with whatever price stood then, a lifted one among them. So
    ///      it is followed from the pool's first swap and never stops. The pool's price now is the one that
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

    /// @notice A pool's Reference Price now, as a pool tick: where the next swap would find it, the time
    ///         since the last swap credited to the price that stood. Rounded toward the cheaper coin. A pool
    ///         that has not traded yet answers its own tick, the price it opened at.
    function referenceTick(PoolId id) external view returns (int24) {
        Terms memory t = _termsOf(id);
        (, int24 tick,,) = StateLibrary.getSlot0(poolManager, id);
        Reference memory r = _references[id];
        if (r.updatedAt == 0) return tick;
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

    /// @notice A coin's Creator Tier now: 1 from launch, 2 or 3 once the ladder key has raised it (#248).
    function creatorTierOf(PoolId id) external view returns (uint8) {
        return FIRST_TIER + _creatorBooks[id].raised;
    }

    /// @notice The Creator's share of every Platform Fee the coin's swaps pay now, in basis points: its
    ///         tier's share, from the Launch's terms.
    function creatorShareOf(PoolId id) external view returns (uint16) {
        return _tierShareBps(_terms[id], _creatorBooks[id].raised);
    }

    /// @notice Every Credit this pool's swaps have recorded to its Creator Earnings Destination since launch,
    ///         in its Quote Asset, paid or not. A Destination that serves several coins reads each coin's
    ///         earnings here, since a Credit is booked by address and asset and not by pool.
    function creatorCreditedOf(PoolId id) external view returns (uint256) {
        return _creatorBooks[id].credited;
    }

    /// @notice A Launch's Graduation Hold and its Graduation as last judged, by its pool (#244). The hold
    ///         can lag the price by one transaction, and a hold that has run the hour reads as running until a
    ///         swap or a call records Graduation; `graduatedAt` here is the recorded one, which a Creator Lock
    ///         reads.
    function graduationOf(PoolId id) external view returns (Graduation memory) {
        return _graduations[id];
    }

    /// @notice The same record judged against the price standing now, as the next transaction to swap the
    ///         pool or a call to `graduate` would leave it: the hold the price has kept, and the Graduation
    ///         such a call would record. Read inside a transaction that has swapped the pool, it judges a price
    ///         that transaction has not yet left.
    function graduationNow(PoolId id) external view returns (Graduation memory) {
        Terms memory t = _termsOf(id);
        return _judged(_graduations[id], _atOrAbove(id, t));
    }

    /// @notice Where the platform's share of a Platform Fee taken now is booked: the Admin's address.
    function platform() external view returns (address) {
        return keys.admin();
    }
}
