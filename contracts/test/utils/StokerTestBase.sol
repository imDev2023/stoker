// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";
import {ListingStandIn} from "../../src/ListingStandIn.sol";
import {TaxVault} from "../../src/TaxVault.sol";
import {HoldersPartStandIn} from "./HoldersPartStandIn.sol";

/// @notice What the local tests and the fork tests share: deploying our contracts against a PoolManager,
///         launching, swapping, and reading the books from outside.
abstract contract StokerTestBase is Test {
    using StateLibrary for IPoolManager;

    /// The coin opens with its whole supply worth about 24.8 units of the Quote Asset (the spike's figure;
    /// a Listing's real value is the registry's, ADR 0024). A tick of quote raw units per coin raw unit.
    int24 internal constant START_TICK = -244_200;
    int24 internal constant TICK_SPACING = 200;
    uint16 internal constant PLATFORM_FEE_BPS = 100; // 1.00% (ADR 0027)
    uint16 internal constant CREATOR_SHARE_BPS = 5_000; // the Creator Ladder's first tier (ADR 0020, ADR 0027)
    uint256 internal constant SUPPLY = 1e12 * 1e18;
    /// The Tax Vault's settings (#245): a piece is at most 0.5% of the pool's Quote Asset depth (ADR 0025),
    /// a pool takes one buy and one Support Liquidity piece a minute, and Support Liquidity reaches ten tick
    /// spacings below the price.
    uint16 internal constant PIECE_BPS = 50;
    uint32 internal constant PIECE_INTERVAL = 60;
    int24 internal constant SUPPORT_WIDTH_SPACINGS = 10;

    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_DONATE_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager internal pm;
    IERC20 internal quote;
    StokerFactory internal factory;
    StokerHook internal hook;
    ListingStandIn internal listings;
    PoolSwapTest internal swapRouter;
    TaxVault internal taxVault;
    /// Stands in for the Distributor (#247) behind `IHoldersPart`.
    HoldersPartStandIn internal holdersPart;

    address internal platform = makeAddr("platform");
    address internal listingWriter = makeAddr("listingWriter");
    address internal creator;
    uint256 internal creatorKey;
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");

    /// Deploys the stand-in registry, the factory and (from the factory's constructor) the hook, and
    /// lists `quote` at START_TICK.
    function _deployStoker() internal {
        (creator, creatorKey) = makeAddrAndKey("creator");
        listings = new ListingStandIn(listingWriter);
        holdersPart = new HoldersPartStandIn();

        // The Tax Vault first, made for the factory's future address (the next deployment after it).
        address factoryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        taxVault = new TaxVault(pm, factoryAddr, holdersPart, PIECE_BPS, PIECE_INTERVAL, SUPPORT_WIDTH_SPACINGS);

        // Mine the hook's salt for the factory's future address with plain arithmetic: HookMiner also
        // reads each candidate's code, which on a fork is one RPC call per salt.
        bytes32 initHash =
            keccak256(abi.encodePacked(type(StokerHook).creationCode, abi.encode(pm, platform, address(taxVault))));
        bytes32 salt;
        for (uint256 i;; i++) {
            address a = vm.computeCreate2Address(bytes32(i), initHash, factoryAddr);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                salt = bytes32(i);
                break;
            }
        }
        factory = new StokerFactory(
            pm, listings, platform, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, TICK_SPACING, salt, taxVault
        );
        assertEq(address(factory), factoryAddr, "factory address");
        hook = factory.hook();
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "hook permission bits");

        vm.prank(listingWriter);
        listings.list(address(quote), START_TICK);

        swapRouter = new PoolSwapTest(pm);
    }

    // ---------------------------------------------------------------- launching

    function _params(bool quoteIsCurrency0, uint256 firstBuy)
        internal
        view
        returns (StokerFactory.LaunchParams memory p)
    {
        p.name = "Test Coin";
        p.symbol = "TEST";
        p.quote = address(quote);
        p.salt = _saltFor(quoteIsCurrency0, creator, p.name, p.symbol);
        p.creatorDestination = address(0); // the Creator's own wallet
        p.firstBuy = firstBuy;
    }

    /// Finds a coin salt that sorts the coin on the chosen side of the Quote Asset in the pool's key.
    function _saltFor(bool quoteIsCurrency0, address who, string memory name, string memory symbol)
        internal
        view
        returns (bytes32 salt)
    {
        bytes32 initHash = keccak256(abi.encodePacked(type(StokerCoin).creationCode, abi.encode(name, symbol)));
        for (uint256 i;; i++) {
            address coin = vm.computeCreate2Address(keccak256(abi.encode(who, bytes32(i))), initHash, address(factory));
            if ((address(quote) < coin) == quoteIsCurrency0) return salt = bytes32(i);
        }
    }

    function _launch(bool quoteIsCurrency0, uint256 firstBuy) internal returns (address coin, PoolKey memory key) {
        StokerFactory.LaunchParams memory p = _params(quoteIsCurrency0, firstBuy);
        vm.startPrank(creator);
        quote.approve(address(factory), firstBuy);
        PoolId id;
        (coin, id) = factory.launch(p);
        vm.stopPrank();
        key = _keyFor(coin);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(id), "pool id");
        assertEq(address(quote) < coin, quoteIsCurrency0, "currency order");
    }

    function _keyFor(address coin) internal view returns (PoolKey memory) {
        bool q0 = address(quote) < coin;
        return PoolKey({
            currency0: Currency.wrap(q0 ? address(quote) : coin),
            currency1: Currency.wrap(q0 ? coin : address(quote)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// An ERC-2612 permit for the factory signed by the Creator's key.
    function _permit(uint256 value, uint256 deadline) internal view returns (StokerFactory.PermitSignature memory s) {
        IERC20Permit token = IERC20Permit(address(quote));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                creator,
                address(factory),
                value,
                token.nonces(creator),
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (s.v, s.r, s.s) = vm.sign(creatorKey, digest);
        s.deadline = deadline;
    }

    // ---------------------------------------------------------------- reading from outside

    function _isQuote0(PoolKey memory key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(quote);
    }

    function _coin(PoolKey memory key) internal view returns (IERC20) {
        return IERC20(Currency.unwrap(_isQuote0(key) ? key.currency1 : key.currency0));
    }

    function _quoteCurrency() internal view returns (Currency) {
        return Currency.wrap(address(quote));
    }

    function _credit(address owner) internal view returns (uint256) {
        return hook.creditOf(owner, _quoteCurrency());
    }

    /// The hook's ERC-6909 claims on the Quote Asset in the PoolManager: what backs every Credit.
    function _hookClaims() internal view returns (uint256) {
        return pm.balanceOf(address(hook), _quoteCurrency().toId());
    }

    function _seedLiquidity(PoolKey memory key) internal view returns (uint128) {
        (int24 lower, int24 upper) = factory.seedRange(key.toId());
        return pm.getPositionLiquidity(key.toId(), Position.calculatePositionKey(address(factory), lower, upper, 0));
    }

    function _poolLiquidity(PoolKey memory key) internal view returns (uint128) {
        return pm.getLiquidity(key.toId());
    }

    // ---------------------------------------------------------------- trading through the test router

    /// `buy` spends the Quote Asset for the coin; `exactIn` pins the amount paid, otherwise the amount received.
    function _swap(PoolKey memory key, address who, bool buy, bool exactIn, uint256 amount)
        internal
        returns (BalanceDelta d)
    {
        _approveRouter(key, who);
        d = _swapApproved(key, who, buy, exactIn, amount);
    }

    function _approveRouter(PoolKey memory key, address who) internal {
        vm.startPrank(who);
        _coin(key).approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// The swap alone, one external call, for a test that expects it to revert.
    function _swapApproved(PoolKey memory key, address who, bool buy, bool exactIn, uint256 amount)
        internal
        returns (BalanceDelta d)
    {
        bool zeroForOne = buy == _isQuote0(key);
        vm.prank(who);
        d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // ---------------------------------------------------------------- the native asset (#242)

    /// The native asset in a v4 pool key: the zero address, always currency0 (never WETH, #249).
    Currency internal constant NATIVE = Currency.wrap(address(0));

    /// The coin opens with its whole supply worth about 1.6 of the native asset (about $5,000 of ETH, the
    /// Opening Value of ADR 0024; a Listing's real value is the registry's). Wei per coin raw unit.
    int24 internal constant NATIVE_START_TICK = -271_200;

    uint256 internal _nativeLaunches;

    function _listNative() internal {
        vm.prank(listingWriter);
        listings.list(address(0), NATIVE_START_TICK);
    }

    function _nativeParams(uint256 firstBuy, address destination)
        internal
        returns (StokerFactory.LaunchParams memory p)
    {
        p.name = "Native Coin";
        p.symbol = "NATV";
        p.quote = address(0);
        // The native asset sorts first whatever the coin's address, so any fresh salt will do.
        p.salt = bytes32(++_nativeLaunches);
        p.creatorDestination = destination;
        p.firstBuy = firstBuy;
    }

    /// One call with value: the Creator launches a coin paired with the native asset, the First Buy paid
    /// with the value sent. No approval and no permit.
    function _launchNative(uint256 firstBuy, address destination) internal returns (address coin, PoolKey memory key) {
        StokerFactory.LaunchParams memory p = _nativeParams(firstBuy, destination);
        PoolId id;
        vm.prank(creator);
        (coin, id) = factory.launch{value: firstBuy}(p);
        key = _nativeKey(coin);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(id), "pool id");
    }

    function _nativeKey(address coin) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: NATIVE,
            currency1: Currency.wrap(coin),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _nativeCredit(address owner) internal view returns (uint256) {
        return hook.creditOf(owner, NATIVE);
    }

    /// The hook's ERC-6909 claims on the native asset in the PoolManager: what backs every native Credit.
    function _nativeClaims() internal view returns (uint256) {
        return pm.balanceOf(address(hook), NATIVE.toId());
    }

    /// A swap in a pool paired with the native asset through the test router. A buy sends its native side
    /// as value: `amount` on exact in, `maxIn` on exact out, the rest refunded by the router.
    function _swapNative(PoolKey memory key, address who, bool buy, bool exactIn, uint256 amount, uint256 maxIn)
        internal
        returns (BalanceDelta d)
    {
        vm.prank(who);
        IERC20(Currency.unwrap(key.currency1)).approve(address(swapRouter), type(uint256).max);
        d = _swapNativeApproved(
            key, who, buy, exactIn, amount, maxIn, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
    }

    /// The swap alone, one external call, with a price limit of the caller's choosing.
    function _swapNativeApproved(
        PoolKey memory key,
        address who,
        bool buy,
        bool exactIn,
        uint256 amount,
        uint256 maxIn,
        uint160 limit
    ) internal returns (BalanceDelta d) {
        uint256 value = buy ? (exactIn ? amount : maxIn) : 0;
        vm.prank(who);
        d = swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: buy, // the native asset is currency0, so a buy is zero for one
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// The Platform Fee on a swap whose gross Quote Asset side is known (a buy's input, a sell's output
    /// before the fee), rounded up in the platform's favour.
    function _feeOnGross(uint256 gross) internal pure returns (uint256) {
        return (gross * PLATFORM_FEE_BPS + 9_999) / 10_000;
    }

    /// The Platform Fee on a swap whose net Quote Asset side is known (what reaches the pool on a buy,
    /// what reaches the trader on a sell), so that the fee is 1.00% of net plus fee, rounded up.
    function _feeOnNet(uint256 net) internal pure returns (uint256) {
        return (net * PLATFORM_FEE_BPS + (10_000 - PLATFORM_FEE_BPS) - 1) / (10_000 - PLATFORM_FEE_BPS);
    }
}
