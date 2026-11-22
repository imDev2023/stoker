// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {StokerCoin} from "./StokerCoin.sol";
import {StokerHook} from "./StokerHook.sol";

/// @title StokerFactory (spike)
/// @notice One transaction launches a coin: deploys the ERC-20, opens its Uniswap v4 pool against a
///         listed Quote Asset at the listing's start price, places the whole supply in it as one
///         single-sided position, and makes the Creator's First Buy. The factory holds every seed
///         position and has no code that removes liquidity.
/// @dev    Evidence for #234, not production code.
contract StokerFactory is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    int24 public constant TICK_SPACING = 200;

    IPoolManager public immutable poolManager;
    StokerHook public immutable hook;
    /// @notice The registry key: lists a Quote Asset and its start price and Graduation Target.
    address public immutable registryKey;

    /// @dev Ticks are of the coin's price in Quote Asset units (raw), as if the coin were currency0.
    struct Listing {
        bool listed;
        int24 startTick;
        int24 graduationTick;
        uint128 flushThreshold;
    }

    struct LaunchParams {
        string name;
        string symbol;
        address quote;
        bytes32 salt;
        address creatorDestination;
        uint16 creatorShareBps;
        uint16 taxBps;
        uint16 burnShareBps;
        uint16 liquidityShareBps;
        uint256 firstBuy;
        uint256 minCoinsOut;
    }

    struct Seed {
        PoolKey key;
        address coin;
        address quote;
        bool quoteIsCurrency0;
        int24 startPoolTick;
        address creator;
        uint256 firstBuy;
        uint256 minCoinsOut;
    }

    mapping(address quote => Listing) public listings;

    error NotRegistryKey();
    error NotPoolManager();
    error NotListed();
    error BadListing();
    error FirstBuyTooSmall(uint256 got, uint256 min);

    event Listed(address indexed quote, int24 startTick, int24 graduationTick, uint128 flushThreshold);
    event Launched(
        address indexed coin,
        PoolId indexed poolId,
        address indexed creator,
        address quote,
        bool quoteIsCurrency0,
        uint256 seeded,
        uint256 firstBuy,
        uint256 coinsBought
    );

    constructor(IPoolManager poolManager_, address platform, bytes32 hookSalt) {
        poolManager = poolManager_;
        registryKey = msg.sender;
        // The hook's address carries its permission flags, so its salt is mined off-chain for
        // this factory's address. BaseHook's constructor refuses a salt that does not match.
        hook = new StokerHook{salt: hookSalt}(poolManager_, platform);
    }

    function list(address quote, int24 startTick, int24 graduationTick, uint128 flushThreshold) external {
        if (msg.sender != registryKey) revert NotRegistryKey();
        if (
            startTick % TICK_SPACING != 0 || graduationTick <= startTick
                || startTick <= TickMath.minUsableTick(TICK_SPACING)
                || graduationTick >= TickMath.maxUsableTick(TICK_SPACING)
        ) revert BadListing();
        listings[quote] = Listing(true, startTick, graduationTick, flushThreshold);
        emit Listed(quote, startTick, graduationTick, flushThreshold);
    }

    function launch(LaunchParams calldata p) external returns (address coin, PoolId id) {
        return _launch(p, msg.sender);
    }

    /// @notice A launch whose First Buy is paid in an ERC-2612 Quote Asset with a signed permit, so
    ///         a Creator with no allowance still launches in one transaction.
    function launchWithPermit(LaunchParams calldata p, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        returns (address coin, PoolId id)
    {
        // A permit someone else already submitted must not block the launch.
        try IERC20Permit(p.quote).permit(msg.sender, address(this), p.firstBuy, deadline, v, r, s) {} catch {}
        return _launch(p, msg.sender);
    }

    function _launch(LaunchParams calldata p, address creator) internal returns (address coin, PoolId id) {
        Listing memory l = listings[p.quote];
        if (!l.listed) revert NotListed();

        coin = address(new StokerCoin{salt: keccak256(abi.encode(creator, p.salt))}(p.name, p.symbol, address(this)));
        bool quoteIsCurrency0 = p.quote < coin;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(quoteIsCurrency0 ? p.quote : coin),
            currency1: Currency.wrap(quoteIsCurrency0 ? coin : p.quote),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        // With the coin as currency1 the pool's price is coin per Quote Asset: negate the ticks.
        int24 startPoolTick = quoteIsCurrency0 ? -l.startTick : l.startTick;
        int24 graduationPoolTick = quoteIsCurrency0 ? -l.graduationTick : l.graduationTick;

        hook.register(
            key,
            StokerHook.Terms({
                coin: coin,
                quote: p.quote,
                quoteIsCurrency0: quoteIsCurrency0,
                creatorDestination: p.creatorDestination,
                creatorShareBps: p.creatorShareBps,
                taxBps: p.taxBps,
                burnShareBps: p.burnShareBps,
                liquidityShareBps: p.liquidityShareBps,
                graduationTick: graduationPoolTick,
                flushThreshold: l.flushThreshold
            })
        );
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(startPoolTick));
        id = key.toId();

        (uint256 seeded, uint256 coinsBought) = abi.decode(
            poolManager.unlock(
                abi.encode(
                    Seed({
                        key: key,
                        coin: coin,
                        quote: p.quote,
                        quoteIsCurrency0: quoteIsCurrency0,
                        startPoolTick: startPoolTick,
                        creator: creator,
                        firstBuy: p.firstBuy,
                        minCoinsOut: p.minCoinsOut
                    })
                )
            ),
            (uint256, uint256)
        );
        emit Launched(coin, id, creator, p.quote, quoteIsCurrency0, seeded, p.firstBuy, coinsBought);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        Seed memory sd = abi.decode(data, (Seed));
        Currency coin = Currency.wrap(sd.coin);
        Currency quote = Currency.wrap(sd.quote);

        // The whole supply as one single-sided range from the start price outward. The pool opens
        // on the range's edge, so the position holds only the coin. Rounding dust stays here.
        uint256 seeded;
        {
            int24 lower;
            int24 upper;
            uint128 liquidity;
            uint256 supply = StokerCoin(sd.coin).SUPPLY();
            if (sd.quoteIsCurrency0) {
                lower = TickMath.minUsableTick(TICK_SPACING);
                upper = sd.startPoolTick;
                liquidity = LiquidityAmounts.getLiquidityForAmount1(
                    TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), supply
                );
            } else {
                lower = sd.startPoolTick;
                upper = TickMath.maxUsableTick(TICK_SPACING);
                liquidity = LiquidityAmounts.getLiquidityForAmount0(
                    TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), supply
                );
            }
            (BalanceDelta d,) = poolManager.modifyLiquidity(
                sd.key,
                ModifyLiquidityParams({
                    tickLower: lower,
                    tickUpper: upper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            seeded = uint256(uint128(-(sd.quoteIsCurrency0 ? d.amount1() : d.amount0())));
            poolManager.sync(coin);
            IERC20(sd.coin).transfer(address(poolManager), seeded);
            poolManager.settle();
        }

        uint256 coinsBought;
        if (sd.firstBuy != 0) {
            // Settle the Quote Asset before the swap, so the hook's in-swap payouts find it in the
            // PoolManager even when no other pool holds that currency.
            poolManager.sync(quote);
            IERC20(sd.quote).transferFrom(sd.creator, address(poolManager), sd.firstBuy);
            poolManager.settle();
            BalanceDelta d = poolManager.swap(
                sd.key,
                SwapParams({
                    zeroForOne: sd.quoteIsCurrency0,
                    amountSpecified: -int256(sd.firstBuy),
                    sqrtPriceLimitX96: sd.quoteIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                ""
            );
            coinsBought = uint256(uint128(sd.quoteIsCurrency0 ? d.amount1() : d.amount0()));
            if (coinsBought < sd.minCoinsOut) revert FirstBuyTooSmall(coinsBought, sd.minCoinsOut);
            poolManager.take(coin, sd.creator, coinsBought);
        }
        return abi.encode(seeded, coinsBought);
    }
}
