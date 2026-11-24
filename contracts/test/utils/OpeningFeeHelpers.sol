// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {StokerHook} from "../../src/StokerHook.sol";
import {TaxHelpers} from "./TaxHelpers.sol";

/// @notice What the Opening Fee's tests share (#246, ADR 0026): launching each type in each kind of pool
///         without leaving the window, a buy carrying a referrer, what a buy did to every book measured from
///         outside, and the rule kept as a second, plain copy to check the hook against.
abstract contract OpeningFeeHelpers is TaxHelpers {
    uint256 internal constant B = 10_000;

    address internal referrer = makeAddr("referrer");

    /// What one swap did, measured from outside.
    struct Seen {
        uint256 quoteIn; // Quote Asset the trader paid (buys)
        uint256 quoteOut; // Quote Asset the trader received (sells)
        uint256 creatorCredit;
        uint256 platformCredit;
        uint256 referrerCredit;
        uint256 tax; // what the pool's booked tax grew by
        uint256 opening; // what the pool's booked Opening Fee grew by
        uint256 vaultClaims; // what the Tax Vault's claims grew by
        uint256 hookClaims; // what the hook's claims grew by
    }

    /// The four fees the rule says a buy owes.
    struct Fees {
        uint256 fee;
        uint256 referrerFee;
        uint256 tax;
        uint256 opening;
    }

    // ---------------------------------------------------------------- launching inside the window

    /// 0: the coin is currency0; 1: the coin is currency1; 2: paired with the native asset. 0: standard;
    /// 1: a Reward Launch (a quarter to the burn, a quarter to Support Liquidity); 2: a Stoke Launch. The
    /// clock stays at the launch's own second.
    function _launchOpen(uint256 kind, uint256 launchType, uint256 firstBuy) internal returns (PoolKey memory key) {
        _tradeInOpening = true;
        StokerHook.LaunchType lt = StokerHook.LaunchType(launchType);
        uint16 taxBps = lt == StokerHook.LaunchType.Standard ? 0 : TAX_BPS;
        uint16 share = lt == StokerHook.LaunchType.Reward ? 2_500 : 0;
        (, key) = _launchWith(
            _typedParams(
                kind == 2 ? address(0) : address(quote),
                kind == 1,
                firstBuy,
                lt,
                taxBps,
                share,
                share,
                StokerHook.PayoutAsset.QuoteAsset
            )
        );
    }

    function _launchedAt(PoolKey memory key) internal view returns (uint256) {
        return hook.termsOf(key.toId()).launchedAt;
    }

    function _taxBpsOf(PoolKey memory key) internal view returns (uint256) {
        return hook.termsOf(key.toId()).taxBps;
    }

    /// An exact-in buy's amount and an exact-out buy's coins, sized to the pool's kind.
    function _buyAmount(PoolKey memory key, bool exactIn) internal pure returns (uint256) {
        if (_native(key)) return exactIn ? 0.05 ether : 1e9 ether;
        return exactIn ? 1 ether : 1e10 ether;
    }

    // ---------------------------------------------------------------- trading

    function _data(uint256 referrerBps) internal view returns (bytes memory) {
        return referrerBps == 0 ? bytes("") : _referral(referrer, referrerBps);
    }

    /// A swap by `who` through the test router with no price limit of its own, naming the referrer at
    /// `referrerBps` (none at zero). A native buy sends all `who` holds and is refunded the rest.
    function _tradeAs(address who, PoolKey memory key, bool buy, bool exactIn, uint256 amount, uint256 referrerBps)
        internal
        returns (BalanceDelta)
    {
        bool zeroForOne = buy == _quoteIsCurrency0(key);
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        if (_native(key)) {
            vm.prank(who);
            _coinOfKey(key).approve(address(swapRouter), type(uint256).max);
            return _swapNativeWithData(key, who, buy, exactIn, amount, who.balance, limit, _data(referrerBps));
        }
        _approveRouter(key, who);
        return _swapWithData(key, who, buy, exactIn, amount, limit, _data(referrerBps));
    }

    /// One swap by the trader, and what it did to every book.
    function _tradeAndSee(PoolKey memory key, bool buy, bool exactIn, uint256 amount, uint256 referrerBps)
        internal
        returns (Seen memory s)
    {
        return _tradeAndSeeAs(trader, key, buy, exactIn, amount, referrerBps);
    }

    function _tradeAndSeeAs(
        address who,
        PoolKey memory key,
        bool buy,
        bool exactIn,
        uint256 amount,
        uint256 referrerBps
    ) internal returns (Seen memory s) {
        Seen memory before = _snapshot(key, who);
        _tradeAs(who, key, buy, exactIn, amount, referrerBps);
        Seen memory afterwards = _snapshot(key, who);
        if (before.quoteIn > afterwards.quoteIn) s.quoteIn = before.quoteIn - afterwards.quoteIn;
        else s.quoteOut = afterwards.quoteIn - before.quoteIn;
        s.creatorCredit = afterwards.creatorCredit - before.creatorCredit;
        s.platformCredit = afterwards.platformCredit - before.platformCredit;
        s.referrerCredit = afterwards.referrerCredit - before.referrerCredit;
        s.tax = afterwards.tax - before.tax;
        s.opening = afterwards.opening - before.opening;
        s.vaultClaims = afterwards.vaultClaims - before.vaultClaims;
        s.hookClaims = afterwards.hookClaims - before.hookClaims;
        // Every wei of the tax and the Opening Fee reached the vault as claims, and nothing else did.
        assertEq(s.vaultClaims, s.tax + s.opening, "the vault's claims grew by the tax and the Opening Fee alone");
        // The hook's claims back the Credits alone.
        assertEq(
            s.hookClaims, s.creatorCredit + s.platformCredit + s.referrerCredit, "the hook's claims are the Credits"
        );
        // Nothing moved in the swap: the vault holds nothing of its own.
        assertEq(_quoteBalanceOf(key, address(taxVault)), 0, "nothing transferred to the vault");
        assertEq(_coinOfKey(key).balanceOf(address(taxVault)), 0, "no coin bought for the vault");
    }

    /// The books as they stand, the trader's Quote Asset in `quoteIn`.
    function _snapshot(PoolKey memory key, address who) internal view returns (Seen memory s) {
        s.quoteIn = _quoteBalanceOf(key, who);
        s.creatorCredit = hook.creditOf(creator, _quoteOfKey(key));
        s.platformCredit = hook.creditOf(platform, _quoteOfKey(key));
        s.referrerCredit = hook.creditOf(referrer, _quoteOfKey(key));
        s.tax = hook.taxBooked(key.toId());
        s.opening = hook.openingFeeBooked(key.toId());
        s.vaultClaims = _vaultClaims(key);
        s.hookClaims = _hookClaimsOf(key);
    }

    function _taken(Seen memory s) internal pure returns (uint256) {
        return s.creatorCredit + s.platformCredit + s.referrerCredit + s.tax + s.opening;
    }

    // ---------------------------------------------------------------- the rule, a second plain copy

    /// The Opening Fee's rate `elapsed` seconds after the launch for a buy whose standing fees are
    /// `standingBps`: the part of the start figure above them, falling in a straight line to nothing at the
    /// duration, rounded up to the basis point.
    function _openingRateAt(uint256 elapsed, uint256 standingBps) internal pure returns (uint256) {
        if (elapsed >= OPENING_FEE_DURATION || OPENING_FEE_START_BPS <= standingBps) return 0;
        uint256 n = (OPENING_FEE_START_BPS - standingBps) * (OPENING_FEE_DURATION - elapsed);
        return (n + OPENING_FEE_DURATION - 1) / OPENING_FEE_DURATION;
    }

    /// The four fees of a buy of a known gross (an exact-in buy's payment).
    function _feesOfGross(uint256 gross, uint256 referrerBps, uint256 taxBps, uint256 openingBps)
        internal
        pure
        returns (Fees memory f)
    {
        f.fee = _rateOfGross(gross, PLATFORM_FEE_BPS);
        f.referrerFee = _rateOfGross(gross, referrerBps);
        f.tax = _rateOfGross(gross, taxBps);
        if (openingBps > 0) {
            uint256 all = _rateOfGross(gross, PLATFORM_FEE_BPS + referrerBps + taxBps + openingBps);
            uint256 standing = f.fee + f.referrerFee + f.tax;
            f.opening = all > standing ? all - standing : 0;
        }
    }

    /// The four fees of a buy whose net reaching the pool is known (an exact-out buy).
    function _feesOfNet(uint256 net, uint256 referrerBps, uint256 taxBps, uint256 openingBps)
        internal
        pure
        returns (Fees memory f)
    {
        uint256 total = PLATFORM_FEE_BPS + referrerBps + taxBps + openingBps;
        f.fee = _rateOfNet(net, PLATFORM_FEE_BPS, total);
        f.referrerFee = _rateOfNet(net, referrerBps, total);
        f.tax = _rateOfNet(net, taxBps, total);
        if (openingBps > 0) {
            uint256 all = _rateOfNet(net, total, total);
            uint256 standing = f.fee + f.referrerFee + f.tax;
            f.opening = all > standing ? all - standing : 0;
        }
    }

    /// Checks one buy against the rule at `elapsed` seconds, and returns what the rule said.
    function _checkBuy(Seen memory s, bool exactIn, uint256 elapsed, uint256 referrerBps, uint256 taxBps)
        internal
        pure
        returns (Fees memory f)
    {
        uint256 openingBps = _openingRateAt(elapsed, PLATFORM_FEE_BPS + referrerBps + taxBps);
        f = exactIn
            ? _feesOfGross(s.quoteIn, referrerBps, taxBps, openingBps)
            : _feesOfNet(s.quoteIn - _taken(s), referrerBps, taxBps, openingBps);
        assertEq(s.creatorCredit + s.platformCredit, f.fee, "the Platform Fee");
        assertEq(s.creatorCredit, f.fee * CREATOR_SHARE_BPS / B, "the Creator's share of the Platform Fee alone");
        assertEq(s.referrerCredit, f.referrerFee, "the Referrer Fee alone");
        assertEq(s.tax, f.tax, "the tax");
        assertEq(s.opening, f.opening, "the Opening Fee");
    }
}
