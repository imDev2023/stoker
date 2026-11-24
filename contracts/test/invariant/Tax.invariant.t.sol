// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/src/test/PoolDonateTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TaxLocalBase} from "../utils/TaxLocalBase.sol";
import {MockQuote} from "../utils/MockQuote.sol";
import {HoldersPartStandIn} from "../utils/HoldersPartStandIn.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {TaxVault} from "../../src/TaxVault.sol";

/// Drives trades (with and without a price limit of their own), every public call of the Tax Vault by
/// random callers, time, and refused removals and donations, across three Launches on one hook and one
/// vault: a Reward Launch paired with the mock Stock Token (burn and liquidity shares, Payout Asset the
/// Quote Asset), a Stoke Launch paired with it, and a Reward Launch paired with the native asset whose
/// Payout Asset is the coin.
contract TaxHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager internal immutable pm;
    StokerHook internal immutable hook;
    TaxVault internal immutable vault;
    MockQuote internal immutable mock;
    PoolSwapTest internal immutable router;
    PoolModifyLiquidityTest internal immutable lpRouter;
    PoolDonateTest internal immutable donateRouter;
    uint16 internal immutable feeBps;

    PoolKey[] internal _keys;
    address[3] internal actors;

    struct Range {
        uint256 pool;
        int24 lower;
        int24 upper;
        uint128 added; // every liquidity the vault reported adding to this range
    }

    Range[] internal _ranges;

    // Ghosts.
    uint256 public taxMismatches; // swaps whose tax was not its rate of the Quote Asset's side
    uint256 public feeMismatches; // swaps whose Platform Fee was not its rate beside the tax
    uint256 public claimMismatches; // swaps whose vault claims grew by other than the tax booked
    uint256 public vaultTouchedInASwap; // swaps after which the vault's books had moved
    uint256 public lockBreaches; // a removal or a donation that went through
    uint256 public swaps;
    uint256 public pieces; // public calls that went through
    mapping(uint256 => uint256) public passedToDistributor; // by pool, in what was deposited

    constructor(
        IPoolManager pm_,
        StokerHook hook_,
        TaxVault vault_,
        MockQuote mock_,
        PoolSwapTest router_,
        uint16 feeBps_,
        PoolKey[] memory keys_
    ) {
        pm = pm_;
        hook = hook_;
        vault = vault_;
        mock = mock_;
        router = router_;
        feeBps = feeBps_;
        lpRouter = new PoolModifyLiquidityTest(pm_);
        donateRouter = new PoolDonateTest(pm_);
        for (uint256 i; i < keys_.length; i++) {
            _keys.push(keys_[i]);
        }
        actors = [makeAddr("t0"), makeAddr("t1"), makeAddr("t2")];
        for (uint256 i; i < 3; i++) {
            mock_.mint(actors[i], 1e9 ether);
            vm.deal(actors[i], 1e9 ether);
            vm.startPrank(actors[i]);
            mock_.approve(address(router_), type(uint256).max);
            mock_.approve(address(lpRouter), type(uint256).max);
            mock_.approve(address(donateRouter), type(uint256).max);
            for (uint256 k; k < keys_.length; k++) {
                IERC20(_coinAddr(k)).approve(address(router_), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- reading

    function keyOf(uint256 i) public view returns (PoolKey memory) {
        return _keys[i];
    }

    function poolCount() external view returns (uint256) {
        return _keys.length;
    }

    function rangeCount() external view returns (uint256) {
        return _ranges.length;
    }

    function rangeOf(uint256 i) external view returns (Range memory) {
        return _ranges[i];
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

    // ---------------------------------------------------------------- trading

    function trade(uint256 poolSeed, uint256 actorSeed, bool buy, bool exactIn, uint256 amount, uint256 limitSeed)
        external
    {
        uint256 k = poolSeed % _keys.length;
        address who = actors[actorSeed % actors.length];
        uint256 unit = _native(k) ? 0.05 ether : 1 ether;
        uint256 coins = IERC20(_coinAddr(k)).balanceOf(who);
        if (!buy && coins < 1e12) buy = true;
        if (buy) amount = bound(amount, 1e9, exactIn ? 200 * unit : 2e10 ether);
        else amount = bound(amount, exactIn ? 1e12 : 1e9, exactIn ? coins : 20 * unit);
        int24 limitTicks = limitSeed % 3 == 0 ? int24(int256(bound(limitSeed, 1, 20))) * 200 : int24(0);

        uint256 q0 = _quoteBalance(k, who);
        uint256 fee0 = _claims(address(hook), k);
        uint256 tax0 = hook.taxBooked(_keys[k].toId());
        uint256 vault0 = _claims(address(vault), k);
        TaxVault.Books memory books0 = vault.booksOf(_keys[k].toId());
        if (!_swap(k, who, buy, exactIn, amount, limitTicks)) return;
        swaps++;
        uint256 q1 = _quoteBalance(k, who);
        uint256 fee = _claims(address(hook), k) - fee0;
        uint256 tax = hook.taxBooked(_keys[k].toId()) - tax0;
        if (_claims(address(vault), k) - vault0 != tax) claimMismatches++;
        TaxVault.Books memory books1 = vault.booksOf(_keys[k].toId());
        if (keccak256(abi.encode(books0)) != keccak256(abi.encode(books1))) vaultTouchedInASwap++;

        uint256 taxBps = hook.termsOf(_keys[k].toId()).taxBps;
        uint256 total = feeBps + taxBps;
        uint256 expFee;
        uint256 expTax;
        if (buy && exactIn) {
            (expFee, expTax) = (_ofGross(q0 - q1, feeBps), _ofGross(q0 - q1, taxBps));
        } else if (buy) {
            uint256 net = q0 - q1 - fee - tax;
            (expFee, expTax) = (_ofNet(net, feeBps, total), _ofNet(net, taxBps, total));
        } else if (exactIn) {
            uint256 gross = q1 - q0 + fee + tax;
            (expFee, expTax) = (_ofGross(gross, feeBps), _ofGross(gross, taxBps));
        } else {
            (expFee, expTax) = (_ofNet(q1 - q0, feeBps, total), _ofNet(q1 - q0, taxBps, total));
        }
        if (tax != expTax) taxMismatches++;
        if (fee != expFee) feeMismatches++;
    }

    function _swap(uint256 k, address who, bool buy, bool exactIn, uint256 amount, int24 limitTicks)
        internal
        returns (bool)
    {
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
        uint256 value = _native(k) && buy ? (exactIn ? amount : 1_000 ether) : 0;
        vm.prank(who);
        try router.swap{value: value}(
            _keys[k],
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: exactIn ? -int256(amount) : int256(amount),
                sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _ofGross(uint256 gross, uint256 bps) internal pure returns (uint256) {
        return (gross * bps + 9_999) / 10_000;
    }

    function _ofNet(uint256 net, uint256 bps, uint256 total) internal pure returns (uint256) {
        return (net * bps + (10_000 - total) - 1) / (10_000 - total);
    }

    // ---------------------------------------------------------------- the vault's public calls

    function addSupport(uint256 poolSeed, uint256 callerSeed) external {
        uint256 k = poolSeed % _keys.length;
        vm.recordLogs();
        vm.prank(actors[callerSeed % actors.length]);
        try vault.addSupport(_keys[k]) returns (uint256, uint128 liquidity) {
            pieces++;
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].emitter == address(vault) && logs[i].topics[0] == TaxVault.SupportAdded.selector) {
                    (int24 lower, int24 upper,,) = abi.decode(logs[i].data, (int24, int24, uint128, uint256));
                    _record(k, lower, upper, liquidity);
                }
            }
        } catch {}
    }

    function _record(uint256 k, int24 lower, int24 upper, uint128 liquidity) internal {
        for (uint256 i; i < _ranges.length; i++) {
            Range storage r = _ranges[i];
            if (r.pool == k && r.lower == lower && r.upper == upper) {
                r.added += liquidity;
                return;
            }
        }
        _ranges.push(Range(k, lower, upper, liquidity));
    }

    function burn(uint256 poolSeed, uint256 callerSeed) external {
        vm.prank(actors[callerSeed % actors.length]);
        try vault.burn(_keys[poolSeed % _keys.length]) {
            pieces++;
        } catch {}
    }

    function buyForHolders(uint256 poolSeed, uint256 callerSeed) external {
        vm.prank(actors[callerSeed % actors.length]);
        try vault.buyForHolders(_keys[poolSeed % _keys.length]) {
            pieces++;
        } catch {}
    }

    function passHoldersPart(uint256 poolSeed, uint256 callerSeed) external {
        uint256 k = poolSeed % _keys.length;
        vm.prank(actors[callerSeed % actors.length]);
        try vault.passHoldersPart(_keys[k]) returns (Currency, uint256 amount) {
            pieces++;
            passedToDistributor[k] += amount;
        } catch {}
    }

    function wait(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 300));
    }

    // ---------------------------------------------------------------- what must be refused

    function tryRemoveSupport(uint256 rangeSeed, uint256 actorSeed) external {
        if (_ranges.length == 0) return;
        Range memory r = _ranges[rangeSeed % _ranges.length];
        vm.prank(actors[actorSeed % actors.length]);
        try lpRouter.modifyLiquidity(_keys[r.pool], ModifyLiquidityParams(r.lower, r.upper, -1, 0), "") {
            lockBreaches++;
        } catch {}
    }

    function tryDonate(uint256 poolSeed, uint256 actorSeed) external {
        uint256 k = poolSeed % _keys.length;
        if (_native(k)) return;
        bool q0 = _quote0(k);
        vm.prank(actors[actorSeed % actors.length]);
        try donateRouter.donate(_keys[k], q0 ? 1 ether : 0, q0 ? 0 : 1 ether, "") {
            lockBreaches++;
        } catch {}
    }
}

contract TaxInvariantTest is TaxLocalBase {
    using StateLibrary for IPoolManager;

    TaxHandler internal handler;

    function setUp() public override {
        super.setUp();
        PoolKey[] memory keys = new PoolKey[](3);
        keys[0] = _launchReward(true, 2_500, 2_500, StokerHook.PayoutAsset.QuoteAsset);
        keys[1] = _launchStoke(false, 500);
        keys[2] = _launchNativeTyped(StokerHook.LaunchType.Reward, 1_000, 0, StokerHook.PayoutAsset.Coin);
        handler = new TaxHandler(pm, hook, taxVault, mockQuote, swapRouter, PLATFORM_FEE_BPS, keys);
        targetContract(address(handler));
    }

    /// The Tax Vault never spends more than a coin's own tax on that coin, and each path no more than its
    /// own part: so the holders' part is never spent by the burn or the liquidity path.
    function invariant_eachPathSpendsOnlyItsOwnPartOfItsOwnCoin() public view {
        for (uint256 k; k < handler.poolCount(); k++) {
            PoolKey memory key = handler.keyOf(k);
            StokerHook.Terms memory t = hook.termsOf(key.toId());
            uint256 booked = hook.taxBooked(key.toId());
            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            uint256 holdersShare =
                t.launchType == StokerHook.LaunchType.Reward ? 10_000 - t.burnShareBps - t.liquidityShareBps : 0;
            assertLe(b.burnSpent, booked * t.burnShareBps / 10_000, "the burn within its share");
            assertLe(b.supportSpent, booked * t.liquidityShareBps / 10_000, "the liquidity within its share");
            assertLe(b.holdersSpent, booked * holdersShare / 10_000, "the holders within their part");
            assertLe(b.burnSpent + b.supportSpent + b.holdersSpent, booked, "never more than the coin's own tax");
        }
    }

    /// The vault's claims are exactly every coin's tax less what was spent: nothing goes missing and
    /// nothing is spent twice.
    function invariant_claimsAreTheUnspentTax() public view {
        uint256 mockUnspent;
        uint256 nativeUnspent;
        for (uint256 k; k < handler.poolCount(); k++) {
            PoolKey memory key = handler.keyOf(k);
            TaxVault.Books memory b = taxVault.booksOf(key.toId());
            uint256 unspent = hook.taxBooked(key.toId()) - b.burnSpent - b.supportSpent - b.holdersSpent;
            if (Currency.unwrap(handler.quoteOf(k)) == address(0)) nativeUnspent += unspent;
            else mockUnspent += unspent;
        }
        assertEq(pm.balanceOf(address(taxVault), Currency.wrap(address(mockQuote)).toId()), mockUnspent);
        assertEq(pm.balanceOf(address(taxVault), 0), nativeUnspent);
    }

    /// Support Liquidity never leaves the pool: every range holds at least every liquidity added to it.
    function invariant_supportNeverLeaves() public view {
        for (uint256 i; i < handler.rangeCount(); i++) {
            TaxHandler.Range memory r = handler.rangeOf(i);
            PoolKey memory key = handler.keyOf(r.pool);
            uint128 liquidity = pm.getPositionLiquidity(
                key.toId(), Position.calculatePositionKey(address(taxVault), r.lower, r.upper, bytes32(0))
            );
            assertEq(liquidity, r.added, "the position holds every liquidity added to it");
        }
        assertEq(handler.lockBreaches(), 0, "no removal or donation went through");
    }

    /// The vault holds no Quote Asset of its own between calls, and exactly the coins bought for holders.
    function invariant_vaultHoldsOnlyTheHoldersCoins() public view {
        assertEq(address(taxVault).balance, 0, "no native asset");
        assertEq(mockQuote.balanceOf(address(taxVault)), 0, "no Quote Asset");
        for (uint256 k; k < handler.poolCount(); k++) {
            PoolKey memory key = handler.keyOf(k);
            address coin = Currency.unwrap(
                Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency0) == address(mockQuote)
                    ? key.currency1
                    : key.currency0
            );
            assertEq(IERC20(coin).balanceOf(address(taxVault)), taxVault.booksOf(key.toId()).holdersCoins);
            assertEq(
                holdersPart.deposited(coin, handler.quoteOf(k))
                    + holdersPart.deposited(coin, Currency.wrap(coin)),
                handler.passedToDistributor(k),
                "the Distributor received exactly what was passed"
            );
        }
    }

    /// Every swap moved exactly its tax to the vault's books and nothing else touched them.
    function invariant_everySwapBooksExactlyItsTax() public view {
        assertEq(handler.taxMismatches(), 0, "the tax is its rate of the Quote Asset's side");
        assertEq(handler.feeMismatches(), 0, "the Platform Fee is its rate beside it");
        assertEq(handler.claimMismatches(), 0, "the vault's claims grew by the tax booked");
        assertEq(handler.vaultTouchedInASwap(), 0, "no swap moved the vault's books");
    }

    /// Each run must have traded and made public calls, or the properties above prove nothing.
    function afterInvariant() external {
        assertGt(handler.swaps(), 0, "the campaign traded");
        assertGt(handler.pieces(), 0, "the campaign spent tax");
        emit log_named_uint("swaps", handler.swaps());
        emit log_named_uint("public calls that went through", handler.pieces());
        emit log_named_uint("support ranges", handler.rangeCount());
    }
}
