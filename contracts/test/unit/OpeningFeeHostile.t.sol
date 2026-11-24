// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {OpeningFeeHelpers} from "../utils/OpeningFeeHelpers.sol";
import {StokerFactory} from "../../src/StokerFactory.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// The Opening Fee's exemption and routes, tested as hostile (#246): the First Buy's exemption reads the
/// swap's `sender`, the factory, which swaps only inside a launch; nothing else can make it swap or carry the
/// exemption to another buy, and a buy reached through another pool or a route pays the coin's own fee.
contract OpeningFeeHostileTest is TaxLocalBase, OpeningFeeHelpers {
    /// The factory's callback answers the PoolManager alone, and the PoolManager calls back only the
    /// contract that unlocked it: nobody can make the factory swap but its own launch.
    function test_opening_nobodyElseCanMakeTheFactorySwap() public {
        PoolKey memory key = _launchOpen(0, 0, 0);
        // A launch's own data, aimed at the existing pool: a First Buy for the stranger.
        bytes memory seed = abi.encode(key, address(0), address(quote), stranger, true, int24(0), int24(0), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(StokerFactory.NotPoolManager.selector);
        factory.unlockCallback(seed);
        // Unlocking the PoolManager calls back the caller, never the factory.
        CallsBack attacker = new CallsBack(pm);
        vm.expectRevert(StokerFactory.NotPoolManager.selector);
        attacker.unlockAndAskTheFactory(address(factory), seed);
        assertEq(hook.openingFeeBooked(key.toId()), 0, "nothing traded");
    }

    /// A contract that launches and buys more in the same transaction: its First Buy is exempt, its second
    /// buy, in the launch's own second, pays the whole Opening Fee. The exemption is the factory's swap's,
    /// never the Creator's or the transaction's.
    function test_opening_launchingAndBuyingInOneTransactionPaysItOnTheSecondBuy() public {
        LaunchThenBuy bot = new LaunchThenBuy(factory, swapRouter);
        vm.deal(address(bot), 10 ether);
        StokerFactory.LaunchParams memory p = _nativeParams(0.1 ether, creator);
        uint256 claims0 = _nativeClaims();
        (address coin, uint256 secondBuy) = bot.run(p, 1 ether);
        PoolKey memory key = _nativeKey(coin);
        Fees memory f = _feesOfGross(secondBuy, 0, 0, _openingRateAt(0, PLATFORM_FEE_BPS));
        assertEq(hook.openingFeeBooked(key.toId()), f.opening, "the second buy paid the whole Opening Fee");
        assertEq(
            _nativeClaims() - claims0,
            _rateOfGross(0.1 ether, PLATFORM_FEE_BPS) + f.fee,
            "the Platform Fee on both buys, nothing more"
        );
        // The Creator's own buy in a later block pays it too.
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(_launchedAt(key) + 5);
        vm.deal(creator, 10 ether);
        Seen memory s = _tradeAndSeeAs(creator, key, true, true, 0.05 ether, 0);
        _checkBuy(s, true, 5, 0, 0);
        assertGt(s.opening, 0, "the Creator's later buy pays it");
    }

    /// A route through two pools in one unlock, both coins inside their windows: selling coin A pays no
    /// Opening Fee, and buying coin B with what came out pays B's own, on exactly that amount.
    function test_opening_aRouteThroughAnotherPoolPaysTheCoinsOwnFee() public {
        PoolKey memory a = _launchOpen(2, 0, 0.1 ether);
        PoolKey memory b = _launchOpen(2, 1, 0);
        vm.warp(_launchedAt(b) + 4);
        TwoHop router = new TwoHop(pm);
        uint256 coinsIn = _coinOfKey(a).balanceOf(creator) / 2;
        vm.prank(creator);
        _coinOfKey(a).transfer(address(router), coinsIn);
        (uint256 ethMid, uint256 coinsOut) = router.route(a, b, coinsIn);
        assertEq(hook.openingFeeBooked(a.toId()), 0, "the sell of A paid none");
        Fees memory f = _feesOfGross(ethMid, 0, TAX_BPS, _openingRateAt(4, PLATFORM_FEE_BPS + TAX_BPS));
        assertEq(hook.openingFeeBooked(b.toId()), f.opening, "B's own Opening Fee on what reached it");
        assertGt(f.opening, 0, "and it is not nothing");
        assertEq(_coinOfKey(b).balanceOf(address(router)), coinsOut, "the router got B's coins");
    }

    /// The vault's own buys are no way around it: inside the window it makes none (see OpeningFeeVault.t.sol),
    /// and once the window is over nobody pays it.
    function test_opening_theVaultsBuyIsNoWayIn() public {
        PoolKey memory key = _launchOpen(0, 1, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TaxVault.TooSoon.selector, _launchedAt(key) + OPENING_FEE_DURATION));
        taxVault.burn(key);
    }

    /// The factory refuses an Opening Fee no deployment should have: no start figure, one over 99%, no
    /// duration, or one over ten minutes; the bounds themselves are taken.
    function test_opening_theFactorysSettingsAreBounded() public {
        uint16[4] memory starts = [uint16(0), 9_901, OPENING_FEE_START_BPS, OPENING_FEE_START_BPS];
        uint32[4] memory durations = [OPENING_FEE_DURATION, OPENING_FEE_DURATION, 0, 601];
        for (uint256 i; i < 4; i++) {
            vm.expectRevert(StokerFactory.InvalidSettings.selector);
            new StokerFactory(
                pm, registry, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, bytes32(0), taxVault, starts[i], durations[i]
            );
        }
        address next = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        TaxVault vault = new TaxVault(pm, next, holdersPart, PIECE_BPS, PIECE_INTERVAL, SUPPORT_WIDTH_SPACINGS);
        bytes32 initHash =
            keccak256(abi.encodePacked(type(StokerHook).creationCode, abi.encode(pm, keys, address(vault))));
        bytes32 salt;
        for (uint256 i;; i++) {
            if (uint160(vm.computeCreate2Address(bytes32(i), initHash, next)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                salt = bytes32(i);
                break;
            }
        }
        StokerFactory edge =
            new StokerFactory(pm, registry, PLATFORM_FEE_BPS, CREATOR_SHARE_BPS, salt, vault, 9_900, 600);
        assertEq(address(edge), next, "the factory the vault was made for");
        assertEq(edge.openingFeeStartBps(), 9_900);
        assertEq(edge.openingFeeDuration(), 600);
    }
}

/// A start figure below what a buy's standing fees already take (a deployment's setting can be anything up
/// to 99%): the Opening Fee is then nothing for that buy, and the buy is never refused for it.
contract OpeningFeeLowStartTest is TaxLocalBase, OpeningFeeHelpers {
    function setUp() public override {
        openingFeeStartBps = 150;
        super.setUp();
    }

    function test_opening_aStartFigureUnderTheStandingFeesChargesNothing() public {
        for (uint256 kind; kind < 3; kind++) {
            uint256 snap = vm.snapshotState();
            PoolKey memory key = _launchOpen(kind, 0, 0);
            // With a referrer at the cap the standing fees are 2.00%, over the 1.50% start: nothing more.
            Seen memory s = _tradeAndSee(key, true, true, _buyAmount(key, true), REFERRER_FEE_CAP_BPS);
            assertEq(s.opening, 0, "no Opening Fee above the start figure");
            assertEq(s.creatorCredit + s.platformCredit, _rateOfGross(s.quoteIn, PLATFORM_FEE_BPS), "the fee");
            // With none they are 1.00%: the Opening Fee is the half percent above them, at the launch's second.
            s = _tradeAndSee(key, true, true, _buyAmount(key, true), 0);
            assertEq(_taken(s), _rateOfGross(s.quoteIn, 150), "1.50% together");
            vm.revertToState(snap);
        }
    }
}

/// Opens an unlock of its own and tries to have the factory's callback run inside it.
contract CallsBack is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function unlockAndAskTheFactory(address factory, bytes calldata seed) external {
        pm.unlock(abi.encode(factory, seed));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (address factory, bytes memory seed) = abi.decode(data, (address, bytes));
        // The factory refuses: this call is not the PoolManager's.
        return IUnlockCallback(factory).unlockCallback(seed);
    }
}

