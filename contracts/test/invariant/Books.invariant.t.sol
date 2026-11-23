// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";

import {LocalBase} from "../utils/LocalBase.sol";

/// Drives trades, Payout Calls and refused liquidity changes with random actors and amounts, and
/// measures every swap from outside.
contract BooksHandler is Test {
    BooksInvariantTest internal immutable t;
    PoolKey internal key;
    address[4] internal actors;
    PoolModifyLiquidityTest internal lpRouter;
    PoolDonateTest internal donateRouter;

    // Ghosts: sums over every swap the handler made.
    uint256 public feesTaken; // what the hook's claims grew by on swaps
    uint256 public creditsRecorded; // what the Credits grew by on swaps
    uint256 public feeFormulaMismatches; // swaps whose fee was not 1.00% of the Quote Asset's side
    uint256 public paidOut; // what Payout Calls delivered
    uint256 public swaps;
    uint256 public limitedSwaps; // swaps that went through with a price limit of their own
    uint256 public lockBreaches; // a removal, a foreign add or a donation that went through

    constructor(BooksInvariantTest t_, PoolKey memory key_) {
        t = t_;
        key = key_;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(t.poolManager()));
        donateRouter = new PoolDonateTest(IPoolManager(t.poolManager()));
    }

    function trade(uint256 actorSeed, bool buy, bool exactIn, uint256 amount) external {
        _trade(actorSeed, buy, exactIn, amount, 0);
    }

    /// The same trade with a price limit of its own a few tick spacings away, which stops many of them
    /// early: those with the Quote Asset as the specified side are refused, the others pay on what moved.
    function tradeWithLimit(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, uint256 spacings) external {
        _trade(actorSeed, buy, exactIn, amount, int24(int256(bound(spacings, 1, 20))) * 200);
    }

    function _trade(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, int24 limitTicks) internal {
        address who = actors[actorSeed % actors.length];
        uint256 coins = t.coinBalance(who);
        if (!buy && coins < 1e9) buy = true;
        if (buy) amount = bound(amount, 1e9, exactIn ? 500 ether : 2e10 ether);
        else amount = bound(amount, 1e9, exactIn ? coins : 20 ether);
        t.fund(who);

        uint256 q0 = t.quoteBalance(who);
        uint256 claims0 = t.hookClaims();
        uint256 credits0 = t.allCredits();
        try t.swapAs(who, buy, exactIn, amount, limitTicks) {}
        catch {
            // A sell asking for more than the pool can give or the actor holds, or a swap with the Quote
            // Asset specified that its limit stopped early.
            return;
        }
        uint256 q1 = t.quoteBalance(who);
        uint256 fee = t.hookClaims() - claims0;
        feesTaken += fee;
        creditsRecorded += t.allCredits() - credits0;
        swaps++;
        if (limitTicks != 0) limitedSwaps++;

        uint256 expected;
        if (buy && exactIn) expected = t.feeOnGross(q0 - q1);
        else if (buy) expected = t.feeOnNet(q0 - q1 - fee);
        else if (exactIn) expected = t.feeOnGross(q1 - q0 + fee);
        else expected = t.feeOnNet(q1 - q0);
        if (fee != expected) feeFormulaMismatches++;
    }

    function payout(uint256 seed) external {
        address[] memory owners = new address[](2);
        owners[0] = seed % 2 == 0 ? t.creatorAddr() : t.platformAddr();
        owners[1] = seed % 3 == 0 ? t.platformAddr() : actors[seed % actors.length];
        uint256 before = t.quoteBalance(owners[0]) + (owners[1] == owners[0] ? 0 : t.quoteBalance(owners[1]));
        t.payoutAs(actors[seed % actors.length], owners);
        uint256 after_ = t.quoteBalance(owners[0]) + (owners[1] == owners[0] ? 0 : t.quoteBalance(owners[1]));
        paidOut += after_ - before;
    }

    function tryRemove(uint256 actorSeed, uint256 liquidity) external {
        (int24 lower, int24 upper) = t.seedRangeOf();
        vm.prank(actors[actorSeed % actors.length]);
        try lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams(lower, upper, -int256(bound(liquidity, 0, 1e30)), 0), ""
        ) {
            lockBreaches++;
        } catch {}
    }

    function tryAdd(uint256 actorSeed) external {
        address who = actors[actorSeed % actors.length];
        t.fund(who);
        t.approveAs(who, address(lpRouter));
        vm.prank(who);
        try lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-887_200, 887_200, 1e15, 0), "") {
            lockBreaches++;
        } catch {}
    }

    function tryDonate(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        t.fund(who);
        t.approveAs(who, address(donateRouter));
        amount = bound(amount, 1, 10 ether);
        vm.prank(who);
        try donateRouter.donate(key, amount, amount, "") {
            lockBreaches++;
        } catch {}
    }
}

