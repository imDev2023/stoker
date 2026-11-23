// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";

/// Drives trades, Payout Calls, refusals and refused liquidity changes with random actors and amounts,
/// and measures every swap from outside. The same handler runs against a coin paired with an ERC-20 and
/// one paired with the native asset (#242).
contract BooksHandler is Test {
    BooksInvariantBase internal immutable t;
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
    uint256 public refusedPayouts; // Payout Calls made while the Creator's Credit owner refused

    constructor(BooksInvariantBase t_, PoolKey memory key_) {
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
        uint256 unit = t.quoteUnit();
        if (!buy && coins < 1e9) buy = true;
        if (buy) amount = bound(amount, 1e9, exactIn ? 500 * unit : 2e10 ether);
        else amount = bound(amount, 1e9, exactIn ? coins : 20 * unit);
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
        owners[0] = seed % 2 == 0 ? t.creditOwner() : t.platformAddr();
        owners[1] = seed % 3 == 0 ? t.platformAddr() : actors[seed % actors.length];
        if (t.refusing()) refusedPayouts++;
        uint256 before = t.quoteBalance(owners[0]) + (owners[1] == owners[0] ? 0 : t.quoteBalance(owners[1]));
        t.payoutAs(actors[seed % actors.length], owners);
        uint256 after_ = t.quoteBalance(owners[0]) + (owners[1] == owners[0] ? 0 : t.quoteBalance(owners[1]));
        paidOut += after_ - before;
    }

    /// The Creator's Credit owner starts or stops refusing payment (a blocklist, a reverting contract).
    function setRefusing(bool refuse) external {
        t.setRefusing(refuse);
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
        uint256 value = t.native() ? t.quoteUnit() : 0;
        vm.prank(who);
        try lpRouter.modifyLiquidity{value: value}(key, ModifyLiquidityParams(-887_200, 887_200, 1e15, 0), "") {
            lockBreaches++;
        } catch {}
    }

    function tryDonate(uint256 actorSeed, uint256 amount) external {
        address who = actors[actorSeed % actors.length];
        t.fund(who);
        t.approveAs(who, address(donateRouter));
        amount = bound(amount, 1, 10 * t.quoteUnit());
        vm.prank(who);
        try donateRouter.donate{value: t.native() ? amount : 0}(key, amount, amount, "") {
            lockBreaches++;
        } catch {}
    }
}

/// A Credit owner that refuses the native asset while told to.
contract ToggleRecipient {
    bool public refusing;

    function setRefusing(bool refuse) external {
        refusing = refuse;
    }

    receive() external payable {
        if (refusing) revert("refusing");
    }
}

