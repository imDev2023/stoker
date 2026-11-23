// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {StokerCoin} from "./StokerCoin.sol";

/// @title StokerHook (spike)
/// @notice One hook for every Stoker pool on a chain. The pool's LP fee is zero; this hook takes
///         every fee on the Quote Asset's side of the swap, in both directions and for exact-in and
///         exact-out alike, and pays the Platform Fee's three shares (Creator, referrer, platform)
///         inside the swap. A Reward Launch's Reward Tax is taken the same way: a share buys the
///         coin and burns it, a share is added to the pool as locked liquidity once the coin has
///         graduated, and the rest is held for the holders. Graduation is a threshold on the
///         pool's tick, latched once. The hook reads time only, never `block.number`.
/// @dev    Evidence for #234, not production code. Shapes borrowed from the Unihood and HOOD10
///         contracts archived in the Robinhood Chain knowledge base (both MIT).
contract StokerHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;
    /// @notice The Platform Fee, in bps of the gross Quote Asset amount of a swap.
    uint16 public constant PLATFORM_FEE_BPS = 100;
    /// @notice A referrer's share of the Platform Fee, when the swap names one in `hookData`.
    uint16 public constant REFERRER_SHARE_BPS = 1_000;
    uint16 public constant MAX_TAX_BPS = 500;
    int24 public constant TICK_SPACING = 200;

    address public immutable factory;
    address public immutable platform;

    struct Terms {
        address coin;
        address quote;
        bool quoteIsCurrency0;
        address creatorDestination;
        /// @dev The Creator's share of the Platform Fee, in bps of that fee.
        uint16 creatorShareBps;
        /// @dev The Reward Tax (or Stoke Tax), in bps of the gross Quote Asset amount. 0 = standard.
        uint16 taxBps;
        /// @dev Shares of the tax, in bps of the tax. The rest is the holders'.
        uint16 burnShareBps;
        uint16 liquidityShareBps;
        /// @dev The pool tick at which the coin graduates, oriented for this pool's currency order.
        int24 graduationTick;
        /// @dev Pending burn plus liquidity (Quote Asset units) at which a swap also flushes them.
        uint128 flushThreshold;
    }

    struct State {
        uint64 launchedAt;
        uint64 graduatedAt;
        bool graduated;
        uint128 pendingBurnQuote;
        uint128 pendingLiquidityQuote;
        uint128 pendingLiquidityCoin;
        uint128 holderPot;
        uint128 lockedLiquidity;
        uint256 burnedCoins;
    }

    mapping(PoolId => Terms) internal _terms;
    mapping(PoolId => State) internal _state;
    /// @notice Fee shares a push could not deliver (a blocked or reverting recipient), claimable later.
    mapping(address recipient => mapping(Currency currency => uint256 amount)) public owed;

    error NotFactory();
    error BadPool();
    error AlreadyRegistered();
    error BadTerms();
    error LiquidityAddsClosed();
    error LiquidityLocked();

    event Registered(PoolId indexed poolId, address indexed coin, address indexed quote, Terms terms);
    event SwapFee(
        PoolId indexed poolId,
        bool indexed isBuy,
        uint256 grossQuote,
        uint256 platformFee,
        uint256 tax,
        address creatorDestination,
        uint256 creatorShare,
        address referrer,
        uint256 referrerShare,
        uint256 platformShare
    );
    event Paid(Currency indexed currency, address indexed to, uint256 amount);
    event Owed(Currency indexed currency, address indexed to, uint256 amount);
    event Claimed(Currency indexed currency, address indexed to, uint256 amount);
    event Graduated(PoolId indexed poolId, int24 tick, uint64 timestamp);
    event Flushed(PoolId indexed poolId, uint256 coinsBurned, uint128 liquidityAdded);

    constructor(IPoolManager poolManager_, address platform_) BaseHook(poolManager_) {
        factory = msg.sender;
        platform = platform_;
    }

    // ------------------------------------------------------------------ permissions

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
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ registration

    function register(PoolKey calldata key, Terms calldata t) external {
        if (msg.sender != factory) revert NotFactory();
        (Currency c0, Currency c1) = t.quoteIsCurrency0
            ? (Currency.wrap(t.quote), Currency.wrap(t.coin))
            : (Currency.wrap(t.coin), Currency.wrap(t.quote));
        if (
            address(key.hooks) != address(this) || key.fee != 0 || key.tickSpacing != TICK_SPACING
                || Currency.unwrap(key.currency0) != Currency.unwrap(c0)
                || Currency.unwrap(key.currency1) != Currency.unwrap(c1)
        ) revert BadPool();
        if (
            t.taxBps > MAX_TAX_BPS || uint256(t.burnShareBps) + t.liquidityShareBps > BPS
                || uint256(t.creatorShareBps) + REFERRER_SHARE_BPS > BPS
        ) revert BadTerms();
        PoolId id = key.toId();
        if (_terms[id].coin != address(0)) revert AlreadyRegistered();
        _terms[id] = t;
        _state[id].launchedAt = uint64(block.timestamp);
        emit Registered(id, t.coin, t.quote, t);
    }

    // ------------------------------------------------------------------ callbacks

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != factory || _terms[key.toId()].coin == address(0)) revert BadPool();
        return this.beforeInitialize.selector;
    }

    /// @dev Only the factory's seed may add liquidity. The hook's own Reward Liquidity is a
    ///      self-call, which skips this callback (v4's `noSelfCall`), as intended.
    function _beforeAddLiquidity(address sender, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (sender != factory) revert LiquidityAddsClosed();
        return this.beforeAddLiquidity.selector;
    }

    /// @dev Nobody but the factory and the hook can hold a position in these pools, neither has
    ///      code that removes one, and this callback refuses any removal regardless.
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityLocked();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        Terms storage t = _terms[id];
        bool exactIn = params.amountSpecified < 0;
        bool quoteSpecified = (params.zeroForOne == exactIn) == t.quoteIsCurrency0;
        if (!quoteSpecified) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 rate = PLATFORM_FEE_BPS + uint256(t.taxBps);
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 gross;
        uint256 fee;
        if (exactIn) {
            // A buy with the Quote Asset in: the trader's amount is the gross.
            gross = amount;
            fee = FullMath.mulDivRoundingUp(gross, rate, BPS);
        } else {
            // A sell for an exact Quote Asset amount out: the pool must pay the gross.
            gross = FullMath.mulDivRoundingUp(amount, BPS, BPS - rate);
            fee = gross - amount;
        }
        _collect(id, t, exactIn, gross, fee, hookData);
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId id = key.toId();
        Terms storage t = _terms[id];
        State storage s = _state[id];
        bool exactIn = params.amountSpecified < 0;
        bool quoteSpecified = (params.zeroForOne == exactIn) == t.quoteIsCurrency0;

        int128 hookDelta;
        if (!quoteSpecified) {
            uint256 rate = PLATFORM_FEE_BPS + uint256(t.taxBps);
            int128 q = t.quoteIsCurrency0 ? delta.amount0() : delta.amount1();
            uint256 gross;
            uint256 fee;
            if (exactIn) {
                // A sell with the coin in: the Quote Asset out is the gross.
                gross = uint256(uint128(q));
                fee = FullMath.mulDivRoundingUp(gross, rate, BPS);
            } else {
                // A buy of an exact coin amount: the fee goes on top of the Quote Asset in.
                uint256 net = uint256(uint128(-q));
                fee = FullMath.mulDivRoundingUp(net, rate, BPS - rate);
                gross = net + fee;
            }
            _collect(id, t, !exactIn, gross, fee, hookData);
            hookDelta = int128(int256(fee));
        }

        _maybeGraduate(id, t, s);
        if (uint256(s.pendingBurnQuote) + (s.graduated ? s.pendingLiquidityQuote : 0) >= t.flushThreshold) {
            _flush(key, id, t, s);
            _maybeGraduate(id, t, s);
        }
        return (this.afterSwap.selector, hookDelta);
    }

    // ------------------------------------------------------------------ fees

    function _collect(PoolId id, Terms storage t, bool isBuy, uint256 gross, uint256 fee, bytes calldata hookData)
        internal
    {
        if (fee == 0) return;
        Currency quote = Currency.wrap(t.quote);
        uint256 rate = PLATFORM_FEE_BPS + uint256(t.taxBps);
        uint256 tax = fee * t.taxBps / rate;
        uint256 platformFee = fee - tax;

        // hookData is untrusted: only its first word is read, as an address, and never reverts.
        address referrer = hookData.length >= 32 ? address(uint160(uint256(bytes32(hookData[:32])))) : address(0);
        uint256 creatorShare = platformFee * t.creatorShareBps / BPS;
        uint256 referrerShare = referrer == address(0) ? 0 : platformFee * REFERRER_SHARE_BPS / BPS;
        uint256 platformShare = platformFee - creatorShare - referrerShare;

        _pay(quote, t.creatorDestination, creatorShare);
        _pay(quote, referrer, referrerShare);
        _pay(quote, platform, platformShare);

        if (tax != 0) {
            State storage s = _state[id];
            uint256 burnPart = tax * t.burnShareBps / BPS;
            uint256 liquidityPart = tax * t.liquidityShareBps / BPS;
            s.pendingBurnQuote += uint128(burnPart);
            s.pendingLiquidityQuote += uint128(liquidityPart);
            s.holderPot += uint128(tax - burnPart - liquidityPart);
            poolManager.mint(address(this), quote.toId(), tax);
        }

        emit SwapFee(
            id,
            isBuy,
            gross,
            platformFee,
            tax,
            t.creatorDestination,
            creatorShare,
            referrer,
            referrerShare,
            platformShare
        );
    }

    /// @dev Pays a share inside the swap. A recipient the Quote Asset refuses (the stock tokens'
    ///      blocklist) or a PoolManager short of that currency must not brick the pool, so a
    ///      failed push becomes an ERC-6909 claim held by the hook and owed to the recipient.
    function _pay(Currency currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        try poolManager.take(currency, to, amount) {
            emit Paid(currency, to, amount);
        } catch {
            poolManager.mint(address(this), currency.toId(), amount);
            owed[to][currency] += amount;
            emit Owed(currency, to, amount);
        }
    }

    // ------------------------------------------------------------------ graduation

    function _maybeGraduate(PoolId id, Terms storage t, State storage s) internal {
        if (s.graduated) return;
        (, int24 tick,,) = poolManager.getSlot0(id);
        bool crossed = t.quoteIsCurrency0 ? tick <= t.graduationTick : tick >= t.graduationTick;
        if (!crossed) return;
        s.graduated = true;
        s.graduatedAt = uint64(block.timestamp);
        emit Graduated(id, tick, uint64(block.timestamp));
    }

    // ------------------------------------------------------------------ burn and liquidity

    /// @notice Anyone may flush a pool's pending Reward Burn and (after Graduation) Reward Liquidity.
    function flush(PoolKey calldata key) external {
        // A caller-supplied key is untrusted: it must name this hook and a registered pool.
        if (address(key.hooks) != address(this) || _terms[key.toId()].coin == address(0)) revert BadPool();
        poolManager.unlock(abi.encode(uint8(0), abi.encode(key)));
    }

    /// @notice Withdraws fee shares that could not be pushed when they were earned.
    function claim(Currency currency) external returns (uint256 amount) {
        amount = owed[msg.sender][currency];
        if (amount == 0) return 0;
        owed[msg.sender][currency] = 0;
        poolManager.unlock(abi.encode(uint8(1), abi.encode(msg.sender, currency, amount)));
        emit Claimed(currency, msg.sender, amount);
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 action, bytes memory inner) = abi.decode(data, (uint8, bytes));
        if (action == 0) {
            PoolKey memory key = abi.decode(inner, (PoolKey));
            PoolId id = key.toId();
            Terms storage t = _terms[id];
            State storage s = _state[id];
            _maybeGraduate(id, t, s);
            _flush(key, id, t, s);
            _maybeGraduate(id, t, s);
        } else {
            (address to, Currency currency, uint256 amount) = abi.decode(inner, (address, Currency, uint256));
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, to, amount);
        }
        return "";
    }

    /// @dev Runs inside an unlock (a trader's swap or `flush`). Every PoolManager call here is a
    ///      self-call, so no hook fee applies to the hook's own buy and no callback gates its add.
    function _flush(PoolKey memory key, PoolId id, Terms storage t, State storage s) internal {
        uint256 burnQuote = s.pendingBurnQuote;
        uint256 liquidityQuote = s.graduated ? s.pendingLiquidityQuote : 0;
        if (burnQuote + liquidityQuote == 0) return;

        Currency quote = Currency.wrap(t.quote);
        Currency coin = Currency.wrap(t.coin);
        s.pendingBurnQuote = 0;
        if (liquidityQuote != 0) s.pendingLiquidityQuote = 0;
        poolManager.burn(address(this), quote.toId(), burnQuote + liquidityQuote);

        uint256 liquidityHalf = liquidityQuote / 2;
        uint256 spend = burnQuote + liquidityHalf;
        uint256 coinsBought = spend == 0 ? 0 : _buyCoin(key, t.quoteIsCurrency0, spend);
        uint256 coinsToBurn = spend == 0 ? 0 : FullMath.mulDiv(coinsBought, burnQuote, spend);

        if (coinsToBurn != 0) {
            poolManager.take(coin, address(this), coinsToBurn);
            StokerCoin(t.coin).burn(coinsToBurn);
            s.burnedCoins += coinsToBurn;
        }

        uint128 added;
        if (liquidityQuote != 0) {
            uint256 quoteAvail = liquidityQuote - liquidityHalf;
            uint256 coinAvail = coinsBought - coinsToBurn + s.pendingLiquidityCoin;
            if (s.pendingLiquidityCoin != 0) {
                poolManager.burn(address(this), coin.toId(), s.pendingLiquidityCoin);
                s.pendingLiquidityCoin = 0;
            }
            (uint256 used0, uint256 used1, uint128 liquidity) = _addFullRange(key, t.quoteIsCurrency0, quoteAvail, coinAvail);
            added = liquidity;
            (uint256 usedQuote, uint256 usedCoin) = t.quoteIsCurrency0 ? (used0, used1) : (used1, used0);
            // Rounding leftovers wait for the next flush as claims held by the hook.
            if (quoteAvail > usedQuote) {
                poolManager.mint(address(this), quote.toId(), quoteAvail - usedQuote);
                s.pendingLiquidityQuote += uint128(quoteAvail - usedQuote);
            }
            if (coinAvail > usedCoin) {
                poolManager.mint(address(this), coin.toId(), coinAvail - usedCoin);
                s.pendingLiquidityCoin += uint128(coinAvail - usedCoin);
            }
            s.lockedLiquidity += liquidity;
        }
        emit Flushed(id, coinsToBurn, added);
    }

    function _buyCoin(PoolKey memory key, bool quoteIsCurrency0, uint256 quoteIn) internal returns (uint256) {
        BalanceDelta d = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: quoteIsCurrency0,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: quoteIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        return uint256(uint128(quoteIsCurrency0 ? d.amount1() : d.amount0()));
    }

    function _addFullRange(PoolKey memory key, bool quoteIsCurrency0, uint256 quoteAvail, uint256 coinAvail)
        internal
        returns (uint256 used0, uint256 used1, uint128 liquidity)
    {
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(key.toId());
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        (uint256 amount0, uint256 amount1) = quoteIsCurrency0 ? (quoteAvail, coinAvail) : (coinAvail, quoteAvail);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice, TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), amount0, amount1
        );
        if (liquidity == 0) return (0, 0, 0);
        (BalanceDelta d,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        used0 = uint256(uint128(-d.amount0()));
        used1 = uint256(uint128(-d.amount1()));
    }

    // ------------------------------------------------------------------ views

    function terms(PoolId id) external view returns (Terms memory) {
        return _terms[id];
    }

    function state(PoolId id) external view returns (State memory) {
        return _state[id];
    }
}
