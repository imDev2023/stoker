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
import {StokerKeys} from "../../src/StokerKeys.sol";

/// Drives trades (naming a referrer or not), Payout Calls, refusals, refused liquidity changes, and every
/// call the Admin and the server keys can make, with random actors and amounts, and measures every swap
/// from outside. The same handler runs against a coin paired with an ERC-20 and one paired with the native
/// asset (#242).
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
    uint256 public ownPulls; // Payout Calls the Creator's Credit owner made for themselves
    uint256 public referredSwaps; // swaps that named a referrer and a fee
    uint256 public referrerCredits; // what the referrers' Credits grew by on swaps
    uint256 public privilegedCalls; // calls by the Admin or a server key that went through
    uint256 public privilegedChanges; // such calls after which a pool, a Seed Position or a Credit differed

    constructor(BooksInvariantBase t_, PoolKey memory key_) {
        t = t_;
        key = key_;
        actors = [makeAddr("a0"), makeAddr("a1"), makeAddr("a2"), makeAddr("a3")];
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(t.poolManager()));
        donateRouter = new PoolDonateTest(IPoolManager(t.poolManager()));
    }

    /// A trade; `refSeed` names no referrer, the ordinary one or the one that refuses payment, with a fee
    /// from zero to the cap.
    function trade(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, uint256 refSeed) external {
        _trade(actorSeed, buy, exactIn, amount, 0, refSeed);
    }

    /// A trade naming no referrer: the path every swap took before #243 stays well exercised.
    function tradePlain(uint256 actorSeed, bool buy, bool exactIn, uint256 amount) external {
        _trade(actorSeed, buy, exactIn, amount, 0, 0);
    }

    /// A trade always naming a referrer, the ordinary one or the hostile one, with a fee from 1 to the cap.
    function tradeReferred(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, bool hostile, uint256 feeSeed)
        external
    {
        uint256 feeBps = 1 + feeSeed % t.referrerCapBps();
        _trade(actorSeed, buy, exactIn, amount, 0, (feeBps << 8) | (hostile ? 2 : 1));
    }

    /// The same trade with a price limit of its own a few tick spacings away, which stops many of them
    /// early: those with the Quote Asset as the specified side are refused, the others pay on what moved.
    function tradeWithLimit(
        uint256 actorSeed,
        bool buy,
        bool exactIn,
        uint256 amount,
        uint256 spacings,
        uint256 refSeed
    ) external {
        _trade(actorSeed, buy, exactIn, amount, int24(int256(bound(spacings, 1, 20))) * 200, refSeed);
    }

    function _trade(uint256 actorSeed, bool buy, bool exactIn, uint256 amount, int24 limitTicks, uint256 refSeed)
        internal
    {
        address who = actors[actorSeed % actors.length];
        uint256 coins = t.coinBalance(who);
        uint256 unit = t.quoteUnit();
        if (!buy && coins < 1e9) buy = true;
        if (buy) amount = bound(amount, 1e9, exactIn ? 500 * unit : 2e10 ether);
        else amount = bound(amount, 1e9, exactIn ? coins : 20 * unit);
        t.fund(who);

        (address referrer, uint256 refBps) = t.referralFor(refSeed);
        bytes memory hookData = referrer == address(0) ? bytes("") : abi.encode(referrer, refBps);

        uint256 q0 = t.quoteBalance(who);
        uint256 claims0 = t.hookClaims();
        uint256 credits0 = t.allCredits();
        uint256 ref0 = referrer == address(0) ? 0 : t.creditOf(referrer);
        try t.swapAs(who, buy, exactIn, amount, limitTicks, hookData) {}
        catch {
            // A sell asking for more than the pool can give or the actor holds, a swap with the Quote
            // Asset specified that its limit stopped early, or a sell too small to pay both fees.
            return;
        }
        uint256 q1 = t.quoteBalance(who);
        uint256 taken = t.hookClaims() - claims0;
        uint256 rf = referrer == address(0) ? 0 : t.creditOf(referrer) - ref0;
        feesTaken += taken;
        creditsRecorded += t.allCredits() - credits0;
        referrerCredits += rf;
        swaps++;
        if (limitTicks != 0) limitedSwaps++;
        if (referrer != address(0)) referredSwaps++;

        // Both fees are their rates of the Quote Asset's side; with no referrer the Platform Fee alone,
        // exactly as before #243.
        uint256 pf;
        uint256 expectedRf;
        if (buy && exactIn) {
            (pf, expectedRf) = (t.feeOnGrossAt(q0 - q1, t.platformBps()), t.feeOnGrossAt(q0 - q1, refBps));
        } else if (buy) {
            (pf, expectedRf) =
            (t.feeOnNetAt(q0 - q1 - taken, t.platformBps(), refBps), t.feeOnNetAt(q0 - q1 - taken, refBps, refBps));
        } else if (exactIn) {
            (pf, expectedRf) =
            (t.feeOnGrossAt(q1 - q0 + taken, t.platformBps()), t.feeOnGrossAt(q1 - q0 + taken, refBps));
        } else {
            (pf, expectedRf) = (t.feeOnNetAt(q1 - q0, t.platformBps(), refBps), t.feeOnNetAt(q1 - q0, refBps, refBps));
        }
        if (taken != pf + expectedRf || rf != expectedRf) feeFormulaMismatches++;
    }

    /// A stranger's Payout Call for two of the Credit owners (the Creator's, an Admin of any moment, a
    /// referrer), or one of them twice.
    function payout(uint256 seed) external {
        address[] memory all = t.owners();
        address[] memory owners = new address[](2);
        owners[0] = all[seed % all.length];
        owners[1] = all[(seed >> 8) % all.length];
        if (t.refusing()) refusedPayouts++;
        uint256 before = t.quoteBalance(owners[0]) + (owners[1] == owners[0] ? 0 : t.quoteBalance(owners[1]));
        t.payoutAs(actors[seed % actors.length], owners);
        uint256 after_ = t.quoteBalance(owners[0]) + (owners[1] == owners[0] ? 0 : t.quoteBalance(owners[1]));
        paidOut += after_ - before;
    }

    /// The Creator's Credit owner pulls their own, the platform's beside it. In the native asset that is
    /// the payment that forwards all the caller's gas, the other being capped.
    function pullOwn() external {
        address[] memory owners = new address[](2);
        owners[0] = t.creditOwner();
        owners[1] = t.currentAdmin();
        if (t.refusing()) refusedPayouts++;
        uint256 before = t.quoteBalance(owners[0]) + t.quoteBalance(owners[1]);
        t.payoutAs(owners[0], owners);
        paidOut += t.quoteBalance(owners[0]) + t.quoteBalance(owners[1]) - before;
        ownPulls++;
    }

    /// The Creator's Credit owner starts or stops refusing payment (a blocklist, a reverting contract).
    function setRefusing(bool refuse) external {
        t.setRefusing(refuse);
    }

    /// The hostile referrer starts or stops refusing payment.
    function setReferrerRefusing(bool refuse) external {
        t.setReferrerRefusing(refuse);
    }

    // ------------------------------------------------ the Admin and the server keys (#243)

    /// A write to the Quote Registry by the Admin of the moment, after some time has passed: a routine
    /// price write, a scheduled change, its withdrawal, a delisting, or a new Listing. Writes the registry
    /// refuses (too soon, too far, a change waiting) are simply refused.
    function adminWrite(uint256 op, uint256 tickSeed, uint256 waitSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(waitSeed, 0, 3 days));
        bytes memory data = t.registryCall(op, tickSeed);
        _privileged(t.currentAdmin(), address(t.registryAddr()), data);
    }

    /// The Admin hands over to another of the pool's addresses, which accepts; or proposes and is left.
    function handOverAdmin(uint256 seed, bool accept) external {
        address next = t.adminCandidate(seed);
        _privileged(t.currentAdmin(), t.keysAddr(), abi.encodeCall(StokerKeys.proposeAdmin, (next)));
        if (accept) _privileged(next, t.keysAddr(), abi.encodeCall(StokerKeys.acceptAdmin, ()));
    }

    /// The Admin replaces or revokes a server key, the new holder accepting.
    function replaceKey(uint256 roleSeed, uint256 holderSeed, bool revoke) external {
        StokerKeys.Role role = StokerKeys.Role(roleSeed % 3);
        if (revoke) {
            _privileged(t.currentAdmin(), t.keysAddr(), abi.encodeCall(StokerKeys.revokeKey, (role)));
            return;
        }
        address holder = actors[holderSeed % actors.length];
        _privileged(t.currentAdmin(), t.keysAddr(), abi.encodeCall(StokerKeys.proposeKey, (role, holder)));
        _privileged(holder, t.keysAddr(), abi.encodeCall(StokerKeys.acceptKey, (role)));
    }

    /// A server key's holder tries every privileged call there is; none is theirs, and none goes through.
    function serverKeyTries(uint256 roleSeed, uint256 op, uint256 tickSeed) external {
        address holder = t.holderOf(StokerKeys.Role(roleSeed % 3));
        if (holder == address(0)) return;
        _privileged(holder, address(t.registryAddr()), t.registryCall(op, tickSeed));
        _privileged(holder, t.keysAddr(), abi.encodeCall(StokerKeys.proposeAdmin, (holder)));
        _privileged(holder, t.keysAddr(), abi.encodeCall(StokerKeys.revokeKey, (StokerKeys.Role(op % 3))));
    }

    /// Makes a privileged call and records whether it went through and whether anything it must not touch
    /// moved: the pool's price and liquidity, the Seed Position, any Credit, the claims behind them, or the
    /// launched coin's terms.
    function _privileged(address who, address target, bytes memory data) internal {
        bytes32 before = t.fingerprint();
        vm.prank(who);
        (bool ok,) = target.call(data);
        if (ok) privilegedCalls++;
        if (t.fingerprint() != before) privilegedChanges++;
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

/// A Credit owner that refuses the native asset while told to: a Creator's Destination, or a referrer.
contract ToggleRecipient {
    bool public refusing;

    function setRefusing(bool refuse) external {
        refusing = refuse;
    }

    receive() external payable {
        if (refusing) revert("refusing");
    }
}

/// Invariants of the books (#241, #242, #243): the Seed Position never falls, the Credits of every swap
/// sum to what the hook took, which is always 1.00% of the Quote Asset's side plus the Referrer Fee the
/// trade named, the claims back every Credit, every payment was a Credit, whether or not the Creator's
/// Credit owner or a referrer refuses payment, and no call by the Admin or a server key changes the pool,
/// its Seed Position or anyone's Credit.
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
    function setReferrerRefusing(bool refuse) external virtual;
    function hostileReferrer() public view virtual returns (address);
    function quoteBalance(address who) public view virtual returns (uint256);
    function fund(address who) external virtual;
    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks, bytes memory hookData)
        external
        virtual;

    // ------------------------------------------------ the Credit owners

    address internal referrerA = makeAddr("referrerA");
    address[2] internal nextAdmins = [makeAddr("admin1"), makeAddr("admin2")];

    /// Every address a Credit can be booked to in the campaign: the Creator's, each Admin it may have, and
    /// the two referrers.
    function owners() public view returns (address[] memory o) {
        o = new address[](6);
        (o[0], o[1], o[2], o[3]) = (creditOwner(), platform, nextAdmins[0], nextAdmins[1]);
        (o[4], o[5]) = (referrerA, hostileReferrer());
    }

    /// No referrer, the ordinary one or the hostile one, with a fee from zero to the cap.
    function referralFor(uint256 refSeed) external view returns (address referrer, uint256 feeBps) {
        uint256 which = refSeed % 3;
        if (which == 0) return (address(0), 0);
        referrer = which == 1 ? referrerA : hostileReferrer();
        feeBps = (refSeed >> 8) % (REFERRER_FEE_CAP_BPS + 1);
        if (feeBps == 0) referrer = address(0);
    }

    function creditOf(address owner) external view returns (uint256) {
        return hook.creditOf(owner, quoteCurrency());
    }

    // ------------------------------------------------ the invariants

    /// The campaign did trade and did pay: a suite whose every swap reverted would prove nothing.
    function afterInvariant() public view {
        assertGt(handler.swaps(), 0, "no swap went through");
    }

    /// No call by the Admin or a server key changes the launched coin's pool, its Seed Position or anyone's
    /// Credit (#243).
    function invariant_noPrivilegedCallTouchesAPoolASeedOrACredit() public view {
        assertEq(handler.privilegedChanges(), 0, "a privileged call moved a pool, a seed or a Credit");
    }

    function invariant_seedLiquidityNeverFalls() public view {
        assertEq(_seedLiquidity(key), seed);
        assertEq(handler.lockBreaches(), 0, "a removal, foreign add or donation went through");
    }

    function invariant_creditsOfEverySwapSumToTheFeeTaken() public view {
        assertEq(handler.creditsRecorded(), handler.feesTaken());
        assertEq(handler.feeFormulaMismatches(), 0, "a fee that was not its rate of the Quote Asset's side");
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

    function allCredits() public view returns (uint256 sum) {
        address[] memory o = owners();
        for (uint256 i; i < o.length; i++) {
            sum += hook.creditOf(o[i], quoteCurrency());
        }
    }

    function referrerCapBps() external pure returns (uint256) {
        return REFERRER_FEE_CAP_BPS;
    }

    function platformBps() external pure returns (uint256) {
        return PLATFORM_FEE_BPS;
    }

    /// A rate of a gross amount, rounded up.
    function feeOnGrossAt(uint256 gross, uint256 feeBps) external pure returns (uint256) {
        return _feeOnGrossAt(gross, feeBps);
    }

    /// A rate of a gross known as its net, the Platform Fee and a Referrer Fee of `refBps` taken from it.
    function feeOnNetAt(uint256 net, uint256 feeBps, uint256 refBps) external pure returns (uint256) {
        return _feeOnNetWith(net, feeBps, PLATFORM_FEE_BPS + refBps);
    }

    // ------------------------------------------------ the Admin and the server keys

    function currentAdmin() external view returns (address) {
        return keys.admin();
    }

    function adminCandidate(uint256 pick) external view returns (address) {
        uint256 i = pick % 3;
        return i == 2 ? platform : nextAdmins[i];
    }

    function keysAddr() external view returns (address) {
        return address(keys);
    }

    function registryAddr() external view returns (address) {
        return address(registry);
    }

    function holderOf(StokerKeys.Role role) external view returns (address) {
        return keys.holderOf(role);
    }

    /// One of the registry's writes, on the campaign's own Quote Asset or a new one, with figures that are
    /// often inside its bounds and sometimes not.
    function registryCall(uint256 op, uint256 tickSeed) external view returns (bytes memory) {
        address asset = native() ? address(0) : address(quote);
        int24 current = registry.listingOf(asset).startTick;
        int24 tick = current + (int24(int256(tickSeed % 31)) - 15) * TICK_SPACING;
        uint16 multiple = uint16(2 + (tickSeed >> 8) % 60);
        uint16 cap = uint16((tickSeed >> 16) % 300);
        uint256 which = op % 5;
        if (which == 0) return abi.encodeCall(registry.writeStartPrice, (asset, tick));
        if (which == 1) return abi.encodeCall(registry.scheduleChange, (asset, tick, multiple, cap));
        if (which == 2) return abi.encodeCall(registry.withdrawChange, (asset));
        if (which == 3) return abi.encodeCall(registry.delist, (asset));
        return abi.encodeCall(registry.list, (address(uint160(0x5000 + op % 7)), tick, multiple, cap));
    }

    /// Everything no privileged call may move: the pool's price and liquidity, the Seed Position, every
    /// Credit, the claims behind them and the launched coin's terms.
    function fingerprint() external view returns (bytes32) {
        (uint160 sqrtPrice, int24 tick,,) = pm.getSlot0(key.toId());
        bytes memory credits;
        address[] memory o = owners();
        for (uint256 i; i < o.length; i++) {
            credits = abi.encodePacked(credits, hook.creditOf(o[i], quoteCurrency()));
        }
        return keccak256(
            abi.encode(
                sqrtPrice,
                tick,
                pm.getLiquidity(key.toId()),
                _seedLiquidity(key),
                credits,
                hookClaims(),
                hook.totalCredits(quoteCurrency()),
                hook.termsOf(key.toId())
            )
        );
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

    function payoutAs(address who, address[] memory payees) external {
        vm.prank(who);
        hook.payout(quoteCurrency(), payees);
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

    /// The hostile referrer of a Stock Token: an address the issuer blocks at times.
    address internal blockedReferrer = makeAddr("blockedReferrer");

    function hostileReferrer() public view override returns (address) {
        return blockedReferrer;
    }

    function setReferrerRefusing(bool refuse) external override {
        mockQuote.setBlocked(blockedReferrer, refuse);
    }

    function quoteBalance(address who) public view override returns (uint256) {
        return quote.balanceOf(who);
    }

    function fund(address who) external override {
        if (quote.balanceOf(who) < 1_000 ether) mockQuote.mint(who, 10_000 ether);
    }

    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks, bytes memory hookData)
        external
        override
    {
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
            hookData
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

    /// The hostile referrer of the native asset: a contract that refuses payment at times.
    ToggleRecipient internal toggleReferrer = new ToggleRecipient();

    function hostileReferrer() public view override returns (address) {
        return address(toggleReferrer);
    }

    function setReferrerRefusing(bool refuse) external override {
        toggleReferrer.setRefusing(refuse);
    }

    function quoteBalance(address who) public view override returns (uint256) {
        return who.balance;
    }

    function fund(address who) external override {
        if (who.balance < 1_000 ether) vm.deal(who, 10_000 ether);
    }

    function swapAs(address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks, bytes memory hookData)
        external
        override
    {
        vm.prank(who);
        _coinToken().approve(address(swapRouter), type(uint256).max);
        _swapNativeWithData(key, who, buy, exactIn, amount, who.balance, _limitFor(buy, limitTicks), hookData);
    }

    /// The hook holds no native asset between calls, and the test router keeps none either.
    function invariant_noNativeLeftBehind() public view {
        assertEq(address(hook).balance, 0, "the hook");
        assertEq(address(factory).balance, 0, "the factory");
        assertEq(address(swapRouter).balance, 0, "the router");
    }
}