/// Launches a coin paired with the native asset with a First Buy, then buys more in the same transaction.
contract LaunchThenBuy {
    StokerFactory internal immutable factory;
    PoolSwapTest internal immutable router;

    constructor(StokerFactory factory_, PoolSwapTest router_) {
        factory = factory_;
        router = router_;
    }

    function run(StokerFactory.LaunchParams calldata p, uint256 buy) external returns (address coin, uint256) {
        (coin,) = factory.launch{value: p.firstBuy}(p);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(coin),
            fee: 0,
            tickSpacing: factory.tickSpacing(),
            hooks: IHooks(address(factory.hook()))
        });
        router.swap{value: buy}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(buy), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        return (coin, buy);
    }

    receive() external payable {}
}

/// Sells coin A for the native asset and buys coin B with all of it, in one unlock: a route through
/// another pool.
contract TwoHop is IUnlockCallback {
    IPoolManager internal immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function route(PoolKey calldata a, PoolKey calldata b, uint256 coinsIn)
        external
        returns (uint256 ethMid, uint256 coinsOut)
    {
        return abi.decode(pm.unlock(abi.encode(a, b, coinsIn)), (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory a, PoolKey memory b, uint256 coinsIn) = abi.decode(data, (PoolKey, PoolKey, uint256));
        // Sell coin A (currency1) for the native asset (currency0): one for zero.
        BalanceDelta da = pm.swap(
            a,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(coinsIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 ethMid = uint256(int256(da.amount0()));
        // Buy coin B with exactly that native asset: zero for one.
        BalanceDelta db = pm.swap(
            b,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethMid), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );
        uint256 coinsOut = uint256(int256(db.amount1()));
        // Pay coin A, take coin B; the native asset nets to nothing.
        pm.sync(a.currency1);
        IERC20(Currency.unwrap(a.currency1)).transfer(address(pm), coinsIn);
        pm.settle();
        pm.take(b.currency1, address(this), coinsOut);
        return abi.encode(ethMid, coinsOut);
    }
}
