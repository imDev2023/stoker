// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast as OZSafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {StokerHook} from "./StokerHook.sol";
import {StokerCoin} from "./StokerCoin.sol";
import {IHoldersPart} from "./interfaces/IHoldersPart.sol";

/// @notice What the Tax Vault reads from the factory it was made for.
interface IStokerLaunches {
    function hook() external view returns (StokerHook);
    function seedRange(PoolId poolId) external view returns (int24 tickLower, int24 tickUpper);
}

/// @title TaxVault
/// @notice Receives every Reward Tax and Stoke Tax on an EVM chain and spends each coin's own tax on that
///         coin alone (ADR 0025, #245), by calls anyone can make, in capped pieces:
///         - `addSupport` adds the Reward Liquidity share, and a Stoke Launch's whole tax, to the coin's pool
///           as Support Liquidity: Quote Asset alone, in a locked position just below the current price,
///           with no coin bought and the price unmoved;
///         - `burn` buys the coin with the Reward Burn share and burns exactly what it bought;
///         - `buyForHolders` buys the coin with the holders' part when the Payout Asset is the coin;
///         - `passHoldersPart` hands the holders' part to the Distributor.
///
///         How a coin's tax reaches these books: the hook mints each swap's tax to this contract as ERC-6909
///         claims in the PoolManager and adds it to its own running total for the pool (`taxBooked`). Nothing
///         moves in a swap. This contract splits that total by the Launch's shares, each part rounded down
///         (so each only ever grows), and records what each path has spent per pool. A path never spends
///         more than its own part of its own coin's tax, so no coin's tax pays for another and the holders'
///         part is never touched by the burn or the liquidity. Liquidity and buys are settled by burning
///         claims, the native asset included; only the holders' part leaves the PoolManager, and only to the
///         Distributor.
///
///         Anyone may also fund a coin's burn or its Support Liquidity with that coin's Quote Asset
///         (`fundBurn`, `fundSupport`, #248): a Creator Earnings Destination of the burn or of the liquidity
///         does so with its coin's earnings. What was funded joins what `burn` and `addSupport` spend, under
///         the same cap, the same interval and the same buy and the same addition, and is kept in books of
///         its own per pool, so funded Quote Asset and a coin's tax are never counted as each other.
/// @dev No owner, no setter, no proxy, no pause; the settings are fixed at deployment. It holds every
///      Support Liquidity position and has no code that removes liquidity; the hook refuses every removal in
///      any case. It reads time only, never `block.number`.
contract TaxVault is IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant BPS = 10_000;

    /// @dev The re-entry guard, in transient storage: keccak256("stoker.taxvault.lock") - 1.
    bytes32 internal constant LOCK_SLOT = 0x64d4bef6df211d0a63203971820f74762833b85151bbeb8e4c54892e55910dce;

    IPoolManager public immutable poolManager;
    /// @notice The factory this vault serves: its hook books the tax, and its Seed Positions set the cap.
    address public immutable factory;
    /// @notice Where the holders' part goes (#247), fixed at deployment.
    IHoldersPart public immutable distributor;
    /// @notice The largest piece, of the coin's pool's Quote Asset depth (see `pieceCap`): 50 is 0.5%.
    uint16 public immutable pieceBps;
    /// @notice The least time between two buys in one pool, and between two Support Liquidity pieces in one
    ///         pool, so a caller cannot stack pieces in one block or one transaction.
    uint32 public immutable pieceInterval;
    /// @notice How deep a Support Liquidity position reaches below the price, in the pool's tick spacings.
    int24 public immutable supportWidthSpacings;

    /// @notice What each path has spent of one coin's tax, in its Quote Asset, and what waits to be passed on.
    /// @param burnSpent The Reward Burn's buys.
    /// @param supportSpent The Support Liquidity added.
    /// @param holdersSpent The holders' part passed to the Distributor, or spent buying the coin for them.
    /// @param holdersCoins Coins bought for the holders, not yet passed to the Distributor.
    /// @param lastBuyAt When this vault last bought in the pool.
    /// @param lastSupportAt When this vault last added Support Liquidity to the pool.
    /// @param burnFunded What anyone has funded this coin's burn with (#248), apart from its tax.
    /// @param burnFundedSpent What the burn's buys have spent of it.
    /// @param supportFunded What anyone has funded this coin's Support Liquidity with, apart from its tax.
    /// @param supportFundedSpent What has been added to the pool of it.
    struct Books {
        uint256 burnSpent;
        uint256 supportSpent;
        uint256 holdersSpent;
        uint256 holdersCoins;
        uint64 lastBuyAt;
        uint64 lastSupportAt;
        uint256 burnFunded;
        uint256 burnFundedSpent;
        uint256 supportFunded;
        uint256 supportFundedSpent;
    }

    mapping(PoolId => Books) internal _books;

    /// @dev One coin's pool as a public call reads it.
    struct Pool {
        PoolId id;
        StokerHook.Terms terms;
        Currency quote;
        Currency coin;
        uint256 booked;
    }

    enum Action {
        Buy,
        Support,
        Take,
        Fund
    }

    event SupportAdded(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 quoteAdded);
    event RewardBurned(PoolId indexed poolId, uint256 quoteSpent, uint256 coinsBurned);
    event BoughtForHolders(PoolId indexed poolId, uint256 quoteSpent, uint256 coinsBought);
    event HoldersPartPassed(PoolId indexed poolId, address indexed coin, Currency asset, uint256 amount);
    /// @notice `funder` gave `amount` of the coin's Quote Asset to its burn (#248).
    event BurnFunded(PoolId indexed poolId, address indexed funder, uint256 amount);
    /// @notice `funder` gave `amount` of the coin's Quote Asset to its Support Liquidity (#248).
    event SupportFunded(PoolId indexed poolId, address indexed funder, uint256 amount);
    /// @notice The part of one `burn` that spent funded Quote Asset: `RewardBurned` reports the tax's part of
    ///         the same buy, and the two together are what it spent and burned.
    event FundedBurned(PoolId indexed poolId, uint256 quoteSpent, uint256 coinsBurned);
    /// @notice The part of one `SupportAdded` that was funded Quote Asset; the rest of it was the coin's tax.
    event FundedSupportAdded(PoolId indexed poolId, uint256 quoteAdded);

    error InvalidSettings();
    error NotPoolManager();
    error NotAStokerPool();
    error NothingToSpend();
    error Reentered();
    /// @notice This pool's last piece of this kind was too recent; the next may come at `nextAt`.
    error TooSoon(uint256 nextAt);
    error NoRoomForSupport();
    /// @notice A Support Liquidity addition did not take Quote Asset alone, or took more than its piece.
    error NotSupportShaped();
    /// @notice The Distributor took other than exactly the amount deposited.
    error DepositShort();
    /// @notice A funding call was sent value other than its amount in the native asset, or any value with an
    ///         ERC-20 Quote Asset.
    error ValueMismatch(uint256 expected, uint256 sent);
    /// @notice The Quote Asset delivered other than exactly the amount funded.
    error FundingShort();

    /// @param factory_ The factory's address, which it checks against itself at its deployment.
    constructor(
        IPoolManager poolManager_,
        address factory_,
        IHoldersPart distributor_,
        uint16 pieceBps_,
        uint32 pieceInterval_,
        int24 supportWidthSpacings_
    ) {
        if (address(poolManager_) == address(0) || factory_ == address(0) || address(distributor_) == address(0)) {
            revert InvalidSettings();
        }
        // At most 1% of the pool's depth per piece, and at least a second between pieces.
        if (pieceBps_ == 0 || pieceBps_ > 100 || pieceInterval_ == 0) revert InvalidSettings();
        if (supportWidthSpacings_ <= 0 || supportWidthSpacings_ > 1_000) revert InvalidSettings();
        poolManager = poolManager_;
        factory = factory_;
        distributor = distributor_;
        pieceBps = pieceBps_;
        pieceInterval = pieceInterval_;
        supportWidthSpacings = supportWidthSpacings_;
    }

    modifier nonReentrant() {
        bool locked;
        assembly ("memory-safe") {
            locked := tload(LOCK_SLOT)
        }
        if (locked) revert Reentered();
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    // ------------------------------------------------------------------ the public calls

    /// @notice Adds one piece of the coin's Support Liquidity: Quote Asset alone, in a position from just
    ///         below the current price down `supportWidthSpacings` tick spacings, held by this vault for good.
    ///         It buys no coin and leaves the pool's price where it was. A piece is at most `pieceCap`, and a
    ///         pool takes one piece per `pieceInterval`.
    function addSupport(PoolKey calldata key) external nonReentrant returns (uint256 added, uint128 liquidity) {
        Pool memory p = _load(key);
        Books storage b = _books[p.id];
        _checkInterval(b.lastSupportAt);
        // The coin's tax first, then what was funded for it (#248): one piece, one position, one cap.
        uint256 taxWaiting = _part(p.booked, p.terms.liquidityShareBps) - b.supportSpent;
        uint256 amount =
            _min(taxWaiting + (b.supportFunded - b.supportFundedSpent), _pieceCap(p.id, p.terms.quoteIsCurrency0));
        if (amount == 0) revert NothingToSpend();

        (int24 lower, int24 upper) = _supportRange(key, p.id, p.terms.quoteIsCurrency0);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(lower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(upper);
        liquidity = p.terms.quoteIsCurrency0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);
        if (liquidity == 0) revert NothingToSpend();

        b.lastSupportAt = OZSafeCast.toUint64(block.timestamp);
        // The PoolManager calls back only this vault, and runs only our hook inside; the guard holds.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bytes memory result = poolManager.unlock(
            abi.encode(Action.Support, abi.encode(key, p.terms.quoteIsCurrency0, lower, upper, liquidity, amount))
        );
        added = abi.decode(result, (uint256));
        uint256 fromFunded = added > taxWaiting ? added - taxWaiting : 0;
        b.supportSpent += added - fromFunded;
        b.supportFundedSpent += fromFunded;
        // forge-lint: disable-next-line(reentrancy-events)
        emit SupportAdded(p.id, lower, upper, liquidity, added);
        // forge-lint: disable-next-line(reentrancy-events)
        if (fromFunded > 0) emit FundedSupportAdded(p.id, fromFunded);
    }

    /// @notice Spends one piece of the coin's Reward Burn share on a buy of the coin, outside any trader's
    ///         swap, and burns exactly the coins it bought, so the supply falls by them. A piece is at most
    ///         `pieceCap`; a pool takes one buy per `pieceInterval`, whether for the burn or for the holders.
    ///         The buy pays the Platform Fee like any buy and no tax (see the hook's `_taxBps`).
    function burn(PoolKey calldata key) external nonReentrant returns (uint256 spent, uint256 burned) {
        Pool memory p = _load(key);
        Books storage b = _books[p.id];
        _checkInterval(b.lastBuyAt);
        // The coin's tax first, then what was funded for it (#248): one piece, one buy, one cap.
        uint256 taxWaiting = _part(p.booked, p.terms.burnShareBps) - b.burnSpent;
        spent = _min(taxWaiting + (b.burnFunded - b.burnFundedSpent), _pieceCap(p.id, p.terms.quoteIsCurrency0));
        if (spent == 0) revert NothingToSpend();
        uint256 fromFunded = spent > taxWaiting ? spent - taxWaiting : 0;
        b.burnSpent += spent - fromFunded;
        b.burnFundedSpent += fromFunded;
        b.lastBuyAt = OZSafeCast.toUint64(block.timestamp);
        burned = _buy(key, p, spent);
        // Our own coin: a plain ERC-20 whose `burn` takes the caller's own coins.
        StokerCoin(Currency.unwrap(p.coin)).burn(burned);
        // The coins of one buy, shared by what each source spent on it, the funded part rounded down.
        uint256 fundedCoins = FullMath.mulDiv(burned, fromFunded, spent);
        // forge-lint: disable-next-line(reentrancy-events)
        if (spent > fromFunded) emit RewardBurned(p.id, spent - fromFunded, burned - fundedCoins);
        // forge-lint: disable-next-line(reentrancy-events)
        if (fromFunded > 0) emit FundedBurned(p.id, fromFunded, fundedCoins);
    }

    /// @notice When a Reward Launch's Payout Asset is the coin, spends one piece of the holders' part on a buy
    ///         of the coin, under the same cap and the same interval as the burn, and keeps what it bought for
    ///         the holders until `passHoldersPart`.
    function buyForHolders(PoolKey calldata key) external nonReentrant returns (uint256 spent, uint256 bought) {
        Pool memory p = _load(key);
        if (p.terms.payoutAsset != StokerHook.PayoutAsset.Coin) revert NothingToSpend();
        Books storage b = _books[p.id];
        _checkInterval(b.lastBuyAt);
        spent =
            _min(_part(p.booked, _holdersShare(p.terms)) - b.holdersSpent, _pieceCap(p.id, p.terms.quoteIsCurrency0));
        if (spent == 0) revert NothingToSpend();
        b.holdersSpent += spent;
        b.lastBuyAt = OZSafeCast.toUint64(block.timestamp);
        bought = _buy(key, p, spent);
        b.holdersCoins += bought;
        // forge-lint: disable-next-line(reentrancy-events)
        emit BoughtForHolders(p.id, spent, bought);
    }

    /// @notice Hands a Reward Launch's holders' part to the Distributor: all of the Quote Asset waiting when
    ///         the Payout Asset is the Quote Asset, all the coins bought for them when it is the coin. A Stoke
    ///         Launch and a standard Launch have no holders' part.
    function passHoldersPart(PoolKey calldata key) external nonReentrant returns (Currency asset, uint256 amount) {
        Pool memory p = _load(key);
        if (p.terms.launchType != StokerHook.LaunchType.Reward) revert NothingToSpend();
        Books storage b = _books[p.id];
        if (p.terms.payoutAsset == StokerHook.PayoutAsset.QuoteAsset) {
            asset = p.quote;
            amount = _part(p.booked, _holdersShare(p.terms)) - b.holdersSpent;
            if (amount == 0) revert NothingToSpend();
            b.holdersSpent += amount;
            // forge-lint: disable-next-line(unused-return, reentrancy-no-eth)
            poolManager.unlock(abi.encode(Action.Take, abi.encode(asset, amount)));
        } else {
            asset = p.coin;
            amount = b.holdersCoins;
            if (amount == 0) revert NothingToSpend();
            b.holdersCoins = 0;
        }
        address coin = Currency.unwrap(p.coin);
        _deposit(coin, asset, amount);
        // forge-lint: disable-next-line(reentrancy-events)
        emit HoldersPartPassed(p.id, coin, asset, amount);
    }

    // ------------------------------------------------------------------ funding a coin (#248)

    /// @notice Gives `amount` of a coin's Quote Asset to its burn: `burn` spends it after the coin's own Reward
    ///         Burn share, in the same capped pieces, and burns what it buys. Anyone may fund any coin of
    ///         ours; a Creator Earnings Destination of the burn does so with its coin's earnings. The native
    ///         asset is the call's value, exactly `amount`; an ERC-20 is pulled from the caller's allowance.
    function fundBurn(PoolKey calldata key, uint256 amount) external payable nonReentrant {
        PoolId id = _fund(key, amount);
        _books[id].burnFunded += amount;
        // The calls before it are the PoolManager's and the listed Quote Asset's, under the guard.
        // forge-lint: disable-next-line(reentrancy-events)
        emit BurnFunded(id, msg.sender, amount);
    }

    /// @notice Gives `amount` of a coin's Quote Asset to its Support Liquidity: `addSupport` places it after
    ///         the coin's own liquidity share, in the same capped pieces, with no coin bought. Anyone may fund
    ///         any coin of ours; a Creator Earnings Destination of the liquidity does so with its coin's
    ///         earnings. The native asset is the call's value, exactly `amount`; an ERC-20 is pulled from the
    ///         caller's allowance.
    function fundSupport(PoolKey calldata key, uint256 amount) external payable nonReentrant {
        PoolId id = _fund(key, amount);
        _books[id].supportFunded += amount;
        // forge-lint: disable-next-line(reentrancy-events)
        emit SupportFunded(id, msg.sender, amount);
    }

    /// @dev Takes `amount` of the pool's Quote Asset from the caller into the PoolManager, as this vault's
    ///      claims, in an unlock of its own: so it cannot run inside another unlock, a trader's swap among
    ///      them, and the vault's claims stay exactly what its books say waits.
    function _fund(PoolKey calldata key, uint256 amount) internal returns (PoolId) {
        Pool memory p = _load(key);
        if (amount == 0) revert NothingToSpend();
        uint256 expected = p.quote.isAddressZero() ? amount : 0;
        if (msg.value != expected) revert ValueMismatch(expected, msg.value);
        // forge-lint: disable-next-line(unused-return, reentrancy-no-eth)
        poolManager.unlock(abi.encode(Action.Fund, abi.encode(p.quote, msg.sender, amount)));
        return p.id;
    }

    // ------------------------------------------------------------------ inside the vault's own unlocks

    /// @dev Runs inside this vault's own unlocks alone: the PoolManager calls back the contract that unlocked it.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Action action, bytes memory args) = abi.decode(data, (Action, bytes));
        if (action == Action.Buy) {
            (PoolKey memory key, bool quoteIsCurrency0, uint256 amount) = abi.decode(args, (PoolKey, bool, uint256));
            return abi.encode(_swapIn(key, quoteIsCurrency0, amount));
        }
        if (action == Action.Support) {
            (PoolKey memory key, bool quoteIsCurrency0, int24 lower, int24 upper, uint128 liquidity, uint256 amount) =
                abi.decode(args, (PoolKey, bool, int24, int24, uint128, uint256));
            return abi.encode(_addLiquidity(key, quoteIsCurrency0, lower, upper, liquidity, amount));
        }
        if (action == Action.Fund) {
            (Currency asset, address funder, uint256 amount) = abi.decode(args, (Currency, address, uint256));
            _takeFunding(asset, funder, amount);
            return "";
        }
        (Currency currency, uint256 total) = abi.decode(args, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), total);
        poolManager.take(currency, address(this), total);
        return "";
    }

    /// @dev Settles `amount` of `asset` into the PoolManager from the funder (the value this vault was sent, or
    ///      the funder's allowance) and mints it to this vault as claims. Refused unless exactly `amount`
    ///      arrived, so the books never count more than the claims hold.
    function _takeFunding(Currency asset, address funder, uint256 amount) internal {
        poolManager.sync(asset);
        uint256 paid;
        if (asset.isAddressZero()) {
            paid = poolManager.settle{value: amount}();
        } else {
            // `funder` is the funding call's own caller: the data comes from this vault's own unlock.
            // forge-lint: disable-next-line(arbitrary-send-erc20)
            IERC20(Currency.unwrap(asset)).safeTransferFrom(funder, address(poolManager), amount);
            paid = poolManager.settle();
        }
        // Exactly the amount, on purpose: a transfer fee must not leave the books ahead of the claims.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (paid != amount) revert FundingShort();
        poolManager.mint(address(this), asset.toId(), amount);
    }

    /// @dev An exact-in buy of `amount` of the Quote Asset, settled by burning this vault's claims; the coins
    ///      come to this vault. With the Quote Asset specified, the hook refuses a swap that stopped early, so
    ///      the vault pays exactly `amount`.
    function _swapIn(PoolKey memory key, bool quoteIsCurrency0, uint256 amount) internal returns (uint256 coins) {
        bool zeroForOne = quoteIsCurrency0;
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -OZSafeCast.toInt256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 quoteDelta, int128 coinDelta) =
            quoteIsCurrency0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        Currency quote = quoteIsCurrency0 ? key.currency0 : key.currency1;
        Currency coin = quoteIsCurrency0 ? key.currency1 : key.currency0;
        poolManager.burn(address(this), quote.toId(), OZSafeCast.toUint256(-int256(quoteDelta)));
        coins = OZSafeCast.toUint256(int256(coinDelta));
        if (coins == 0) revert NothingToSpend();
        poolManager.take(coin, address(this), coins);
    }

    /// @dev Adds `liquidity` in `[lower, upper)`, which lies wholly on the Quote Asset's side of the price, and
    ///      settles it by burning claims. Refused unless it took Quote Asset alone, and no more than `amount`.
    function _addLiquidity(
        PoolKey memory key,
        bool quoteIsCurrency0,
        int24 lower,
        int24 upper,
        uint128 liquidity,
        uint256 amount
    ) internal returns (uint256 added) {
        // A new or grown position in a pool with no LP fee and no donations has accrued nothing; any coin in
        // the delta is refused below in any case.
        // forge-lint: disable-start(unused-return)
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: OZSafeCast.toInt256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        // forge-lint: disable-end(unused-return)
        (int128 quoteDelta, int128 coinDelta) =
            quoteIsCurrency0 ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        if (coinDelta != 0 || quoteDelta >= 0) revert NotSupportShaped();
        added = OZSafeCast.toUint256(-int256(quoteDelta));
        if (added > amount) revert NotSupportShaped();
        Currency quote = quoteIsCurrency0 ? key.currency0 : key.currency1;
        poolManager.burn(address(this), quote.toId(), added);
    }

    // ------------------------------------------------------------------ helpers

    function _load(PoolKey calldata key) internal view returns (Pool memory p) {
        StokerHook h = IStokerLaunches(factory).hook();
        p.id = key.toId();
        p.terms = h.termsOf(p.id);
        // The pool id hashes every field of the key, its hook included, so only a pool our factory opened
        // has registered terms: any other key, on another hook or with another spacing, is refused here.
        if (!p.terms.registered) revert NotAStokerPool();
        (p.quote, p.coin) = p.terms.quoteIsCurrency0 ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        p.booked = h.taxBooked(p.id);
    }

    /// @dev A part of a coin's tax so far, rounded down: each part only ever grows as the tax does, and the
    ///      parts together are never more than the tax.
    function _part(uint256 booked, uint256 shareBps) internal pure returns (uint256) {
        return booked * shareBps / BPS;
    }

    /// @dev What is left for the holders: none on a Stoke Launch or a standard Launch.
    function _holdersShare(StokerHook.Terms memory t) internal pure returns (uint256) {
        if (t.launchType != StokerHook.LaunchType.Reward) return 0;
        return BPS - t.burnShareBps - t.liquidityShareBps;
    }

    function _buy(PoolKey calldata key, Pool memory p, uint256 amount) internal returns (uint256 coins) {
        // The PoolManager calls back only this vault, and runs only our hook inside; the guard holds.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        bytes memory result =
            poolManager.unlock(abi.encode(Action.Buy, abi.encode(key, p.terms.quoteIsCurrency0, amount)));
        coins = abi.decode(result, (uint256));
    }

    /// @dev Hands `amount` of `asset` to the Distributor with the PoolManager locked: the native asset as
    ///      value, an ERC-20 approved for exactly `amount` and pulled by the Distributor.
    function _deposit(address coin, Currency asset, uint256 amount) internal {
        if (asset.isAddressZero()) {
            distributor.deposit{value: amount}(coin, asset, amount);
            return;
        }
        IERC20 token = IERC20(Currency.unwrap(asset));
        uint256 before = token.balanceOf(address(this));
        token.forceApprove(address(distributor), amount);
        distributor.deposit(coin, asset, amount);
        // Exactly `amount` must have left: the Distributor is told the amount, and pulls it.
        // forge-lint: disable-next-line(incorrect-strict-equality)
        if (before - token.balanceOf(address(this)) != amount) revert DepositShort();
        token.forceApprove(address(distributor), 0);
    }

    function _checkInterval(uint64 last) internal view {
        // Time is the only clock these contracts read; a sequencer's skew of seconds moves a piece by as much.
        // forge-lint: disable-next-line(block-timestamp)
        if (last != 0 && block.timestamp < uint256(last) + pieceInterval) {
            revert TooSoon(uint256(last) + pieceInterval);
        }
    }

    /// @dev Where the next Support Liquidity piece goes: wholly on the Quote Asset's side of the pool's tick,
    ///      from the first tick-spacing boundary past it, `supportWidthSpacings` deep. With the coin as
    ///      currency0 the pool's price is Quote Asset per coin and the range lies below the tick; with the
    ///      Quote Asset as currency0 it is coin per Quote Asset, the coin's price falls as the pool's rises,
    ///      and the range lies above. Either way the coin's price falls into it.
    function _supportRange(PoolKey calldata key, PoolId id, bool quoteIsCurrency0)
        internal
        view
        returns (int24 lower, int24 upper)
    {
        (, int24 tick,,) = poolManager.getSlot0(id);
        int24 spacing = key.tickSpacing;
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed--;
        int24 width = supportWidthSpacings * spacing;
        if (quoteIsCurrency0) {
            // A position wholly above the tick holds currency0 alone.
            lower = (compressed + 1) * spacing;
            upper = lower + width;
            int24 maxUsable = TickMath.maxUsableTick(spacing);
            if (upper > maxUsable) upper = maxUsable;
        } else {
            // A position wholly at or below the tick holds currency1 alone.
            // Rounded down to the tick spacing on purpose.
            // forge-lint: disable-next-line(divide-before-multiply)
            upper = compressed * spacing;
            lower = upper - width;
            int24 minUsable = TickMath.minUsableTick(spacing);
            if (lower < minUsable) lower = minUsable;
        }
        if (lower >= upper) revert NoRoomForSupport();
    }

    /// @dev The largest piece: `pieceBps` of the Quote Asset depth of the coin's Seed Position at the current
    ///      price, its virtual reserve (liquidity times the square root of the Quote Asset's price, in the
    ///      Quote Asset's units). A buy of that size moves the price by about twice `pieceBps`. It is never
    ///      zero: at the start price it is the Opening Value, the whole supply's worth, though the pool then
    ///      holds no Quote Asset at all, so a cap on what the pool holds would starve the burn of a coin that
    ///      has been bought and sold back; it grows with the square root of the price.
    function _pieceCap(PoolId id, bool quoteIsCurrency0) internal view returns (uint256) {
        (int24 lower, int24 upper) = IStokerLaunches(factory).seedRange(id);
        uint128 seedLiquidity =
            poolManager.getPositionLiquidity(id, Position.calculatePositionKey(factory, lower, upper, bytes32(0)));
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint256 depth = quoteIsCurrency0
            ? FullMath.mulDiv(seedLiquidity, FixedPoint96.Q96, sqrtPriceX96)
            : FullMath.mulDiv(seedLiquidity, sqrtPriceX96, FixedPoint96.Q96);
        return depth * pieceBps / BPS;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @dev The PoolManager pays this vault the native asset only in `passHoldersPart`, on its way to the
    ///      Distributor in the same call; nobody else may send it any.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ------------------------------------------------------------------ views

    /// @notice The largest piece a public call may spend in the pool now (see `_pieceCap`).
    function pieceCap(PoolKey calldata key) external view returns (uint256) {
        Pool memory p = _load(key);
        return _pieceCap(p.id, p.terms.quoteIsCurrency0);
    }

    /// @notice What waits for each path of one coin's tax: the Reward Burn's, the Support Liquidity's and the
    ///         holders' Quote Asset, and the coins bought for the holders.
    function waiting(PoolKey calldata key)
        external
        view
        returns (uint256 burnPart, uint256 supportPart, uint256 holdersPart, uint256 holdersCoins)
    {
        Pool memory p = _load(key);
        Books storage b = _books[p.id];
        burnPart = _part(p.booked, p.terms.burnShareBps) - b.burnSpent;
        supportPart = _part(p.booked, p.terms.liquidityShareBps) - b.supportSpent;
        holdersPart = _part(p.booked, _holdersShare(p.terms)) - b.holdersSpent;
        holdersCoins = b.holdersCoins;
    }

    /// @notice What was funded for a coin's burn and for its Support Liquidity (#248) and still waits, apart
    ///         from its tax: `burn` and `addSupport` spend each after the tax's own part.
    function fundedWaiting(PoolKey calldata key) external view returns (uint256 burnFunded, uint256 supportFunded) {
        Books storage b = _books[_load(key).id];
        burnFunded = b.burnFunded - b.burnFundedSpent;
        supportFunded = b.supportFunded - b.supportFundedSpent;
    }

    /// @notice What each path has spent of one coin's tax.
    function booksOf(PoolId id) external view returns (Books memory) {
        return _books[id];
    }
}