/// Invariants of the books (#241, #242): the Seed Position never falls, the Credits of every swap sum to
/// the fee the hook took, which is always 1.00% of the Quote Asset's side, the claims back every Credit,
/// and every payment was a Credit, whether or not the Creator's Credit owner refuses payment.
abstract contract BooksInvariantBase is LocalBase {
    using StateLibrary for IPoolManager;

    PoolKey internal key;
    address internal coin;
    uint128 internal seed;
    BooksHandler internal handler;
    uint256 internal firstBuy;

    function setUp() public override {
        super.setUp();
        (coin, key) = _launchForBooks();
        seed = _seedLiquidity(key);
        handler = new BooksHandler(this, key);
        targetContract(address(handler));
    }

    // ------------------------------------------------ what each Quote Asset fills in

    function _launchForBooks() internal virtual returns (address, PoolKey memory);
    function native() public view virtual returns (bool);
    function quoteUnit() public view virtual returns (uint256);
    function quoteCurrency() public view virtual returns (Currency);
    function creditOwner() public view virtual returns (address);
    function refusing() public view virtual returns (bool);
    function setRefusing(bool refuse) external virtual;
    function quoteBalance(address who) public view virtual returns (uint256);
    function fund(address who) external virtual;
    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks) external virtual;

    // ------------------------------------------------ the invariants

    /// The campaign did trade and did pay: a suite whose every swap reverted would prove nothing.
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
        assertEq(hookClaims(), hook.totalCredits(quoteCurrency()));
        assertEq(hookClaims(), allCredits());
        assertEq(quoteBalance(address(hook)), 0, "the hook holds no Quote Asset");
        assertEq(_coinToken().balanceOf(address(hook)), 0, "the hook holds no coin");
    }

    function invariant_everyPaymentWasACredit() public view {
        // What Payout Calls delivered plus what is still owed is what the swaps credited (the First Buy's
        // credits included).
        assertEq(handler.paidOut() + hookClaims(), handler.creditsRecorded() + _feeOnGross(firstBuy));
    }

    // ------------------------------------------------ the handler's window onto the fixture

    function _coinToken() internal view returns (IERC20) {
        return IERC20(coin);
    }

    function poolManager() external view returns (address) {
        return address(pm);
    }

    function coinBalance(address who) external view returns (uint256) {
        return _coinToken().balanceOf(who);
    }

    function hookClaims() public view returns (uint256) {
        return pm.balanceOf(address(hook), quoteCurrency().toId());
    }

    function allCredits() public view returns (uint256) {
        return hook.creditOf(creditOwner(), quoteCurrency()) + hook.creditOf(platform, quoteCurrency());
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

    function approveAs(address who, address spender) external {
        vm.startPrank(who);
        if (!native()) quote.approve(spender, type(uint256).max);
        _coinToken().approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    function payoutAs(address who, address[] memory owners) external {
        vm.prank(who);
        hook.payout(quoteCurrency(), owners);
    }

    /// A price limit `limitTicks` from the pool's price in the trade's direction; zero for none.
    function _limitFor(bool zeroForOne, int24 limitTicks) internal view returns (uint160) {
        if (limitTicks == 0) return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        (, int24 tick,,) = pm.getSlot0(key.toId());
        return TickMath.getSqrtPriceAtTick(zeroForOne ? tick - limitTicks : tick + limitTicks);
    }
}

/// The books of a coin paired with an ERC-20 (a mock Stock Token), its Creator blocked at times (#241).
contract BooksInvariantTest is BooksInvariantBase {
    function _launchForBooks() internal override returns (address c, PoolKey memory k) {
        firstBuy = 1 ether;
        (c, k) = _launch(true, firstBuy);
    }

    function native() public pure override returns (bool) {
        return false;
    }

    function quoteUnit() public pure override returns (uint256) {
        return 1 ether;
    }

    function quoteCurrency() public view override returns (Currency) {
        return _quoteCurrency();
    }

    function creditOwner() public view override returns (address) {
        return creator;
    }

    function refusing() public view override returns (bool) {
        return mockQuote.isBlocked(creator);
    }

    function setRefusing(bool refuse) external override {
        mockQuote.setBlocked(creator, refuse);
    }

    function quoteBalance(address who) public view override returns (uint256) {
        return quote.balanceOf(who);
    }

    function fund(address who) external override {
        if (quote.balanceOf(who) < 1_000 ether) mockQuote.mint(who, 10_000 ether);
    }

    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks) external override {
        _approveRouter(key, who);
        bool zeroForOne = buy == _isQuote0(key);
        vm.prank(who);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: _limitFor(zeroForOne, limitTicks)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

/// The books of a coin paired with the native asset, its Creator's Destination a contract that refuses
/// payment at times (#242).
contract NativeBooksInvariantTest is BooksInvariantBase {
    ToggleRecipient internal destination;

    function _launchForBooks() internal override returns (address c, PoolKey memory k) {
        _listNative();
        destination = new ToggleRecipient();
        firstBuy = 0.1 ether;
        vm.deal(creator, 1 ether);
        (c, k) = _launchNative(firstBuy, address(destination));
    }

    function native() public pure override returns (bool) {
        return true;
    }

    function quoteUnit() public pure override returns (uint256) {
        return 0.1 ether;
    }

    function quoteCurrency() public pure override returns (Currency) {
        return NATIVE;
    }

    function creditOwner() public view override returns (address) {
        return address(destination);
    }

    function refusing() public view override returns (bool) {
        return destination.refusing();
    }

    function setRefusing(bool refuse) external override {
        destination.setRefusing(refuse);
    }

    function quoteBalance(address who) public view override returns (uint256) {
        return who.balance;
    }

    function fund(address who) external override {
        if (who.balance < 1_000 ether) vm.deal(who, 10_000 ether);
    }

    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks) external override {
        vm.prank(who);
        _coinToken().approve(address(swapRouter), type(uint256).max);
        _swapNativeApproved(key, who, buy, exactIn, amount, who.balance, _limitFor(buy, limitTicks));
    }

    /// The hook holds no native asset between calls, and the test router keeps none either.
    function invariant_noNativeLeftBehind() public view {
        assertEq(address(hook).balance, 0, "the hook");
        assertEq(address(factory).balance, 0, "the factory");
        assertEq(address(swapRouter).balance, 0, "the router");
    }
}