/// Invariants of the books (#241): the Seed Position never falls, and the Credits of every swap sum to
/// the fee the hook took, which is always 1.00% of the Quote Asset's side.
contract BooksInvariantTest is LocalBase {
    using StateLibrary for IPoolManager;

    PoolKey internal key;
    address internal coin;
    uint128 internal seed;
    BooksHandler internal handler;

    function setUp() public override {
        super.setUp();
        (coin, key) = _launch(true, 1 ether);
        seed = _seedLiquidity(key);
        handler = new BooksHandler(this, key);
        targetContract(address(handler));
    }

    /// The campaign did trade: a suite whose every swap reverted would prove nothing.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap went through");
    }

    function invariant_seedLiquidityNeverFalls() public view {
        assertEq(_seedLiquidity(key), seed);
        assertEq(handler.lockBreaches(), 0, "a removal, foreign add or donation went through");
    }

    function invariant_creditsOfEverySwapSumToTheFeeTaken() public view {
        assertEq(handler.creditsRecorded(), handler.feesTaken());
        assertEq(handler.feeFormulaMismatches(), 0, "a fee that was not 1.00% of the Quote Asset's side");
    }

    function invariant_claimsBackEveryCredit() public view {
        // Every Credit still owed is backed by the hook's claims, and nothing else is.
        assertEq(_hookClaims(), hook.totalCredits(_quoteCurrency()));
        assertEq(_hookClaims(), _credit(creator) + _credit(platform));
        assertEq(quote.balanceOf(address(hook)), 0, "the hook holds no Quote Asset");
        assertEq(_coin(key).balanceOf(address(hook)), 0, "the hook holds no coin");
    }

    function invariant_everyPaymentWasACredit() public view {
        // What Payout Calls delivered plus what is still owed is what the swaps credited (the First Buy's
        // credits included).
        uint256 firstBuyFee = _feeOnGross(1 ether);
        assertEq(handler.paidOut() + _hookClaims(), handler.creditsRecorded() + firstBuyFee);
    }

    // ------------------------------------------------ the handler's window onto the fixture

    function poolManager() external view returns (address) {
        return address(pm);
    }

    function coinBalance(address who) external view returns (uint256) {
        return _coin(key).balanceOf(who);
    }

    function quoteBalance(address who) external view returns (uint256) {
        return quote.balanceOf(who);
    }

    function hookClaims() external view returns (uint256) {
        return _hookClaims();
    }

    function allCredits() external view returns (uint256) {
        return _credit(creator) + _credit(platform);
    }

    function creatorAddr() external view returns (address) {
        return creator;
    }

    function platformAddr() external view returns (address) {
        return platform;
    }

    function seedRangeOf() external view returns (int24, int24) {
        return factory.seedRange(key.toId());
    }

    function feeOnGross(uint256 gross) external pure returns (uint256) {
        return _feeOnGross(gross);
    }

    function feeOnNet(uint256 net) external pure returns (uint256) {
        return _feeOnNet(net);
    }

    function fund(address who) external {
        if (quote.balanceOf(who) < 1_000 ether) mockQuote.mint(who, 10_000 ether);
    }

    function approveAs(address who, address spender) external {
        vm.startPrank(who);
        quote.approve(spender, type(uint256).max);
        _coin(key).approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    /// `limitTicks` zero trades to the end of the range; otherwise the price limit sits that many ticks
    /// from the pool's price, in the trade's direction.
    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks) external {
        if (limitTicks == 0) {
            _swap(key, who, buy, exactIn, amount);
            return;
        }
        _approveRouter(key, who);
        (, int24 tick,,) = pm.getSlot0(key.toId());
        bool zeroForOne = buy == _isQuote0(key);
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(zeroForOne ? tick - limitTicks : tick + limitTicks)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function payoutAs(address who, address[] memory owners) external {
        vm.prank(who);
        hook.payout(_quoteCurrency(), owners);
    }
}
