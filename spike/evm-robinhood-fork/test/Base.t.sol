// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {StokerFactory} from "../src/StokerFactory.sol";
import {StokerHook} from "../src/StokerHook.sol";
import {StokerCoin} from "../src/StokerCoin.sol";

/// @notice Shared fixture: a fork of Robinhood Chain (4663) pinned at one block, our factory and
///         hook deployed against the chain's real PoolManager, NVDA listed as a Quote Asset.
abstract contract ForkBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Every test in this spike forks this block (2026-11-22, timestamp 1795370197).
    uint256 internal constant FORK_BLOCK = 120_800_000;

    // Robinhood Chain mainnet addresses (knowledge base, robinhood-chain/44-uniswap-v4-hooks.md).
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address internal constant UNIVERSAL_ROUTER = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address internal constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    // NVIDIA • Robinhood Token, an ERC-8056 stock token behind the shared beacon.
    IERC20 internal constant NVDA = IERC20(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC);
    address internal constant STOCK_REGISTRY = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    // NVDA listing: the coin opens at a fully diluted value of about 24.8 NVDA and graduates at
    // about 20 times that. Ticks are of the coin's price in NVDA, as if the coin were currency0.
    int24 internal constant START_TICK = -244_200;
    int24 internal constant GRADUATION_TICK = -214_200;
    uint128 internal constant FLUSH_THRESHOLD = 0.01 ether; // 0.01 NVDA

    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    address internal platform = makeAddr("platform");
    address internal creator;
    uint256 internal creatorKey;
    address internal creatorDestination = makeAddr("creatorDestination");
    address internal trader = makeAddr("trader");
    address internal referrer = makeAddr("referrer");

    StokerFactory internal factory;
    StokerHook internal hook;
    PoolSwapTest internal swapRouter;

    function setUp() public virtual {
        vm.createSelectFork("robinhood", FORK_BLOCK);
        (creator, creatorKey) = makeAddrAndKey("creator");

        // Mine the hook's salt for the factory's future address. Plain computation: HookMiner's
        // own loop also reads each candidate's code, which on a fork is one RPC call per salt.
        address factoryAddr = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        bytes32 initHash =
            keccak256(abi.encodePacked(type(StokerHook).creationCode, abi.encode(POOL_MANAGER, platform)));
        bytes32 salt;
        for (uint256 i;; i++) {
            address a = vm.computeCreate2Address(bytes32(i), initHash, factoryAddr);
            if (uint160(a) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                salt = bytes32(i);
                break;
            }
        }
        factory = new StokerFactory(POOL_MANAGER, platform, salt);
        assertEq(address(factory), factoryAddr);
        hook = factory.hook();
        factory.list(address(NVDA), START_TICK, GRADUATION_TICK, FLUSH_THRESHOLD);

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        deal(address(NVDA), creator, 1_000 ether);
        deal(address(NVDA), trader, 1_000 ether);
        vm.prank(trader);
        NVDA.approve(address(swapRouter), type(uint256).max);
    }

    // ------------------------------------------------------------------ launch helpers

    function _params(bool quoteIsCurrency0) internal view returns (StokerFactory.LaunchParams memory p) {
        p.name = "Spike Coin";
        p.symbol = "SPIKE";
        p.quote = address(NVDA);
        p.salt = _saltFor(quoteIsCurrency0, creator, p.name, p.symbol);
        p.creatorDestination = creatorDestination;
        p.creatorShareBps = 5_000; // the Creator Ladder's first tier: half the Platform Fee
    }

    /// @dev Finds a coin salt that sorts the coin on the chosen side of the Quote Asset.
    function _saltFor(bool quoteIsCurrency0, address who, string memory name, string memory symbol)
        internal
        view
        returns (bytes32 salt)
    {
        bytes32 initHash = keccak256(
            abi.encodePacked(type(StokerCoin).creationCode, abi.encode(name, symbol, address(factory)))
        );
        for (uint256 i;; i++) {
            address coin = vm.computeCreate2Address(keccak256(abi.encode(who, bytes32(i))), initHash, address(factory));
            if ((address(NVDA) < coin) == quoteIsCurrency0) return salt = bytes32(i);
        }
    }

    function _launch(StokerFactory.LaunchParams memory p) internal returns (address coin, PoolKey memory key) {
        vm.startPrank(creator);
        NVDA.approve(address(factory), p.firstBuy);
        PoolId id;
        (coin, id) = factory.launch(p);
        vm.stopPrank();
        key = _keyFor(coin);
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(id));
    }

    function _keyFor(address coin) internal view returns (PoolKey memory) {
        bool quoteIsCurrency0 = address(NVDA) < coin;
        return PoolKey({
            currency0: Currency.wrap(quoteIsCurrency0 ? address(NVDA) : coin),
            currency1: Currency.wrap(quoteIsCurrency0 ? coin : address(NVDA)),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(hook))
        });
    }

    // ------------------------------------------------------------------ swap helpers

    function _isQuote0(PoolKey memory key) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(NVDA);
    }

    function _coin(PoolKey memory key) internal pure returns (IERC20) {
        return IERC20(Currency.unwrap(_isQuote0(key) ? key.currency1 : key.currency0));
    }

    /// @dev Swaps through a plain test router. `buy` spends NVDA for the coin. `exactIn` pins the
    ///      amount paid in; otherwise it pins the amount received.
    function _swap(PoolKey memory key, address who, bool buy, bool exactIn, uint256 amount, bytes memory hookData)
        internal
        returns (BalanceDelta d)
    {
        bool zeroForOne = buy == _isQuote0(key);
        vm.startPrank(who);
        _coin(key).approve(address(swapRouter), type(uint256).max);
        NVDA.approve(address(swapRouter), type(uint256).max);
        d = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    function _tick(PoolKey memory key) internal view returns (int24 tick) {
        (, tick,,) = POOL_MANAGER.getSlot0(key.toId());
    }

    /// @dev The coin's price expressed as a tick of NVDA per coin, whatever the currency order.
    function _coinPriceTick(PoolKey memory key) internal view returns (int24) {
        int24 t = _tick(key);
        return _isQuote0(key) ? -t : t;
    }
}
