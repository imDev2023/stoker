// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LocalBase} from "../utils/LocalBase.sol";
import {StokerHook} from "../../src/StokerHook.sol";
import {
    RevertingRecipient,
    GasBurningRecipient,
    ReturnBombRecipient,
    ReentrantPayoutRecipient,
    ReentrantSwapRecipient
} from "../utils/Recipients.sol";

/// What the Referrer Fee tests share: one swap measured from outside, with or without a referrer named,
/// in a coin paired with an ERC-20 or with the native asset.
abstract contract ReferrerBase is LocalBase {
    using StateLibrary for IPoolManager;

    address internal referrer = makeAddr("referrer");

    /// What one swap did, measured from outside.
    struct Seen {
        uint256 quoteIn; // Quote Asset the trader paid (buys)
        uint256 quoteOut; // Quote Asset the trader received (sells)
        uint256 taken; // what the hook's claims grew by: every fee of the swap
        uint256 creatorCredit;
        uint256 platformCredit;
        uint256 referrerCredit;
    }

    function setUp() public virtual override {
        super.setUp();
        _listNative();
        vm.deal(creator, 10 ether);
        vm.deal(trader, 1_000 ether);
    }

    function _native(PoolKey memory key) internal pure returns (bool) {
        return Currency.unwrap(key.currency0) == address(0);
    }

    function _q(PoolKey memory key) internal view returns (Currency) {
        return _native(key) ? NATIVE : _quoteCurrency();
    }

    function _bal(PoolKey memory key, address who) internal view returns (uint256) {
        return _native(key) ? who.balance : quote.balanceOf(who);
    }

    function _claims(PoolKey memory key) internal view returns (uint256) {
        return pm.balanceOf(address(hook), _q(key).toId());
    }

    function _cred(PoolKey memory key, address owner) internal view returns (uint256) {
        return hook.creditOf(owner, _q(key));
    }

    function _defaultLimit(PoolKey memory key, bool buy) internal view returns (uint160) {
        bool zeroForOne = _native(key) ? buy : buy == _isQuote0(key);
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// The swap alone, one external call, approved beforehand.
    function _trade(PoolKey memory key, bool buy, bool exactIn, uint256 amount, uint160 limit, bytes memory hookData)
        internal
    {
        if (_native(key)) _swapNativeWithData(key, trader, buy, exactIn, amount, 100 ether, limit, hookData);
        else _swapWithData(key, trader, buy, exactIn, amount, limit, hookData);
    }

    function _approveAll(PoolKey memory key) internal {
        vm.startPrank(trader);
        IERC20(Currency.unwrap(_native(key) ? key.currency1 : (_isQuote0(key) ? key.currency1 : key.currency0)))
            .approve(address(swapRouter), type(uint256).max);
        quote.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _see(PoolKey memory key, bool buy, bool exactIn, uint256 amount, bytes memory hookData)
        internal
        returns (Seen memory s)
    {
        _approveAll(key);
        address destination = hook.termsOf(key.toId()).creatorDestination;
        uint256 q0 = _bal(key, trader);
        uint256 h0 = _claims(key);
        uint256 c0 = _cred(key, destination);
        uint256 p0 = _cred(key, platform);
        uint256 r0 = _cred(key, referrer);
        uint256 rb0 = _bal(key, referrer);
        _trade(key, buy, exactIn, amount, _defaultLimit(key, buy), hookData);
        uint256 q1 = _bal(key, trader);
        if (q0 > q1) s.quoteIn = q0 - q1;
        else s.quoteOut = q1 - q0;
        s.taken = _claims(key) - h0;
        s.creatorCredit = _cred(key, destination) - c0;
        s.platformCredit = _cred(key, platform) - p0;
        s.referrerCredit = _cred(key, referrer) - r0;
        assertEq(_bal(key, referrer), rb0, "nothing is paid to the referrer inside the swap");
        assertEq(s.creatorCredit + s.platformCredit + s.referrerCredit, s.taken, "the Credits sum to what was taken");
    }

    /// The Platform Fee and the Referrer Fee a swap should take at `refBps`, from what the trader saw: both
    /// are their rates of the Quote Asset's side (what the trader pays on a buy, what the pool pays out on a
    /// sell), each rounded up.
    function _expected(bool buy, bool exactIn, Seen memory s, uint256 refBps, uint256 specified)
        internal
        pure
        returns (uint256 platformFee, uint256 referrerFee)
    {
        uint256 total = PLATFORM_FEE_BPS + refBps;
        if (buy && exactIn) {
            (platformFee, referrerFee) = (_feeOnGrossAt(s.quoteIn, PLATFORM_FEE_BPS), _feeOnGrossAt(s.quoteIn, refBps));
        } else if (buy) {
            uint256 net = s.quoteIn - s.taken;
            (platformFee, referrerFee) =
            (_feeOnNetWith(net, PLATFORM_FEE_BPS, total), _feeOnNetWith(net, refBps, total));
        } else if (exactIn) {
            uint256 gross = s.quoteOut + s.taken;
            (platformFee, referrerFee) = (_feeOnGrossAt(gross, PLATFORM_FEE_BPS), _feeOnGrossAt(gross, refBps));
        } else {
            (platformFee, referrerFee) =
            (_feeOnNetWith(specified, PLATFORM_FEE_BPS, total), _feeOnNetWith(specified, refBps, total));
        }
    }

    /// The hook's revert from `beforeSwap`, as the PoolManager wraps it.
    function _wrappedBefore(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _wrappedAfter(bytes memory reason) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.afterSwap.selector,
            reason,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// A price limit `ticks` away from the pool's price, in the direction the trade moves it.
    function _limitAway(PoolKey memory key, bool buy, int24 ticks) internal view returns (uint160) {
        (, int24 tick,,) = pm.getSlot0(key.toId());
        bool zeroForOne = _native(key) ? buy : buy == _isQuote0(key);
        return TickMath.getSqrtPriceAtTick(zeroForOne ? tick - ticks : tick + ticks);
    }

    /// Three launches: a coin paired with the ERC-20 in each currency order, and one with the native asset.
    function _threeCoins() internal returns (PoolKey[3] memory keys_) {
        (, keys_[0]) = _launch(true, 0);
        (, keys_[1]) = _launch(false, 0);
        (, keys_[2]) = _launchNative(0, address(0));
    }

    /// Specified amounts per swap type that fit each kind of coin: buys of the Quote Asset or of coins,
    /// sells of coins or of the Quote Asset.
    function _amount(PoolKey memory key, bool buy, bool exactIn) internal pure returns (uint256) {
        bool n = _native(key);
        if (buy) return exactIn ? (n ? 0.5 ether : 10 ether) : 1e9 ether;
        return exactIn ? 1e9 ether : (n ? 0.01 ether : 1 ether);
    }
}

/// A trade may name a referrer and a Referrer Fee up to its Listing's cap (ADR 0027): the fee is taken on
/// top of the Platform Fee, on the Quote Asset's side, and recorded as the referrer's Credit; the Platform
/// Fee and its split are what they would be without it.
contract ReferrerTest is ReferrerBase {
    function test_referrer_fourSwapTypes_creditTheFeeOnTopOfThePlatformFee() public {
        PoolKey[3] memory coins = _threeCoins();
        uint256 refBps = 60; // 0.60%, under the cap of 1.00%
        for (uint256 c; c < coins.length; c++) {
            PoolKey memory key = coins[c];
            // Something to sell first.
            _see(key, true, true, _amount(key, true, true) * 4, "");
            for (uint256 i; i < 4; i++) {
                bool buy = i < 2;
                bool exactIn = i % 2 == 0;
                uint256 amount = _amount(key, buy, exactIn);
                Seen memory s = _see(key, buy, exactIn, amount, _referral(referrer, refBps));
                (uint256 pf, uint256 rf) = _expected(buy, exactIn, s, refBps, amount);
                assertGt(rf, 0);
                assertEq(s.referrerCredit, rf, "the Referrer Fee, credited to the referrer");
                assertEq(s.creatorCredit + s.platformCredit, pf, "the Platform Fee, on top of which it is taken");
                assertEq(s.creatorCredit, pf * CREATOR_SHARE_BPS / 10_000, "the Platform Fee's split, unchanged");
                assertEq(s.taken, pf + rf);
                // The Platform Fee is still 1.00% of the Quote Asset's side, to the rounding of a wei.
                uint256 side = buy ? s.quoteIn : s.quoteOut + s.taken;
                assertApproxEqAbs(pf * 10_000, side * PLATFORM_FEE_BPS, 10_000, "1.00% of the Quote Asset's side");
                assertApproxEqAbs(rf * 10_000, side * refBps, 10_000, "the named rate of the same side");
            }
        }
    }

    /// The trader pays the Referrer Fee; the Platform Fee of an exact-in buy is the very figure of the same
    /// buy with no referrer, and the referrer's fee is all the difference to the pool.
    function test_referrer_exactInBuy_samePlatformFee_traderPaysTheDifference() public {
        (, PoolKey memory key) = _launch(true, 0);
        uint256 snap = vm.snapshotState();
        Seen memory plain = _see(key, true, true, 10 ether, "");
        vm.revertToState(snap);
        Seen memory referred = _see(key, true, true, 10 ether, _referral(referrer, REFERRER_FEE_CAP_BPS));
        assertEq(referred.creatorCredit, plain.creatorCredit);
        assertEq(referred.platformCredit, plain.platformCredit);
        assertEq(referred.referrerCredit, 0.1 ether, "1.00% of the 10 paid, the cap itself");
        assertEq(referred.quoteIn, plain.quoteIn, "exact in: the trader pays the amount either way");
    }

    function test_referrer_eventNamesTheReferrer() public {
        (, PoolKey memory key) = _launch(true, 0);
        _approveAll(key);
        uint256 fee = _feeOnGross(10 ether);
        vm.expectEmit(true, true, true, true, address(hook));
        emit StokerHook.ReferrerFeeCredited(key.toId(), _quoteCurrency(), referrer, _feeOnGrossAt(10 ether, 40));
        uint256 creatorCredit = fee * CREATOR_SHARE_BPS / 10_000;
        vm.expectEmit(true, true, true, true, address(hook));
        emit StokerHook.FeeCredited(key.toId(), _quoteCurrency(), creator, fee, creatorCredit, fee - creatorCredit);
        _trade(key, true, true, 10 ether, _defaultLimit(key, true), _referral(referrer, 40));
    }

    function testFuzz_referrer_creditsAlwaysSumToWhatWasTaken(
        uint256 coinSeed,
        bool buy,
        bool exactIn,
        uint256 amount,
        uint256 refBps
    ) public {
        PoolKey[3] memory coins = _threeCoins();
        PoolKey memory key = coins[coinSeed % 3];
        bool n = _native(key);
        _see(key, true, true, n ? 5 ether : 100 ether, "");
        refBps = bound(refBps, 0, REFERRER_FEE_CAP_BPS);
        address coin = Currency.unwrap(n ? key.currency1 : (_isQuote0(key) ? key.currency1 : key.currency0));
        // Coin amounts from 1e15 raw units, so a sell pays out enough of the Quote Asset for both fees.
        if (buy) {
            amount = exactIn ? bound(amount, 1e9, n ? 50 ether : 1_000 ether) : bound(amount, 1e15, 1e10 ether);
        } else {
            amount = exactIn
                ? bound(amount, 1e15, IERC20(coin).balanceOf(trader))
                : bound(amount, 1e9, n ? 0.5 ether : 50 ether);
        }
        Seen memory s = _see(key, buy, exactIn, amount, _referral(referrer, refBps));
        (uint256 pf, uint256 rf) = _expected(buy, exactIn, s, refBps, amount);
        assertEq(s.referrerCredit, rf, "the Referrer Fee");
        assertEq(s.creatorCredit + s.platformCredit, pf, "the Platform Fee");
    }

    // ------------------------------------------------ the cap

    function test_referrer_feeOverTheCap_revertsByName() public {
        PoolKey[3] memory coins = _threeCoins();
        for (uint256 c; c < coins.length; c++) {
            PoolKey memory key = coins[c];
            _see(key, true, true, _amount(key, true, true) * 4, "");
            _approveAll(key);
            for (uint256 i; i < 4; i++) {
                bool buy = i < 2;
                bool exactIn = i % 2 == 0;
                uint256 over = REFERRER_FEE_CAP_BPS + 1;
                vm.expectRevert(
                    _wrappedBefore(
                        abi.encodeWithSelector(StokerHook.ReferrerFeeOverCap.selector, over, REFERRER_FEE_CAP_BPS)
                    )
                );
                _trade(
                    key, buy, exactIn, _amount(key, buy, exactIn), _defaultLimit(key, buy), _referral(referrer, over)
                );
            }
            // A fee of any size beyond, a whole word of it among them.
            vm.expectRevert(
                _wrappedBefore(
                    abi.encodeWithSelector(
                        StokerHook.ReferrerFeeOverCap.selector, type(uint256).max, REFERRER_FEE_CAP_BPS
                    )
                )
            );
            _trade(
                key,
                true,
                true,
                _amount(key, true, true),
                _defaultLimit(key, true),
                _referral(referrer, type(uint256).max)
            );
            // The cap itself is taken.
            Seen memory s = _see(key, true, true, _amount(key, true, true), _referral(referrer, REFERRER_FEE_CAP_BPS));
            assertGt(s.referrerCredit, 0);
        }
    }

    // ------------------------------------------------ hookData from anyone

    /// hookData reaches the hook from any router and any caller. Empty, it names no referrer; anything else
    /// must be exactly the two words, an address with clean upper bits and a fee up to the cap, or the swap
    /// reverts by name: a malformed hookData never credits anyone.
    function test_referrer_malformedHookData_revertsByName() public {
        (, PoolKey memory key) = _launch(true, 0);
        _approveAll(key);
        bytes memory malformed = abi.encodeWithSelector(StokerHook.MalformedHookData.selector);
        bytes[7] memory bad = [
            bytes(hex"01"),
            abi.encode(referrer),
            _cut(_referral(referrer, 10), 63),
            abi.encodePacked(_referral(referrer, 10), hex"00"),
            abi.encode(referrer, uint256(10), uint256(0)),
            abi.encode(uint256(uint160(referrer)) | (uint256(1) << 160), uint256(10)),
            _referral(address(0), 10)
        ];
        for (uint256 i; i < bad.length; i++) {
            vm.expectRevert(_wrappedBefore(malformed));
            _trade(key, true, true, 10 ether, _defaultLimit(key, true), bad[i]);
            // Whatever side the fee is taken on.
            vm.expectRevert(_wrappedBefore(malformed));
            _trade(key, true, false, 1e9 ether, _defaultLimit(key, true), bad[i]);
        }
        assertEq(_cred(key, referrer), 0);
    }

    function _cut(bytes memory b, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i; i < len; i++) {
            out[i] = b[i];
        }
    }

    /// The hook, the factory and the PoolManager can never be paid usefully (an ERC-20 paid to one is
    /// stranded, the native asset refused), so naming one is refused rather than left as a loss.
    function test_referrer_ourContractsAsTheReferrer_revertByName() public {
        (, PoolKey memory key) = _launch(true, 0);
        _approveAll(key);
        address[3] memory ours = [address(hook), address(factory), address(pm)];
        for (uint256 i; i < ours.length; i++) {
            vm.expectRevert(_wrappedBefore(abi.encodeWithSelector(StokerHook.InvalidReferrer.selector, ours[i])));
            _trade(key, true, true, 10 ether, _defaultLimit(key, true), _referral(ours[i], 10));
        }
    }

    /// A referrer with a fee of zero, or the zero address with none, is no referrer: the swap costs what it
    /// costs with empty hookData, and nobody is credited.
    function test_referrer_zeroFeeOrZeroReferrer_isNoReferrer() public {
        (, PoolKey memory key) = _launch(false, 0);
        uint256 snap = vm.snapshotState();
        Seen memory plain = _see(key, true, false, 1e9 ether, "");
        bytes[2] memory none = [_referral(referrer, 0), _referral(address(0), 0)];
        for (uint256 i; i < none.length; i++) {
            vm.revertToState(snap);
            Seen memory s = _see(key, true, false, 1e9 ether, none[i]);
            assertEq(s.quoteIn, plain.quoteIn);
            assertEq(s.taken, plain.taken);
            assertEq(s.referrerCredit, 0);
        }
    }

    /// The referrer is whoever the hookData names, never the router that called the PoolManager.
    function test_referrer_isTheNamedAddress_neverTheRouter() public {
        (, PoolKey memory key) = _launch(true, 0);
        _see(key, true, true, 10 ether, _referral(referrer, 50));
        assertEq(_cred(key, address(swapRouter)), 0);
        assertEq(_cred(key, trader), 0);
        assertGt(_cred(key, referrer), 0);
    }

    /// Naming yourself gains nothing: you are credited back the fee you paid on top, the Platform Fee is
    /// what it would have been, and the same Quote Asset bought fewer coins.
    function test_referrer_namingYourself_gainsNothing() public {
        (, PoolKey memory key) = _launch(true, 0);
        _approveAll(key);
        IERC20 coin = _coin(key);
        uint256 snap = vm.snapshotState();
        (uint256 c0, uint256 h0) = (coin.balanceOf(trader), _claims(key));
        _trade(key, true, true, 10 ether, _defaultLimit(key, true), "");
        (uint256 plainCoins, uint256 plainTaken) = (coin.balanceOf(trader) - c0, _claims(key) - h0);
        vm.revertToState(snap);

        _trade(key, true, true, 10 ether, _defaultLimit(key, true), _referral(trader, REFERRER_FEE_CAP_BPS));
        uint256 rf = _feeOnGrossAt(10 ether, REFERRER_FEE_CAP_BPS);
        assertEq(_cred(key, trader), rf, "the fee comes back as a Credit");
        assertEq(_claims(key) - h0 - rf, plainTaken, "the Platform Fee is unchanged");
        assertLt(coin.balanceOf(trader) - c0, plainCoins, "fewer coins for the same 10");
    }

    /// The factory's First Buy names no referrer: a launch credits the Creator and the platform alone.
    function test_referrer_theFirstBuyNamesNone() public {
        (, PoolKey memory key) = _launch(true, 1 ether);
        assertEq(hook.totalCredits(_quoteCurrency()), _credit(creator) + _credit(platform));
        assertEq(_credit(creator) + _credit(platform), _feeOnGross(1 ether));
        key;
    }

    // ------------------------------------------------ a swap its own price limit stops early

    /// The fee of a swap with the Quote Asset specified is taken before the pool runs; with a referrer named
    /// both fees are, and a swap its limit stops early is refused in both directions, for an ERC-20 and for
    /// the native asset (#241's review).
    function test_referrer_quoteSpecifiedSwapStoppedByItsLimit_reverts() public {
        PoolKey[3] memory coins = _threeCoins();
        bytes memory stopped = _wrappedAfter(abi.encodeWithSelector(StokerHook.SwapStoppedEarly.selector));
        for (uint256 c; c < coins.length; c++) {
            PoolKey memory key = coins[c];
            bool n = _native(key);
            _see(key, true, true, n ? 5 ether : 50 ether, "");
            _approveAll(key);
            bytes memory ref = _referral(referrer, 70);

            // The limits are read before the revert is expected: `vm.expectRevert` binds to the next call,
            // and reading the pool's price is one.
            uint160 buyLimit = _limitAway(key, true, 400);
            uint160 sellLimit = _limitAway(key, false, 400);
            vm.expectRevert(stopped);
            _trade(key, true, true, n ? 10 ether : 100 ether, buyLimit, ref);
            vm.expectRevert(stopped);
            _trade(key, false, false, n ? 4 ether : 40 ether, sellLimit, ref);

            // A limit that does not bind leaves the swap alone, both fees taken.
            uint256 h0 = _claims(key);
            uint256 small = n ? 0.001 ether : 0.01 ether;
            _trade(key, true, true, small, _limitAway(key, true, 400), ref);
            assertEq(_claims(key) - h0, _feeOnGross(small) + _feeOnGrossAt(small, 70));
            h0 = _claims(key);
            _trade(key, false, false, small, _limitAway(key, false, 400), ref);
            uint256 total = PLATFORM_FEE_BPS + 70;
            assertEq(_claims(key) - h0, _feeOnNetWith(small, PLATFORM_FEE_BPS, total) + _feeOnNetWith(small, 70, total));
        }
    }

    /// With the coin specified, both fees are taken after the pool runs on the Quote Asset that moved, so a
    /// swap its limit stops early pays both on what it really traded.
    function test_referrer_coinSpecifiedSwapStoppedByItsLimit_paysOnWhatItTraded() public {
        PoolKey[3] memory coins = _threeCoins();
        for (uint256 c; c < coins.length; c++) {
            PoolKey memory key = coins[c];
            _see(key, true, true, _native(key) ? 5 ether : 50 ether, "");
            _approveAll(key);
            uint256 q0 = _bal(key, trader);
            uint256 h0 = _claims(key);
            uint256 r0 = _cred(key, referrer);
            _trade(key, true, false, 1e11 ether, _limitAway(key, true, 400), _referral(referrer, 70));
            Seen memory s;
            s.quoteIn = q0 - _bal(key, trader);
            s.taken = _claims(key) - h0;
            (uint256 pf, uint256 rf) = _expected(true, false, s, 70, 0);
            assertEq(s.taken, pf + rf);
            assertEq(_cred(key, referrer) - r0, rf);
        }
    }

    /// A tiny sell whose two fees would together exceed what the pool pays out reverts instead of making the
    /// trader pay to sell: a sell paying out 1 wei owes 1 of Platform Fee and 1 of Referrer Fee.
    function test_referrer_sellTheFeesWouldExceed_reverts() public {
        (, PoolKey memory key) = _launch(true, 0);
        _see(key, true, true, 10 ether, "");
        _approveAll(key);
        uint256 coins = _coinsPayingOutOneWei(key);
        vm.expectRevert(_wrappedAfter(abi.encodeWithSelector(StokerHook.SwapTooSmall.selector)));
        _trade(key, false, true, coins, _defaultLimit(key, false), _referral(referrer, 50));
        // With no referrer the same sell goes through, as before this slice: the trader receives nothing.
        uint256 q0 = _bal(key, trader);
        _trade(key, false, true, coins, _defaultLimit(key, false), "");
        assertEq(_bal(key, trader), q0);
    }

    /// The fewest coins whose exact-in sell makes the pool pay out exactly 1 wei, found from outside.
    function _coinsPayingOutOneWei(PoolKey memory key) internal returns (uint256 coins) {
        for (coins = 1e9;; coins += coins / 4) {
            uint256 snap = vm.snapshotState();
            (uint256 q0, uint256 h0) = (_bal(key, trader), _claims(key));
            _trade(key, false, true, coins, _defaultLimit(key, false), "");
            uint256 gross = _bal(key, trader) - q0 + _claims(key) - h0;
            vm.revertToState(snap);
            if (gross == 1) return coins;
            require(gross == 0, "stepped past 1 wei");
        }
    }
}

/// A referrer is any address a trade names, so it is treated as hostile (#243): one that refuses, burns
/// its gas or re-enters stays owed and stops nobody, and a blocklisted referrer of a Stock Token stays owed.
contract ReferrerPayoutTest is ReferrerBase {
    uint256 internal constant KEEPER_GAS = 1_000_000;

    function test_referrer_payout_strangerPaysTheReferrer_toItselfAlone() public {
        PoolKey[3] memory coins = _threeCoins();
        for (uint256 c; c < coins.length; c++) {
            PoolKey memory key = coins[c];
            _see(key, true, true, _amount(key, true, true), _referral(referrer, 80));
            uint256 owed = _cred(key, referrer);
            assertGt(owed, 0);
            address[] memory owners = new address[](1);
            owners[0] = referrer;
            uint256 b0 = _bal(key, referrer);
            uint256 s0 = _bal(key, stranger);
            vm.prank(stranger);
            hook.payout{gas: KEEPER_GAS}(_q(key), owners);
            assertEq(_bal(key, referrer) - b0, owed, "paid to the referrer");
            assertEq(_bal(key, stranger), s0, "the caller gains nothing");
            assertEq(_cred(key, referrer), 0);
        }
    }

    /// A referrer the Stock Token blocks stays owed, while the Creator and the platform in the same call are
    /// paid and trading goes on; unblocked, it is paid.
    function test_referrer_payout_blockedReferrerStaysOwed() public {
        (, PoolKey memory key) = _launch(true, 0);
        _see(key, true, true, 10 ether, _referral(referrer, 80));
        mockQuote.setBlocked(referrer, true);
        _see(key, true, true, 10 ether, _referral(referrer, 80));
        uint256 owed = _cred(key, referrer);

        address[] memory owners = new address[](3);
        (owners[0], owners[1], owners[2]) = (referrer, creator, platform);
        uint256 creatorOwed = _credit(creator);
        vm.expectEmit(true, true, false, true, address(hook));
        emit StokerHook.CreditRefused(referrer, _quoteCurrency(), owed);
        vm.prank(stranger);
        hook.payout(_quoteCurrency(), owners);
        assertEq(_cred(key, referrer), owed, "owed to the referrer, to nobody else");
        assertEq(quote.balanceOf(creator) >= creatorOwed, true);
        assertEq(_credit(creator), 0, "the Creator paid beside it");
        assertEq(_credit(platform), 0, "the platform paid beside it");
        assertEq(_hookClaims(), owed, "and still backed");

        mockQuote.setBlocked(referrer, false);
        hook.payout(_quoteCurrency(), owners);
        assertEq(quote.balanceOf(referrer), owed);
    }

    /// Referrers that refuse, burn their gas, return a bomb or re-enter, named on native trades, stay owed
    /// under a Keeper's gas while an ordinary referrer, the Creator and the platform in the same call are paid.
    function test_referrer_payout_hostileNativeReferrersStayOwed() public {
        (, PoolKey memory key) = _launchNative(0.1 ether, address(0));
        address[5] memory hostile = [
            address(new RevertingRecipient()),
            address(new GasBurningRecipient()),
            address(new ReturnBombRecipient()),
            address(new ReentrantPayoutRecipient(hook, false)),
            address(new ReentrantSwapRecipient(pm, key, false))
        ];
        for (uint256 i; i < hostile.length; i++) {
            _swapNativeWithData(
                key, trader, true, true, 0.5 ether, 0, TickMath.MIN_SQRT_PRICE + 1, _referral(hostile[i], 90)
            );
        }
        _swapNativeWithData(key, trader, true, true, 0.5 ether, 0, TickMath.MIN_SQRT_PRICE + 1, _referral(referrer, 90));

        address[] memory owners = new address[](hostile.length + 3);
        uint256[] memory owed = new uint256[](hostile.length);
        for (uint256 i; i < hostile.length; i++) {
            owners[i] = hostile[i];
            owed[i] = _nativeCredit(hostile[i]);
            assertGt(owed[i], 0);
        }
        (owners[5], owners[6], owners[7]) = (referrer, creator, platform);
        (uint256 r, uint256 c, uint256 p) = (_nativeCredit(referrer), _nativeCredit(creator), _nativeCredit(platform));
        (uint256 rb, uint256 cb) = (referrer.balance, creator.balance);

        vm.prank(stranger);
        hook.payout{gas: KEEPER_GAS}(NATIVE, owners);
        for (uint256 i; i < hostile.length; i++) {
            assertEq(_nativeCredit(hostile[i]), owed[i], "a hostile referrer stays owed, to itself");
        }
        assertEq(referrer.balance - rb, r, "the ordinary referrer paid");
        assertEq(creator.balance - cb, c, "the Creator paid");
        assertEq(platform.balance, p, "the platform paid");
        assertEq(address(hook).balance, 0);
        assertEq(_nativeClaims(), hook.totalCredits(NATIVE), "the claims back what is still owed");
    }
}
