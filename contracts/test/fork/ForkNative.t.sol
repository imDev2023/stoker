// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ForkBase} from "./ForkBase.sol";
import {RouterLib, IUniversalRouter, IV4Quoter, IPermit2Allowance, IStateView, IV4FeeAdapter} from "./RouterLib.sol";
import {
    RevertingRecipient,
    GasBurningRecipient,
    ReturnBombRecipient,
    ReentrantPayoutRecipient,
    ReentrantSwapRecipient,
    CountingRecipient
} from "../utils/Recipients.sol";
import {OpcodeScan} from "../utils/OpcodeScan.sol";
import {StokerCoin} from "../../src/StokerCoin.sol";
import {StokerHook} from "../../src/StokerHook.sol";

/// Safe 1.4.1 on Robinhood Chain, at the addresses its deterministic deployment gives every chain.
interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafeSetup {
    function setup(
        address[] calldata owners,
        uint256 threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}

/// The native asset as a Quote Asset on the real PoolManager (#242): a launch in one call with value, the
/// four trades through both Universal Routers the chain's traffic uses, and the Payout Call against an
/// ordinary wallet, a Safe and recipients that refuse, re-enter or burn their gas.
contract ForkNativeTest is ForkBase {
    using StateLibrary for IPoolManager;

    error V4TooLittleReceived(uint256 minAmountOutReceived, uint256 amountReceived);
    error V4TooMuchRequested(uint256 maxAmountInRequested, uint256 amountRequested);

    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_L2_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    address internal router = UNIVERSAL_ROUTER;
    /// The Creator's Destination in the trading tests: it counts every payment that reaches it.
    CountingRecipient internal destination;

    struct Trade {
        bool buy;
        bool exactIn;
        uint256 amount;
    }

    function setUp() public override {
        super.setUp();
        _listNative();
        destination = new CountingRecipient();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 100 ether);
    }

    // ---------------------------------------------------------------- the launch

    /// One call with value launches a coin paired with native ETH and makes the First Buy: no approval,
    /// no permit, and nothing kept by the factory.
    function test_fork_native_launch_oneCallWithValue_noApprovalNoPermit() public {
        uint256 before = creator.balance;
        uint256 gasBefore = gasleft();
        (address coin, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        emit log_named_uint("launch gas, native First Buy included", gasBefore - gasleft());
        StokerCoin c = StokerCoin(coin);

        assertEq(Currency.unwrap(key.currency0), address(0), "native ETH in the pool key, never WETH");
        assertEq(before - creator.balance, 0.1 ether, "the Creator paid exactly the value sent");
        assertEq(quote.allowance(creator, address(factory)), 0, "no approval was given");
        assertGt(c.balanceOf(creator), 0, "the First Buy delivered coins");
        emit log_named_uint("coins for 0.1 ETH", c.balanceOf(creator));
        assertEq(address(factory).balance, 0, "the factory keeps nothing");
        assertEq(address(hook).balance, 0, "the hook holds nothing");
        assertEq(c.balanceOf(address(pm)) + c.balanceOf(creator), c.totalSupply(), "every coin accounted");

        (,, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(key.toId());
        assertEq(lpFee, 0);
        assertEq(protocolFee, 0);
        assertEq(_poolLiquidity(key), _seedLiquidity(key));

        uint256 fee = _feeOnGross(0.1 ether);
        assertEq(_nativeCredit(creator), fee * CREATOR_SHARE_BPS / 10_000, "the Creator's Credit");
        assertEq(_nativeCredit(platform), fee - _nativeCredit(creator));
        assertEq(_nativeClaims(), fee);

        assertFalse(OpcodeScan.contains(address(hook).code, OpcodeScan.NUMBER));
        assertFalse(OpcodeScan.contains(address(factory).code, OpcodeScan.NUMBER));
    }

    // ---------------------------------------------------------------- trading through the router

    function _approveRouter(address who, address coin) internal {
        vm.startPrank(who);
        IERC20(coin).approve(PERMIT2, type(uint256).max);
        IPermit2Allowance(PERMIT2).approve(coin, router, type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _quote(PoolKey memory key, Trade memory t) internal returns (uint256 figure) {
        IV4Quoter.QuoteExactSingleParams memory q = IV4Quoter.QuoteExactSingleParams(key, t.buy, uint128(t.amount), "");
        (figure,) =
            t.exactIn ? IV4Quoter(V4_QUOTER).quoteExactInputSingle(q) : IV4Quoter(V4_QUOTER).quoteExactOutputSingle(q);
    }

    /// One trade through the router with `limit` as the slippage bound. A buy sends its native side as
    /// value (the amount on exact in, the bound on exact out) and settles currency zero with it; a sell
    /// takes native ETH to the trader.
    function _route(address who, PoolKey memory key, Trade memory t, uint256 limit) internal {
        (Currency cin, Currency cout) = t.buy ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes memory actions;
        bytes[] memory params = new bytes[](3);
        if (t.exactIn) {
            actions = abi.encodePacked(RouterLib.SWAP_EXACT_IN_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL);
            params[0] =
                abi.encode(RouterLib.ExactInputSingleParams(key, t.buy, uint128(t.amount), uint128(limit), 0, ""));
            params[1] = abi.encode(cin, t.amount);
            params[2] = abi.encode(cout, limit);
        } else {
            actions = abi.encodePacked(RouterLib.SWAP_EXACT_OUT_SINGLE, RouterLib.SETTLE_ALL, RouterLib.TAKE_ALL);
            params[0] =
                abi.encode(RouterLib.ExactOutputSingleParams(key, t.buy, uint128(t.amount), uint128(limit), 0, ""));
            params[1] = abi.encode(cin, limit);
            params[2] = abi.encode(cout, t.amount);
        }
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 value = t.buy ? (t.exactIn ? t.amount : limit) : 0;
        vm.prank(who);
        IUniversalRouter(router).execute{value: value}(
            abi.encodePacked(RouterLib.V4_SWAP), inputs, block.timestamp + 60
        );
    }

    /// Buys and sells, exact in and exact out, deliver the Quoter's figure to the wei, a bound one wei
    /// tighter reverts, and each swap's Credits sum to 1.00% of its native side, paid to nobody.
    function test_fork_native_router_fourTradesDeliverTheQuote_creditsOnePercent() public {
        _fourTrades();
    }

    /// The same through Universal Router v2.1.2.
    function test_fork_native_router_v212_fourTradesDeliverTheQuote_creditsOnePercent() public {
        router = UNIVERSAL_ROUTER_V2_1_2;
        _fourTrades();
    }

    function _fourTrades() internal {
        (address coin, PoolKey memory key) = _launchNative(0.1 ether, address(destination));
        _approveRouter(trader, coin);
        Trade[4] memory trades = [
            Trade(true, true, 1 ether),
            Trade(true, false, 1e10 ether),
            Trade(false, true, 1e10 ether),
            Trade(false, false, 0.2 ether)
        ];
        for (uint256 i; i < trades.length; i++) {
            Trade memory t = trades[i];
            uint256 figure = _quote(key, t);

            uint256 snap = vm.snapshotState();
            if (t.exactIn) {
                vm.expectRevert(abi.encodeWithSelector(V4TooLittleReceived.selector, figure + 1, figure));
                _route(trader, key, t, figure + 1);
            } else {
                vm.expectRevert(abi.encodeWithSelector(V4TooMuchRequested.selector, figure - 1, figure));
                _route(trader, key, t, figure - 1);
            }
            vm.revertToState(snap);

            uint256 r0 = router.balance;
            uint256 q0 = trader.balance;
            uint256 c0 = IERC20(coin).balanceOf(trader);
            uint256 claims0 = _nativeClaims();
            uint256 dc0 = _nativeCredit(address(destination));
            uint256 pc0 = _nativeCredit(platform);
            _route(trader, key, t, figure);
            uint256 q1 = trader.balance;
            uint256 c1 = IERC20(coin).balanceOf(trader);

            uint256 fee = _nativeClaims() - claims0;
            uint256 expected;
            if (t.buy && t.exactIn) {
                assertEq(q0 - q1, t.amount, "paid");
                assertEq(c1 - c0, figure, "buy exact in: the Quoter's coins");
                expected = _feeOnGross(q0 - q1);
            } else if (t.buy) {
                assertEq(q0 - q1, figure, "buy exact out: the Quoter's price");
                assertEq(c1 - c0, t.amount, "received");
                expected = _feeOnNet(q0 - q1 - fee);
            } else if (t.exactIn) {
                assertEq(c0 - c1, t.amount, "sold");
                assertEq(q1 - q0, figure, "sell exact in: the Quoter's proceeds");
                expected = _feeOnGross(q1 - q0 + fee);
            } else {
                assertEq(c0 - c1, figure, "sell exact out: the Quoter's coins");
                assertEq(q1 - q0, t.amount, "received");
                expected = _feeOnNet(q1 - q0);
            }
            assertGt(fee, 0);
            assertEq(fee, expected, "1.00% of the native side");
            uint256 dc = _nativeCredit(address(destination)) - dc0;
            uint256 pc = _nativeCredit(platform) - pc0;
            assertEq(dc + pc, fee, "the Credits sum to the fee");
            assertEq(dc, fee * CREATOR_SHARE_BPS / 10_000, "the Creator's tier");

            // No native transfer to the Creator's Destination or the platform, and nothing left behind.
            assertEq(destination.payments(), 0, "no swap paid the Creator's Destination");
            assertEq(platform.balance, 0, "no swap paid the platform");
            assertEq(address(hook).balance, 0, "the hook holds no ETH");
            assertEq(router.balance, r0, "the router keeps none of the trade's ETH");
        }
    }

    /// Anyone may push the protocol fee controller's policy into the PoolManager; for a pool of ours paired
    /// with native ETH it resolves to 0, as for one paired with a Stock Token.
    function test_fork_native_protocolFee_policyLeavesOurPoolAtZero() public {
        (, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        assertEq(IV4FeeAdapter(PROTOCOL_FEE_CONTROLLER).getFee(key), 0, "the policy's figure for our pool");
        vm.prank(stranger);
        IV4FeeAdapter(PROTOCOL_FEE_CONTROLLER).triggerFeeUpdate(key);
        (,, uint24 inForce,) = IStateView(STATE_VIEW).getSlot0(PoolId.unwrap(key.toId()));
        assertEq(inForce, 0, "no protocol fee in force after the trigger");
    }

    // ---------------------------------------------------------------- the Payout Call

    function _safe() internal returns (address safe) {
        address[] memory owners = new address[](1);
        owners[0] = makeAddr("safeOwner");
        bytes memory init = abi.encodeCall(
            ISafeSetup.setup, (owners, 1, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0)))
        );
        safe = ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_L2_SINGLETON, init, 242);
    }

    function _creditThrough(address who) internal {
        (address coin, PoolKey memory key) = _launchNative(0.01 ether, who);
        _approveRouter(trader, coin);
        _route(trader, key, Trade(true, true, 0.5 ether), 0);
        assertGt(_nativeCredit(who), 0);
    }

    /// A stranger's Payout Call pays the ordinary wallet, a Safe and the platform in full, while recipients
    /// that revert, burn their gas, return a bomb or re-enter each keep their Credit owed, to themselves.
    function test_fork_native_payout_walletAndSafePaid_hostileRecipientsStayOwed() public {
        _creditThrough(creator);
        address safe = _safe();
        _creditThrough(safe);
        (, PoolKey memory anyKey) = _launchNative(0, address(0));
        address[5] memory hostile = [
            address(new RevertingRecipient()),
            address(new GasBurningRecipient()),
            address(new ReturnBombRecipient()),
            address(new ReentrantPayoutRecipient(hook, false)),
            address(new ReentrantSwapRecipient(pm, anyKey, false))
        ];
        for (uint256 i; i < hostile.length; i++) {
            _creditThrough(hostile[i]);
        }

        address[] memory owners = new address[](hostile.length + 3);
        owners[0] = creator;
        owners[1] = safe;
        for (uint256 i; i < hostile.length; i++) {
            owners[i + 2] = hostile[i];
        }
        owners[owners.length - 1] = platform;

        uint256 creatorOwed = _nativeCredit(creator);
        uint256 safeOwed = _nativeCredit(safe);
        uint256 platformOwed = _nativeCredit(platform);
        uint256[5] memory hostileOwed;
        uint256 stillOwed;
        for (uint256 i; i < hostile.length; i++) {
            hostileOwed[i] = _nativeCredit(hostile[i]);
            stillOwed += hostileOwed[i];
        }
        uint256 creatorBefore = creator.balance;

        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.CreditPaid(safe, NATIVE, safeOwed);
        uint256 gasBefore = gasleft();
        // A Keeper's budget, not Foundry's near-unlimited default, so a gas burner would show.
        vm.prank(stranger);
        hook.payout{gas: 1_000_000}(NATIVE, owners);
        emit log_named_uint("Payout Call gas, 8 owners, 5 refusing", gasBefore - gasleft());

        assertEq(creator.balance - creatorBefore, creatorOwed, "the ordinary wallet paid");
        assertEq(safe.balance, safeOwed, "the Safe paid within the gas a payment carries");
        assertEq(platform.balance, platformOwed, "the platform paid");
        for (uint256 i; i < hostile.length; i++) {
            assertEq(_nativeCredit(hostile[i]), hostileOwed[i], "a hostile recipient stays owed");
            assertEq(hostile[i].balance, 0);
        }
        assertEq(_nativeClaims(), stillOwed, "the claims back exactly what is still owed");
        assertEq(hook.totalCredits(NATIVE), stillOwed);
        assertEq(address(hook).balance, 0, "the hook keeps no ETH");
    }

    /// The lenient re-entering recipients, on the real PoolManager: a second Payout Call meets the guard,
    /// and a swap or take from inside the payment meets a locked PoolManager; each is paid exactly once.
    function test_fork_native_payout_reentryMeetsTheGuardAndALockedPoolManager() public {
        (, PoolKey memory anyKey) = _launchNative(0, address(0));
        ReentrantPayoutRecipient again = new ReentrantPayoutRecipient(hook, true);
        ReentrantSwapRecipient direct = new ReentrantSwapRecipient(pm, anyKey, true);
        _creditThrough(address(again));
        _creditThrough(address(direct));
        uint256 owedAgain = _nativeCredit(address(again));
        uint256 owedDirect = _nativeCredit(address(direct));
        address[] memory two = new address[](2);
        two[0] = address(again);
        two[1] = address(direct);
        vm.prank(stranger);
        hook.payout(NATIVE, two);
        assertEq(again.met(), StokerHook.PayoutReentered.selector);
        assertEq(direct.swapMet(), IPoolManager.ManagerLocked.selector);
        assertEq(direct.takeMet(), IPoolManager.ManagerLocked.selector);
        assertEq(address(again).balance, owedAgain);
        assertEq(address(direct).balance, owedDirect);
    }
}
