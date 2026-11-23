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

    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager internal pm;
    IERC20 internal quote;
    StokerFactory internal factory;
    StokerHook internal hook;
    ListingStandIn internal listings;
    PoolSwapTest internal swapRouter;

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

        // Mine the hook's salt for the factory's future address with plain arithmetic: HookMiner also
        // reads each candidate's code, which on a fork is one RPC call per salt.
        address factoryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 initHash = keccak256(abi.encodePacked(type(StokerHook).creationCode, abi.encode(pm, platform)));
        bytes32 salt;
        for (uint256 i;; i++) {
            address a = vm.computeCreate2Address(bytes32(i), initHash, factoryAddr);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                salt = bytes32(i);
                break;
            }
        }
        factory = new StokerFactory(pm, listings, platform, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, TICK_SPACING, salt);
        assertEq(address(factory), factoryAddr, "factory address");
        hook = factory.hook();
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "hook permission bits");

        vm.prank(listingWriter);
        listings.list(address(quote), START_TICK);

        swapRouter = new PoolSwapTest(pm);
    }

    // ---------------------------------------------------------------- launching

    function _params(bool quoteIsCurrency0, uint256 firstBuy) internal view returns (StokerFactory.LaunchParams memory p) {
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
