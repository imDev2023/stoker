// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast as OZSafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {StokerCoin} from "./StokerCoin.sol";
import {StokerHook} from "./StokerHook.sol";
import {StokerCreatorLock} from "./StokerCreatorLock.sol";
import {TaxVault} from "./TaxVault.sol";
import {IQuoteListings} from "./interfaces/IQuoteListings.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";

/// @title StokerFactory
/// @notice Launches a Stoker coin on an EVM chain by Direct Seed (ADR 0024), in one transaction: it
///         deploys the coin, opens its Uniswap v4 pool against a listed Quote Asset at the Listing's start
///         price, places the whole supply in the pool as the Seed Position, and makes the Creator's First
///         Buy. The factory holds every Seed Position and has no code that removes liquidity; the hook
///         refuses every removal in any case.
/// @dev No owner, no setter, no proxy and no pause. Its own settings are fixed at deployment and the
///      Listing's figures are read at launch, and both are written into each Launch's terms; a later
///      deployment, or a later write to the Quote Registry, changes them for later Launches only.
contract StokerFactory is IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant SUPPLY = 1e12 * 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice The largest Creator Lock: a fifth of the supply (ADR 0024, as on Solana, ADR 0023).
    uint16 public constant MAX_CREATOR_LOCK_BPS = 2_000;
    /// @notice The shortest Creator Lock, cliff and unlock time together, counted from Graduation.
    uint256 public constant MIN_CREATOR_LOCK_TIME = 7 days;
    /// @notice The longest cliff, and the longest unlock time, a Creator Lock may have (Solana's four years).
    uint256 public constant MAX_CREATOR_LOCK_PART = 4 * 365 days;

    IPoolManager public immutable poolManager;
    StokerHook public immutable hook;
    /// @notice The chain's Quote Registry, where each Quote Asset's Listing is read at launch (ADR 0028).
    QuoteRegistry public immutable registry;
    /// @notice The Platform Fee written into every Launch, in basis points of the Quote Asset's side.
    uint16 public immutable platformFeeBps;
    /// @notice The Creator's share of the Platform Fee written into every Launch: the Creator Ladder's first
    ///         tier (ADR 0027). Never the launcher's to choose.
    uint16 public immutable creatorShareBps;
    /// @notice The Creator's share on the Creator Ladder's second and top tiers, written into every Launch
    ///         beside the first (#248); a coin reaches them only by the ladder key's raise.
    uint16 public immutable secondTierShareBps;
    uint16 public immutable topTierShareBps;
    /// @notice The Tax Vault and the Distributor: with the hook, this factory and the PoolManager, the
    ///         addresses no Launch may name as its Creator Earnings Destination (#248).
    address public immutable taxVault;
    address public immutable distributor;
    /// @notice The tick spacing of every pool this factory opens: the registry's, which every start price
    ///         is a multiple of.
    int24 public immutable tickSpacing;
    /// @notice What a buy's fees take together at a Launch's own second, written into every Launch (#246,
    ///         ADR 0026): 9,900 is 99.00%. The Opening Fee is the part above the Launch's standing fees.
    uint16 public immutable openingFeeStartBps;
    /// @notice The seconds over which every Launch's Opening Fee falls in a straight line to nothing (#246).
    uint32 public immutable openingFeeDuration;

    /// @notice The highest start figure a deployment may set: a buy always keeps at least 1% of itself.
    uint16 public constant MAX_OPENING_FEE_START_BPS = 9_900;
    /// @notice The longest Opening Fee a deployment may set: a fee that never fell would stop a coin trading.
    uint32 public constant MAX_OPENING_FEE_DURATION = 10 minutes;

    /// @notice A Launch's own facts, as the factory recorded them.
    struct Launch {
        address coin;
        address quote;
        address creator;
        int24 seedTickLower;
        int24 seedTickUpper;
    }

    /// @param name The coin's name.
    /// @param symbol The coin's ticker.
    /// @param quote The Quote Asset; it must be listed.
    /// @param salt The launcher's salt for the coin's CREATE2 address, hashed with the launcher's address.
    /// @param creatorDestination Where the Creator's share of every Platform Fee is credited; zero means the
    ///        Creator's own wallet. Fixed at launch; nobody can change it.
    /// @param firstBuy The Quote Asset the Creator spends on the First Buy, fee included; zero for none.
    ///        With the native asset as the Quote Asset it is the value the launch is sent, exactly.
    /// @param launchType Standard, Reward or Liquidity (the Stoke Launch), fixed at launch (#245).
    /// @param taxBps A Reward Launch's Reward Tax or a Stoke Launch's Stoke Tax: 1% to 5% in whole percents
    ///        (Solana's rates); zero on a standard Launch.
    /// @param burnShareBps A Reward Launch's Reward Burn share of the tax: none, a tenth, a quarter or half.
    /// @param liquidityShareBps A Reward Launch's Reward Liquidity share, on the same steps, the two together
    ///        at most half. Zero on a Stoke Launch, whose whole tax becomes Support Liquidity by its type.
    /// @param payoutAsset A Reward Launch's Payout Asset; the Quote Asset on the other two types.
    /// @param creatorLockBps The Creator Lock: the share of the supply held out of the Seed Position for the
    ///        Creator, in basis points, at most a fifth; zero for none (#244).
    /// @param creatorLockCliff Seconds from Graduation before any of the lock is released.
    /// @param creatorLockUnlock Seconds after the cliff over which the lock is released in a straight line;
    ///        zero releases it all at the cliff's end. With the cliff, at least seven days.
    struct LaunchParams {
        string name;
        string symbol;
        address quote;
        bytes32 salt;
        address creatorDestination;
        uint256 firstBuy;
        StokerHook.LaunchType launchType;
        uint16 taxBps;
        uint16 burnShareBps;
        uint16 liquidityShareBps;
        StokerHook.PayoutAsset payoutAsset;
        uint16 creatorLockBps;
        uint32 creatorLockCliff;
        uint32 creatorLockUnlock;
    }

    /// @notice An ERC-2612 permit by the Creator for the factory, for the First Buy's amount.
    struct PermitSignature {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Seed {
        PoolKey key;
        address coin;
        address quote;
        address creator;
        bool quoteIsCurrency0;
        int24 tickLower;
        int24 tickUpper;
        uint256 firstBuy;
        uint256 seedCoins;
    }

    mapping(PoolId => Launch) internal _launches;

    /// @notice A Launch's Creator Lock contract, by its pool; zero for a Launch with none (#244).
    mapping(PoolId => address) public creatorLockOf;

    event Launched(
        PoolId indexed poolId,
        address indexed coin,
        address indexed creator,
        address quote,
        address creatorDestination,
        int24 startTick,
        uint128 seedLiquidity,
        uint256 firstBuy,
        uint256 firstBuyCoins
    );
    /// @notice A Launch's Creator Lock: `amount` coins held by `lock` for `creator`, released from Graduation
    ///         after `cliff` seconds and then over `unlock` seconds.
    event CreatorLocked(
        PoolId indexed poolId,
        address indexed lock,
        address indexed creator,
        uint256 amount,
        uint32 cliff,
        uint32 unlock
    );

    error InvalidSettings();
    error NotListed(address quote);
    error InvalidStartTick(int24 startTick);
    /// @notice The Listing's Graduation multiple gives no Graduation Target the pool can reach.
    error InvalidGraduationMultiple(uint16 graduationMultiple);
    error NotPoolManager();
    /// @notice A Creator Lock over a fifth of the supply, shorter than seven days, with a part over four
    ///         years, or a cliff or unlock time with no lock.
    error InvalidCreatorLock(uint16 bps, uint32 cliff, uint32 unlock);
    /// @notice The launch was sent value other than its native First Buy: any value with an ERC-20 Quote
    ///         Asset, or value that differs from `firstBuy` with the native asset.
    error ValueMismatch(uint256 expected, uint256 sent);
    /// @notice A tax off Solana's rates (1% to 5% in whole percents), or any tax on a standard Launch.
    error InvalidTaxRate(uint16 taxBps);
    /// @notice A burn or liquidity share off the steps (none, a tenth, a quarter, half), the two together over
    ///         half, or any share on a standard Launch or a Stoke Launch.
    error InvalidShares(uint16 burnShareBps, uint16 liquidityShareBps);
    /// @notice A Payout Asset of the coin on a Launch that has no holders' part.
    error InvalidPayoutAsset();
    /// @notice A Creator Earnings Destination that can never be paid usefully: the hook, this factory, the
    ///         PoolManager, the Tax Vault or the Distributor. None accepts the native asset from the Payout
    ///         Call, and an ERC-20 paid to one belongs to nobody there.
    error InvalidDestination(address destination);

    /// @param registry_ The chain's Quote Registry; its keys are the hook's (the platform's share is booked
    ///        to their Admin) and its tick spacing is every pool's.
    /// @param secondTierShareBps_ The Creator's share on the second Creator Tier, at least the first's.
    /// @param topTierShareBps_ The Creator's share on the top Creator Tier, at least the second's and at most
    ///        the whole Platform Fee, so a raise never lowers what a Creator is credited.
    /// @param hookSalt The CREATE2 salt that gives the hook an address carrying its permission bits.
    /// @param taxVault_ The Tax Vault, deployed beforehand for this factory's address (#245).
    /// @param openingFeeStartBps_ The Opening Fee's start figure, every buy's fees together at a Launch's own
    ///        second, at most 99.00% (#246).
    /// @param openingFeeDuration_ The seconds the Opening Fee runs, at least one and at most ten minutes.
    constructor(
        IPoolManager poolManager_,
        QuoteRegistry registry_,
        uint16 platformFeeBps_,
        uint16 creatorShareBps_,
        uint16 secondTierShareBps_,
        uint16 topTierShareBps_,
        bytes32 hookSalt,
        TaxVault taxVault_,
        uint16 openingFeeStartBps_,
        uint32 openingFeeDuration_
    ) {
        // Bounded so that no deployment can take most of a swap: at most 10% of the Quote Asset's side.
        if (platformFeeBps_ == 0 || platformFeeBps_ > 1_000) revert InvalidSettings();
        if (creatorShareBps_ > 10_000 || address(registry_) == address(0)) revert InvalidSettings();
        poolManager = poolManager_;
        registry = registry_;
        platformFeeBps = platformFeeBps_;
        creatorShareBps = creatorShareBps_;
        // The ladder only climbs: a tier's share is never below the one before it, nor above the whole fee.
        if (secondTierShareBps_ < creatorShareBps_ || topTierShareBps_ < secondTierShareBps_) revert InvalidSettings();
        if (topTierShareBps_ > 10_000) revert InvalidSettings();
        secondTierShareBps = secondTierShareBps_;
        topTierShareBps = topTierShareBps_;
        tickSpacing = registry_.tickSpacing();
        if (openingFeeStartBps_ == 0 || openingFeeStartBps_ > MAX_OPENING_FEE_START_BPS) revert InvalidSettings();
        if (openingFeeDuration_ == 0 || openingFeeDuration_ > MAX_OPENING_FEE_DURATION) revert InvalidSettings();
        openingFeeStartBps = openingFeeStartBps_;
        openingFeeDuration = openingFeeDuration_;
        // The Tax Vault reads this factory's hook and Seed Positions, so it must have been made for it.
        if (address(taxVault_) == address(0) || taxVault_.factory() != address(this)) revert InvalidSettings();
        taxVault = address(taxVault_);
        distributor = address(taxVault_.distributor());
        hook = new StokerHook{salt: hookSalt}(poolManager_, registry_.keys(), address(taxVault_));
    }

    // ------------------------------------------------------------------ launching

    /// @notice Launches a coin. A First Buy in an ERC-20 needs the Creator's allowance for the factory; a
    ///         First Buy in the native asset is the value sent with this call, so the launch is one
    ///         transaction and one signature (#242).
    function launch(LaunchParams calldata p) external payable returns (address coin, PoolId poolId) {
        return _launch(p);
    }

    /// @notice Launches a coin with the First Buy's allowance given by an ERC-2612 signature, in the same
    ///         transaction. A permit already used (someone submitted the signature first) does not stop the
    ///         launch while the allowance stands. Not payable: a permit is an ERC-20's, and a native First
    ///         Buy goes through `launch`.
    function launchWithPermit(LaunchParams calldata p, PermitSignature calldata s)
        external
        returns (address coin, PoolId poolId)
    {
        if (p.firstBuy > 0 && p.quote != address(0)) {
            try IERC20Permit(p.quote).permit(msg.sender, address(this), p.firstBuy, s.deadline, s.v, s.r, s.s) {}
                catch {}
        }
        return _launch(p);
    }

    function _launch(LaunchParams calldata p) internal returns (address coin, PoolId poolId) {
        IQuoteListings.Listing memory listing = registry.listingOf(p.quote);
        if (!listing.listed) revert NotListed(p.quote);
        // The factory keeps nothing it was not sent and refunds nothing: the value is the native First Buy
        // to the wei, and an ERC-20 launch takes none.
        uint256 expectedValue = p.quote == address(0) ? p.firstBuy : 0;
        if (msg.value != expectedValue) revert ValueMismatch(expectedValue, msg.value);
        int24 startTick = listing.startTick;
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        if (startTick % tickSpacing != 0 || startTick <= minUsable || startTick >= maxUsable) {
            revert InvalidStartTick(startTick);
        }

        coin = address(new StokerCoin{salt: keccak256(abi.encode(msg.sender, p.salt))}(p.name, p.symbol));
        address destination = p.creatorDestination == address(0) ? msg.sender : p.creatorDestination;
        _checkDestination(destination);

        Seed memory seed;
        seed.coin = coin;
        seed.quote = p.quote;
        seed.creator = msg.sender;
        seed.firstBuy = p.firstBuy;
        seed.quoteIsCurrency0 = p.quote < coin;
        seed.key = PoolKey({
            currency0: Currency.wrap(seed.quoteIsCurrency0 ? p.quote : coin),
            currency1: Currency.wrap(seed.quoteIsCurrency0 ? coin : p.quote),
            fee: 0,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        poolId = seed.key.toId();
        // The Creator Lock, when the launch asks for one, is held out of the Seed Position (#244).
        seed.seedCoins = SUPPLY - _lockForCreator(p, coin, poolId);

        // The pool's price is currency1 per currency0. With the coin as currency0 that is the start price
        // itself, and the seed spans from it upward; with the coin as currency1 it is the inverse, and the
        // seed spans from it downward. Either way the pool opens on the seed's edge, holding only coins.
        int24 openTick;
        if (seed.quoteIsCurrency0) {
            openTick = -startTick;
            (seed.tickLower, seed.tickUpper) = (minUsable, openTick);
        } else {
            openTick = startTick;
            (seed.tickLower, seed.tickUpper) = (openTick, maxUsable);
        }

        uint160 openSqrtPrice = TickMath.getSqrtPriceAtTick(openTick);
        StokerHook.Terms memory terms = StokerHook.Terms({
            creatorDestination: destination,
            platformFeeBps: platformFeeBps,
            creatorShareBps: creatorShareBps,
            referrerFeeCapBps: listing.referrerFeeCapBps,
            quoteIsCurrency0: seed.quoteIsCurrency0,
            registered: true,
            startTick: startTick,
            graduationMultiple: listing.graduationMultiple,
            graduationSqrtPriceX96: _graduationTarget(openSqrtPrice, listing.graduationMultiple, seed.quoteIsCurrency0),
            launchType: p.launchType,
            taxBps: 0,
            burnShareBps: 0,
            liquidityShareBps: 0,
            payoutAsset: StokerHook.PayoutAsset.QuoteAsset,
            // The hook writes the Launch's own second itself when it registers the terms.
            launchedAt: 0,
            openingFeeStartBps: openingFeeStartBps,
            openingFeeDuration: openingFeeDuration,
            secondTierShareBps: secondTierShareBps,
            topTierShareBps: topTierShareBps
        });
        _writeTaxTerms(terms, p);
        hook.registerLaunch(seed.key, terms);
        _launches[poolId] = Launch({
            coin: coin,
            quote: p.quote,
            creator: msg.sender,
            seedTickLower: seed.tickLower,
            seedTickUpper: seed.tickUpper
        });

        // The tick it returns is `openTick`, by construction.
        // forge-lint: disable-next-line(unused-return)
        poolManager.initialize(seed.key, openSqrtPrice);
        (uint128 liquidity, uint256 coinsBought) = abi.decode(poolManager.unlock(abi.encode(seed)), (uint128, uint256));

        // The calls before it are the PoolManager's, our hook's, the new coin's and the listed Quote Asset's.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Launched(poolId, coin, msg.sender, p.quote, destination, startTick, liquidity, p.firstBuy, coinsBought);
    }

    /// @dev Checks a Launch's type, tax and shares against Solana's steps (ADR 0025) and writes them into its
    ///      terms. A standard Launch has none; a Reward Launch has a tax of 1% to 5% in whole percents, a
    ///      burn and a liquidity share of none, a tenth, a quarter or half each, at most half together, and a
    ///      Payout Asset; a Stoke Launch has a tax and nothing else, and its whole tax becomes Support
    ///      Liquidity, so it has no holders' part.
    function _writeTaxTerms(StokerHook.Terms memory terms, LaunchParams calldata p) internal pure {
        if (p.launchType == StokerHook.LaunchType.Standard) {
            if (p.taxBps != 0) revert InvalidTaxRate(p.taxBps);
            if (p.burnShareBps != 0 || p.liquidityShareBps != 0) {
                revert InvalidShares(p.burnShareBps, p.liquidityShareBps);
            }
            if (p.payoutAsset != StokerHook.PayoutAsset.QuoteAsset) revert InvalidPayoutAsset();
            return;
        }
        if (p.taxBps < 100 || p.taxBps > 500 || p.taxBps % 100 != 0) revert InvalidTaxRate(p.taxBps);
        terms.taxBps = p.taxBps;
        if (p.launchType == StokerHook.LaunchType.Liquidity) {
            if (p.burnShareBps != 0 || p.liquidityShareBps != 0) {
                revert InvalidShares(p.burnShareBps, p.liquidityShareBps);
            }
            if (p.payoutAsset != StokerHook.PayoutAsset.QuoteAsset) revert InvalidPayoutAsset();
            terms.liquidityShareBps = 10_000;
            return;
        }
        if (
            !_onStep(p.burnShareBps) || !_onStep(p.liquidityShareBps)
                || uint256(p.burnShareBps) + p.liquidityShareBps > BPS / 2
        ) revert InvalidShares(p.burnShareBps, p.liquidityShareBps);
        terms.burnShareBps = p.burnShareBps;
        terms.liquidityShareBps = p.liquidityShareBps;
        terms.payoutAsset = p.payoutAsset;
    }

    /// @dev A Creator Earnings Destination is any address the launcher names, and the factory knows nothing
    ///      of what stands behind it (#248); it refuses only our own contracts that can never be paid usefully.
    function _checkDestination(address destination) internal view {
        if (
            destination == address(hook) || destination == address(this) || destination == address(poolManager)
                || destination == taxVault || destination == distributor
        ) revert InvalidDestination(destination);
    }

    /// @dev Solana's steps for the Reward Burn and the Reward Liquidity: none, a tenth, a quarter or half.
    function _onStep(uint16 shareBps) internal pure returns (bool) {
        return shareBps == 0 || shareBps == 1_000 || shareBps == 2_500 || shareBps == 5_000;
    }

    /// @dev Checks the launch's Creator Lock against the limits, and for a lock deploys its own contract and
    ///      sends it the locked coins. Returns how many it holds, zero for a launch with none.
    function _lockForCreator(LaunchParams calldata p, address coin, PoolId poolId) internal returns (uint256 locked) {
        (uint16 bps, uint32 cliff, uint32 unlock) = (p.creatorLockBps, p.creatorLockCliff, p.creatorLockUnlock);
        if (bps == 0) {
            if (cliff != 0 || unlock != 0) revert InvalidCreatorLock(bps, cliff, unlock);
            return 0;
        }
        if (
            bps > MAX_CREATOR_LOCK_BPS || uint256(cliff) + unlock < MIN_CREATOR_LOCK_TIME
                || cliff > MAX_CREATOR_LOCK_PART || unlock > MAX_CREATOR_LOCK_PART
        ) revert InvalidCreatorLock(bps, cliff, unlock);
        locked = SUPPLY * bps / 10_000;
        address lock = address(new StokerCreatorLock(IERC20(coin), hook, poolId, msg.sender, locked, cliff, unlock));
        creatorLockOf[poolId] = lock;
        IERC20(coin).safeTransfer(lock, locked);
        // The calls before it create our own lock and move our own new coin, which has no hooks.
        // forge-lint: disable-next-line(reentrancy-events)
        emit CreatorLocked(poolId, lock, msg.sender, locked, cliff, unlock);
    }

    /// @dev The Graduation Target as the pool's sqrt price: the start price times the multiple. The pool's
    ///      price is Quote Asset per coin with the coin as currency0, so the target is above the open price;
    ///      with the Quote Asset as currency0 it is coin per Quote Asset, and the target is below. Rounded so
    ///      the target is never a lower coin price than the multiple says (#244 records Graduation against it).
    function _graduationTarget(uint160 openSqrtPrice, uint16 multiple, bool quoteIsCurrency0)
        internal
        pure
        returns (uint160 target)
    {
        if (multiple < 2) revert InvalidGraduationMultiple(multiple);
        uint256 rootQ96 = Math.sqrt(uint256(multiple) << 192, Math.Rounding.Ceil);
        uint256 t = quoteIsCurrency0
            ? FullMath.mulDiv(openSqrtPrice, FixedPoint96.Q96, rootQ96)
            : FullMath.mulDivRoundingUp(openSqrtPrice, rootQ96, FixedPoint96.Q96);
        if (t <= TickMath.MIN_SQRT_PRICE || t >= TickMath.MAX_SQRT_PRICE) revert InvalidGraduationMultiple(multiple);
        // Bounded by the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        target = uint160(t);
    }

    /// @dev Runs inside the factory's own unlock: the PoolManager calls back the contract that unlocked it,
    ///      so the data is the factory's own.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Seed memory seed = abi.decode(data, (Seed));
        uint128 liquidity = _placeSeed(seed);
        uint256 coinsBought = seed.firstBuy > 0 ? _firstBuy(seed) : 0;
        return abi.encode(liquidity, coinsBought);
    }

    /// @dev Places the seed's coins, the supply less any Creator Lock, as one single-sided position and burns
    ///      the rounding dust left over, so every coin is in the pool, in the lock or, after the First Buy,
    ///      with the Creator.
    function _placeSeed(Seed memory seed) internal returns (uint128 liquidity) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(seed.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(seed.tickUpper);
        liquidity = seed.quoteIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, seed.seedCoins)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, seed.seedCoins);

        // A new position has accrued no fees, so the second value is zero.
        // forge-lint: disable-start(unused-return)
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            seed.key,
            ModifyLiquidityParams({
                tickLower: seed.tickLower,
                tickUpper: seed.tickUpper,
                liquidityDelta: uint256(liquidity).toInt256(),
                salt: bytes32(0)
            }),
            ""
        );
        // forge-lint: disable-end(unused-return)
        int128 coinDelta = seed.quoteIsCurrency0 ? delta.amount1() : delta.amount0();
        uint256 owed = OZSafeCast.toUint256(-int256(coinDelta));

        Currency coinCurrency = Currency.wrap(seed.coin);
        poolManager.sync(coinCurrency);
        IERC20(seed.coin).safeTransfer(address(poolManager), owed);
        // What it returns is `owed`; any shortfall would fail the unlock's own delta check.
        // forge-lint: disable-next-line(unused-return)
        poolManager.settle();

        uint256 dust = seed.seedCoins - owed;
        if (dust > 0) StokerCoin(seed.coin).burn(dust);
    }

    /// @dev The Creator's First Buy: an exact-in buy of `firstBuy`, paid from the Creator's allowance or,
    ///      in the native asset, from the value the launch was sent; the coins go to the Creator. It passes
    ///      through the hook and pays the Platform Fee like any buy, and no Opening Fee: it is the only swap
    ///      this factory ever makes, in the launch's own unlock, which the hook reads from its `sender` (#246).
    function _firstBuy(Seed memory seed) internal returns (uint256 coinsBought) {
        bool zeroForOne = seed.quoteIsCurrency0;
        BalanceDelta delta = poolManager.swap(
            seed.key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -seed.firstBuy.toInt256(),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 quoteDelta, int128 coinDelta) =
            seed.quoteIsCurrency0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());

        uint256 paid = OZSafeCast.toUint256(-int256(quoteDelta));
        poolManager.sync(Currency.wrap(seed.quote));
        if (seed.quote == address(0)) {
            // The whole value sent, never `paid`: were they ever to differ, the factory's delta would not
            // close and the unlock would revert, so no wei of the launch's value can stay here.
            // forge-lint: disable-next-line(unused-return)
            poolManager.settle{value: seed.firstBuy}();
        } else {
            // `seed.creator` is the launch's own caller: the data comes from the factory's own unlock.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            IERC20(seed.quote).safeTransferFrom(seed.creator, address(poolManager), paid);
            // forge-lint: disable-next-line(unused-return)
            poolManager.settle();
        }

        coinsBought = OZSafeCast.toUint256(coinDelta);
        poolManager.take(Currency.wrap(seed.coin), seed.creator, coinsBought);
    }

    // ------------------------------------------------------------------ views

    /// @notice A Launch's facts, by its pool.
    function launchOf(PoolId poolId) external view returns (Launch memory) {
        return _launches[poolId];
    }

    /// @notice The ticks of a Launch's Seed Position, which the factory owns with salt zero.
    function seedRange(PoolId poolId) external view returns (int24 tickLower, int24 tickUpper) {
        Launch storage l = _launches[poolId];
        return (l.seedTickLower, l.seedTickUpper);
    }
}
