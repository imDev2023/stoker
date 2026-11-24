// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {MockQuote} from "../utils/MockQuote.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// Drives buys and sells in every swap type (with and without a price limit of their own, naming no
/// referrer or one at any fee up to the cap), time in steps of up to three seconds from the launches' own
/// second to well past the window, and Support Liquidity pieces by a stranger, across three Launches made
/// in one second on one hook and one vault: a standard coin paired with the mock Stock Token, a Reward
/// Launch paired with it, and a Stoke Launch paired with the native asset.
contract OpeningFeeHandler is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant B = 10_000;

    IPoolManager internal immutable pm;
    StokerHook internal immutable hook;
    TaxVault internal immutable vault;
    MockQuote internal immutable mock;
    PoolSwapTest internal immutable router;
    uint16 internal immutable feeBps;
    uint256 internal immutable startBps;
    uint256 internal immutable duration;

    PoolKey[] internal _keys;
    address[3] internal actors;
    address internal referrer = makeAddr("referrer");

    // Ghosts.
    uint256 public mismatches; // swaps whose four fees were not the rule's
    uint256 public openingOnASell; // a sell that booked an Opening Fee
    uint256 public openingAfterTheWindow; // a buy from the window's end on that booked one
    uint256 public overTheStart; // a buy whose fees together passed the start figure of its payment
    uint256 public claimMismatches; // swaps whose vault claims grew by other than the tax and the Opening Fee
    uint256 public swaps;
    uint256 public openingBuys;

    constructor(
        IPoolManager pm_,
        StokerHook hook_,
        TaxVault vault_,
        MockQuote mock_,
        PoolSwapTest router_,
        uint16 feeBps_,
        uint256 startBps_,
        uint256 duration_,
        PoolKey[] memory keys_
    ) {
        (pm, hook, vault, mock, router, feeBps, startBps, duration) =
        (pm_, hook_, vault_, mock_, router_, feeBps_, startBps_, duration_);
        for (uint256 i; i < keys_.length; i++) {
            _keys.push(keys_[i]);
        }
        actors = [makeAddr("t0"), makeAddr("t1"), makeAddr("t2")];
        for (uint256 i; i < 3; i++) {
            mock_.mint(actors[i], 1e9 ether);
            vm.deal(actors[i], 1e9 ether);
            vm.startPrank(actors[i]);
            mock_.approve(address(router_), type(uint256).max);
            for (uint256 k; k < keys_.length; k++) {
                IERC20(_coinAddr(k)).approve(address(router_), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function keyOf(uint256 i) external view returns (PoolKey memory) {
        return _keys[i];
    }

    function poolCount() external view returns (uint256) {
        return _keys.length;
    }

    function _native(uint256 k) internal view returns (bool) {
        return Currency.unwrap(_keys[k].currency0) == address(0);
    }

    function _quote0(uint256 k) internal view returns (bool) {
        return _native(k) || Currency.unwrap(_keys[k].currency0) == address(mock);
    }

    function quoteOf(uint256 k) public view returns (Currency) {
        return _quote0(k) ? _keys[k].currency0 : _keys[k].currency1;
    }

    function _coinAddr(uint256 k) internal view returns (address) {
        return Currency.unwrap(_quote0(k) ? _keys[k].currency1 : _keys[k].currency0);
    }

    function _quoteBalance(uint256 k, address who) internal view returns (uint256) {
        return _native(k) ? who.balance : mock.balanceOf(who);
    }

    function _claims(address owner, uint256 k) internal view returns (uint256) {
        return pm.balanceOf(owner, quoteOf(k).toId());
    }

    // ---------------------------------------------------------------- time and Support Liquidity

    function wait(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 3));
        vm.roll(vm.getBlockNumber() + 1);
    }

    function support(uint256 poolSeed) external {
        vm.prank(makeAddr("stranger"));
        try vault.addSupport(_keys[poolSeed % _keys.length]) {} catch {}
    }

    // ---------------------------------------------------------------- trading

    struct Before {
        uint256 q;
        uint256 hookClaims;
        uint256 tax;
        uint256 opening;
        uint256 vaultClaims;
    }

    function trade(
        uint256 poolSeed,
        uint256 actorSeed,
        bool buy,
        bool exactIn,
        uint256 amount,
        uint256 limitSeed,
        uint256 referrerBps
    ) external {
        uint256 k = poolSeed % _keys.length;
        address who = actors[actorSeed % actors.length];
        uint256 unit = _native(k) ? 0.05 ether : 1 ether;
        uint256 coins = IERC20(_coinAddr(k)).balanceOf(who);
        if (!buy && coins < 1e12) buy = true;
        if (buy) amount = bound(amount, 1e9, exactIn ? 200 * unit : 2e10 ether);
        else amount = bound(amount, exactIn ? 1e12 : 1e9, exactIn ? coins : 20 * unit);
        referrerBps = bound(referrerBps, 0, hook.termsOf(_keys[k].toId()).referrerFeeCapBps);
        int24 limitTicks = limitSeed % 3 == 0 ? int24(int256(bound(limitSeed, 1, 20))) * 200 : int24(0);

        Before memory b = Before(
            _quoteBalance(k, who),
            _claims(address(hook), k),
            hook.taxBooked(_keys[k].toId()),
            hook.openingFeeBooked(_keys[k].toId()),
            _claims(address(vault), k)
        );
        if (!_swap(k, who, buy, exactIn, amount, limitTicks, referrerBps)) return;
        swaps++;
        uint256 q1 = _quoteBalance(k, who);
        uint256 credits = _claims(address(hook), k) - b.hookClaims;
        uint256 tax = hook.taxBooked(_keys[k].toId()) - b.tax;
        uint256 opening = hook.openingFeeBooked(_keys[k].toId()) - b.opening;
        if (_claims(address(vault), k) - b.vaultClaims != tax + opening) claimMismatches++;
        if (!buy) {
            if (opening != 0) openingOnASell++;
            return;
        }
        if (opening > 0) openingBuys++;
        _checkBuy(k, b.q - q1, exactIn, referrerBps, credits, tax, opening);
    }

    /// The buy against the rule, a second plain copy.
    function _checkBuy(
        uint256 k,
        uint256 paid,
        bool exactIn,
        uint256 referrerBps,
        uint256 credits,
        uint256 tax,
        uint256 opening
    ) internal {
        StokerHook.Terms memory t = hook.termsOf(_keys[k].toId());
        uint256 elapsed = vm.getBlockTimestamp() - t.launchedAt;
        uint256 standing = feeBps + t.taxBps;
        uint256 rate = 0;
        if (elapsed < duration && startBps > standing) {
            rate = ((startBps - standing) * (duration - elapsed) + duration - 1) / duration;
        }
        // Inside the window a Referrer Fee takes only the room left under the start figure.
        if (rate > 0 && referrerBps > startBps - standing - rate) referrerBps = startBps - standing - rate;
        if (elapsed >= duration && opening != 0) openingAfterTheWindow++;
        uint256 taken = credits + tax + opening;
        if (taken * B > paid * startBps + B) overTheStart++;

        uint256 total = standing + rate + referrerBps;
        uint256 fee;
        uint256 refFee;
        uint256 expTax;
        uint256 expOpening;
        if (exactIn) {
            (fee, expTax) = (_ofGross(paid, feeBps), _ofGross(paid, t.taxBps));
            if (rate == 0) {
                refFee = _ofGross(paid, referrerBps);
            } else {
                uint256 base = _ofGross(paid, standing + rate);
                expOpening = base > fee + expTax ? base - fee - expTax : 0;
                refFee = _ofGross(paid, total) - base;
            }
        } else {
            uint256 net = paid - taken;
            (fee, expTax) = (_ofNet(net, feeBps, total), _ofNet(net, t.taxBps, total));
            if (rate == 0) {
                refFee = _ofNet(net, referrerBps, total);
            } else {
                uint256 base = _ofNet(net, standing + rate, total);
                expOpening = base > fee + expTax ? base - fee - expTax : 0;
                refFee = _ofNet(net, total, total) - base;
            }
        }
        if (credits != fee + refFee || tax != expTax || opening != expOpening) mismatches++;
    }

    function _ofGross(uint256 gross, uint256 bps) internal pure returns (uint256) {
        return (gross * bps + B - 1) / B;
    }

    function _ofNet(uint256 net, uint256 bps, uint256 total) internal pure returns (uint256) {
        return (net * bps + (B - total) - 1) / (B - total);
    }

    function _swap(
        uint256 k,
        address who,
        bool buy,
        bool exactIn,
        uint256 amount,
        int24 limitTicks,
        uint256 referrerBps
    ) internal returns (bool) {
        bool zeroForOne = buy == _quote0(k);
        uint160 limit;
        if (limitTicks == 0) {
            limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        } else {
            (, int24 tick,,) = pm.getSlot0(_keys[k].toId());
            int24 target = zeroForOne ? tick - limitTicks : tick + limitTicks;
            if (target <= TickMath.MIN_TICK || target >= TickMath.MAX_TICK) return false;
            limit = TickMath.getSqrtPriceAtTick(target);
        }
        uint256 value = _native(k) && buy ? (exactIn ? amount : who.balance / 2) : 0;
        bytes memory data = referrerBps == 0 ? bytes("") : abi.encode(referrer, referrerBps);
        vm.prank(who);
        try router.swap{value: value}(
            _keys[k],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            data
        ) {
            return true;
        } catch {
            return false;
        }
    }
}

/// The Opening Fee's invariants (#246): under random trades from the launches' own second to well past
/// the window, every buy pays exactly the rule's four fees (a rule that falls with time), the Opening Fee is
/// never paid by a sell or after the window, and the fees never pass the start figure; every wei of it reaches
/// the vault's claims and waits as its coin's Support Liquidity alone.
contract OpeningFeeInvariantTest is TaxLocalBase {
    OpeningFeeHandler internal handler;
    PoolKey[] internal launches;

    function setUp() public override {
        super.setUp();
        _tradeInOpening = true;
        launches.push(_launchKindOf(address(quote), true, StokerHook.LaunchType.Standard, 0));
        launches.push(_launchKindOf(address(quote), false, StokerHook.LaunchType.Reward, 2_500));
        launches.push(_launchKindOf(address(0), true, StokerHook.LaunchType.Liquidity, 0));
        handler = new OpeningFeeHandler(
            pm,
            hook,
            taxVault,
            mockQuote,
            swapRouter,
            PLATFORM_FEE_BPS,
            OPENING_FEE_START_BPS,
            OPENING_FEE_DURATION,
            launches
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = OpeningFeeHandler.trade.selector;
        selectors[1] = OpeningFeeHandler.trade.selector;
        selectors[2] = OpeningFeeHandler.wait.selector;
        selectors[3] = OpeningFeeHandler.support.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _launchKindOf(address q, bool quote0, StokerHook.LaunchType lt, uint16 share)
        internal
        returns (PoolKey memory key)
    {
        (, key) = _launchWith(
            _typedParams(
                q,
                quote0,
                0,
                lt,
                lt == StokerHook.LaunchType.Standard ? 0 : TAX_BPS,
                share,
                share,
                StokerHook.PayoutAsset.QuoteAsset
            )
        );
    }

    function invariant_everyBuyPaysTheRule() public view {
        assertEq(handler.mismatches(), 0, "a buy's fees were not the rule's");
        assertEq(handler.openingAfterTheWindow(), 0, "an Opening Fee after the window");
        assertEq(handler.openingOnASell(), 0, "a sell paid an Opening Fee");
        assertEq(handler.overTheStart(), 0, "the fees passed the start figure");
        assertEq(handler.claimMismatches(), 0, "the vault's claims grew by other than the tax and the Opening Fee");
    }

    /// The vault's claims in each currency are what waits: every pool's tax and Opening Fee less what its
    /// Support Liquidity spent, and Support Liquidity never spent more than its part.
    function invariant_theVaultsClaimsAreWhatWaits() public view {
        uint256 mockWaiting;
        uint256 nativeWaiting;
        for (uint256 k; k < launches.length; k++) {
            PoolKey memory key = launches[k];
            uint256 tax = hook.taxBooked(key.toId());
            uint256 opening = hook.openingFeeBooked(key.toId());
            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            StokerHook.Terms memory t = hook.termsOf(key.toId());
            assertLe(b.supportSpent, tax * t.liquidityShareBps / 10_000 + opening, "support within its part");
            uint256 waiting = tax + opening - b.supportSpent - b.burnSpent - b.holdersSpent;
            if (Currency.unwrap(key.currency0) == address(0)) nativeWaiting += waiting;
            else mockWaiting += waiting;
        }
        assertEq(pm.balanceOf(address(taxVault), _quoteCurrency().toId()), mockWaiting, "the mock's claims");
        assertEq(pm.balanceOf(address(taxVault), NATIVE.toId()), nativeWaiting, "the native claims");
    }
}
