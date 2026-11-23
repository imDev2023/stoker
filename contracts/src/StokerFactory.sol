// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
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

import {StokerCoin} from "./StokerCoin.sol";
import {StokerHook} from "./StokerHook.sol";
import {IQuoteListings} from "./interfaces/IQuoteListings.sol";

/// @title StokerFactory
/// @notice Launches a Stoker coin on an EVM chain by Direct Seed (ADR 0024), in one transaction: it
///         deploys the coin, opens its Uniswap v4 pool against a listed Quote Asset at the Listing's start
///         price, places the whole supply in the pool as the Seed Position, and makes the Creator's First
///         Buy. The factory holds every Seed Position and has no code that removes liquidity; the hook
///         refuses every removal in any case.
/// @dev No owner, no setter, no proxy and no pause. The settings are fixed at deployment and written into
///      each Launch's terms; a later deployment changes them for later Launches only.
contract StokerFactory is IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant SUPPLY = 1e12 * 1e18;

    IPoolManager public immutable poolManager;
    StokerHook public immutable hook;
    /// @notice Where each Quote Asset's Listing is read (a stand-in until the Quote Registry, #243).
    IQuoteListings public immutable listings;
    /// @notice The Platform Fee written into every Launch, in basis points of the Quote Asset's side.
    uint16 public immutable platformFeeBps;
    /// @notice The Creator's share of the Platform Fee written into every Launch: the Creator Ladder's first
    ///         tier (ADR 0027). Never the launcher's to choose.
    uint16 public immutable creatorShareBps;
    /// @notice The tick spacing of every pool this factory opens.
    int24 public immutable tickSpacing;

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
    struct LaunchParams {
        string name;
        string symbol;
        address quote;
        bytes32 salt;
        address creatorDestination;
        uint256 firstBuy;
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
    }

    mapping(PoolId => Launch) internal _launches;

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

    error InvalidSettings();
    error NotListed(address quote);
    error InvalidStartTick(int24 startTick);
    error NotPoolManager();

    /// @param hookSalt The CREATE2 salt that gives the hook an address carrying its permission bits.
    constructor(
        IPoolManager poolManager_,
        IQuoteListings listings_,
        address platform_,
        uint16 platformFeeBps_,
        uint16 creatorShareBps_,
        int24 tickSpacing_,
        bytes32 hookSalt
    ) {
        // Bounded so that no deployment can take most of a swap: at most 10% of the Quote Asset's side.
        if (platformFeeBps_ == 0 || platformFeeBps_ > 1_000) revert InvalidSettings();
        if (creatorShareBps_ > 10_000 || platform_ == address(0)) revert InvalidSettings();
        if (tickSpacing_ < TickMath.MIN_TICK_SPACING || tickSpacing_ > TickMath.MAX_TICK_SPACING) {
            revert InvalidSettings();
        }
        poolManager = poolManager_;
        listings = listings_;
        platformFeeBps = platformFeeBps_;
        creatorShareBps = creatorShareBps_;
        tickSpacing = tickSpacing_;
        hook = new StokerHook{salt: hookSalt}(poolManager_, platform_);
    }

    // ------------------------------------------------------------------ launching

    /// @notice Launches a coin; a First Buy needs the Creator's allowance for the factory.
    function launch(LaunchParams calldata p) external returns (address coin, PoolId poolId) {
        return _launch(p);
    }

    /// @notice Launches a coin with the First Buy's allowance given by an ERC-2612 signature, in the same
    ///         transaction. A permit already used (someone submitted the signature first) does not stop the
    ///         launch while the allowance stands.
    function launchWithPermit(LaunchParams calldata p, PermitSignature calldata s)
        external
        returns (address coin, PoolId poolId)
    {
        if (p.firstBuy > 0) {
            try IERC20Permit(p.quote).permit(msg.sender, address(this), p.firstBuy, s.deadline, s.v, s.r, s.s) {}
                catch {}
        }
        return _launch(p);
    }

    function _launch(LaunchParams calldata p) internal returns (address coin, PoolId poolId) {
        IQuoteListings.Listing memory listing = listings.listingOf(p.quote);
        if (!listing.listed || p.quote == address(0)) revert NotListed(p.quote);
        int24 startTick = listing.startTick;
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);
        if (startTick % tickSpacing != 0 || startTick <= minUsable || startTick >= maxUsable) {
            revert InvalidStartTick(startTick);
        }

        coin = address(new StokerCoin{salt: keccak256(abi.encode(msg.sender, p.salt))}(p.name, p.symbol));
        address destination = p.creatorDestination == address(0) ? msg.sender : p.creatorDestination;

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

        hook.registerLaunch(
            seed.key,
            StokerHook.Terms({
                creatorDestination: destination,
                platformFeeBps: platformFeeBps,
                creatorShareBps: creatorShareBps,
                quoteIsCurrency0: seed.quoteIsCurrency0,
                registered: true
            })
        );
        _launches[poolId] = Launch({
            coin: coin,
            quote: p.quote,
            creator: msg.sender,
            seedTickLower: seed.tickLower,
            seedTickUpper: seed.tickUpper
        });

        // The tick it returns is `openTick`, by construction.
        // forge-lint: disable-next-line(unused-return)
        poolManager.initialize(seed.key, TickMath.getSqrtPriceAtTick(openTick));
        (uint128 liquidity, uint256 coinsBought) = abi.decode(poolManager.unlock(abi.encode(seed)), (uint128, uint256));

        // The calls before it are the PoolManager's, our hook's, the new coin's and the listed Quote Asset's.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Launched(poolId, coin, msg.sender, p.quote, destination, startTick, liquidity, p.firstBuy, coinsBought);
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

    /// @dev Places the whole supply as one single-sided position and burns the rounding dust left over, so
    ///      every coin is in the pool or, after the First Buy, with the Creator.
    function _placeSeed(Seed memory seed) internal returns (uint128 liquidity) {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(seed.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(seed.tickUpper);
        liquidity = seed.quoteIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, SUPPLY)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, SUPPLY);

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

        uint256 dust = SUPPLY - owed;
        if (dust > 0) StokerCoin(seed.coin).burn(dust);
    }

    /// @dev The Creator's First Buy: an exact-in buy of `firstBuy`, paid from the Creator's allowance, the
    ///      coins sent to the Creator. It passes through the hook and pays the Platform Fee like any buy.
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
        // `seed.creator` is the launch's own caller: the data comes from the factory's own unlock.
        // forge-lint: disable-next-line(arbitrary-send-erc20)
        IERC20(seed.quote).safeTransferFrom(seed.creator, address(poolManager), paid);
        // forge-lint: disable-next-line(unused-return)
        poolManager.settle();

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
