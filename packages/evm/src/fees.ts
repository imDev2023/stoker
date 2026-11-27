import { BPS, feeOnGross, feeOnNet, mulDivUp } from "./math";

/**
 * The fees of a swap in a coin's own pool as `StokerHook` takes them (#253), to the wei: the Platform Fee, the coin's
 * tax (a Reward Tax or a Stoke Tax), the Opening Fee and the Referrer Fee, from the Launch's own terms and the block's
 * time alone. Every function names the function of the hook it mirrors and the rule in contracts/README.md it stands
 * on, so a quote's fee lines are the figures the hook's events will carry. Pure functions, no chain.
 *
 * Two swaps are not a trader's and are not priced here: the Creator's First Buy inside the launch (the factory's, which
 * never pays the Opening Fee) and the Tax Vault's own buys (which pay no tax). No trade the site prepares is either.
 */

/** The terms of a Launch its fees are read from: the fields of `StokerHook.Terms`, as `termsOf(poolId)` answers them. */
export type FeeTerms = {
  platformFeeBps: number;
  /** The coin's tax: nothing for a standard coin. */
  taxBps: number;
  /** The Launch's own second, the block time the hook wrote when it registered the terms. */
  launchedAt: bigint;
  /** What a buy's fees take together at the launch's own second, and the seconds the Opening Fee runs. */
  openingFeeStartBps: number;
  openingFeeDuration: number;
};

/** The four rates one swap pays, in basis points: `referrer` is the rate the hook takes, already held to its room. */
export type FeeRates = { platform: number; tax: number; opening: number; referrer: number };

/** The four fees one swap pays, in the Quote Asset's raw units. */
export type SwapFees = { platform: bigint; tax: bigint; opening: bigint; referrer: bigint };

export const feesTotal = (f: SwapFees) => f.platform + f.tax + f.opening + f.referrer;

/**
 * The Opening Fee's rate on a buy at `time`, a block's time in seconds (`_openingBps`; README, "The Opening Fee",
 * the rule): at the launch's own second a buy's fees together take the start figure, the Opening Fee being the part of
 * it above the Platform Fee and the tax, and that part falls in a straight line to nothing at the duration:
 * `ceil((start - platform - tax) x secondsLeft / duration)`. So it never rises with time, never passes the start
 * figure, is exactly zero from the last second on, and a clock read before the launch's own second is held to the
 * start figure. A Referrer Fee is never counted among the fees it stands above.
 */
export function openingBpsAt(t: FeeTerms, time: bigint): number {
  const duration = BigInt(t.openingFeeDuration);
  const end = t.launchedAt + duration;
  // A duration of zero has no window; the hook never divides by it on a clock that runs forward.
  if (time >= end || duration === 0n) return 0;
  const standing = t.platformFeeBps + t.taxBps;
  if (t.openingFeeStartBps <= standing) return 0;
  const left = end - time < duration ? end - time : duration;
  return Number(mulDivUp(BigInt(t.openingFeeStartBps - standing), left, duration));
}

/**
 * The Referrer Fee's rate as the hook takes it (`_referrerBpsUnderTheStart`; README, "A Referrer Fee inside the
 * window"): outside the window (an Opening Fee rate of zero) the rate the trade named, whole; inside it no more than
 * the room the Platform Fee, the tax and the Opening Fee leave under the start figure,
 * `min(named, start - platform - tax - opening)`. So it is nothing at the launch's own second and grows as the
 * schedule falls, and naming a referrer never lowers the Opening Fee.
 */
export function referrerBpsUnderTheStart(t: FeeTerms, namedBps: number, openingBps: number): number {
  if (openingBps === 0) return namedBps;
  return Math.min(namedBps, t.openingFeeStartBps - t.platformFeeBps - t.taxBps - openingBps);
}

/**
 * The four rates a trader's swap pays at `time`: a buy pays the Opening Fee while it runs and its Referrer Fee is held
 * to the room under the start figure; a sell never pays the Opening Fee, so the rate it named is taken whole (the
 * hook's `_beforeSwap` and `_afterSwap` pass an Opening Fee rate of zero for every sell). `namedReferrerBps` is the
 * rate in the trade's `hookData`, which the hook has already refused above the Launch's cap.
 */
export function feeRatesAt(t: FeeTerms, time: bigint, side: "buy" | "sell", namedReferrerBps = 0): FeeRates {
  const opening = side === "buy" ? openingBpsAt(t, time) : 0;
  return { platform: t.platformFeeBps, tax: t.taxBps, opening, referrer: referrerBpsUnderTheStart(t, namedReferrerBps, opening) };
}

/** What the combined rate takes beyond the Platform Fee and the tax, never below zero (`_openingRest`). */
const openingRest = (allTaken: bigint, standing: bigint) => (allTaken > standing ? allTaken - standing : 0n);

/**
 * The four fees of a known gross amount (`_feesOnGross`): what an exact-in buy pays of the amount the trader spends,
 * and what an exact-in sell pays of the Quote Asset the pool pays out. Outside the window each is its rate of the
 * gross, rounded up (README, the fee table and the Referrer Fee's). Inside it the Platform Fee and the tax are their
 * rates, rounded up; the Opening Fee is what those two rates and its own take together, rounded up once, less the two
 * as each was rounded; and the Referrer Fee is what adding its rate to the three takes beyond that (README, the
 * Opening Fee's table). So a buy inside the window pays its combined rate rounded up once, and the Opening Fee is the
 * same to the wei with or without a referrer.
 */
export function feesOnGross(gross: bigint, r: FeeRates): SwapFees {
  const platform = feeOnGross(gross, BigInt(r.platform));
  const tax = feeOnGross(gross, BigInt(r.tax));
  if (r.opening === 0) return { platform, tax, opening: 0n, referrer: feeOnGross(gross, BigInt(r.referrer)) };
  const withoutReferrer = feeOnGross(gross, BigInt(r.platform + r.tax + r.opening));
  return {
    platform, tax, opening: openingRest(withoutReferrer, platform + tax),
    referrer: feeOnGross(gross, BigInt(r.platform + r.tax + r.opening + r.referrer)) - withoutReferrer,
  };
}

/**
 * The four fees of a gross amount known only as its net (`_feesOnNet`): what an exact-out buy pays on top of the Quote
 * Asset that reaches the pool, and what an exact-out sell pays on top of what reaches the trader. Each is its rate of
 * net plus every fee, rounded up, by the same split as `feesOnGross` inside the window, so the Platform Fee stays its
 * rate of what the buyer pays on either kind of buy (README, the two tables' exact-out rows).
 */
export function feesOnNet(net: bigint, r: FeeRates): SwapFees {
  const total = BigInt(r.platform + r.tax + r.opening + r.referrer);
  const platform = feeOnNet(net, BigInt(r.platform), total);
  const tax = feeOnNet(net, BigInt(r.tax), total);
  if (r.opening === 0) return { platform, tax, opening: 0n, referrer: feeOnNet(net, BigInt(r.referrer), total) };
  const withoutReferrer = feeOnNet(net, BigInt(r.platform + r.tax + r.opening), total);
  return { platform, tax, opening: openingRest(withoutReferrer, platform + tax), referrer: feeOnNet(net, total, total) - withoutReferrer };
}

/**
 * The gross whose fees, taken as `feesOnGross` takes them, leave exactly `net`: the Quote Asset a pool paid out on an
 * exact-in sell, of which a quote knows only what reached the trader. Null when no gross leaves that net, which no
 * figure the hook produced can be.
 *
 * Each fee is rounded up on its own, so stepping the gross by a wei steps the fees together by nothing, by one wei or
 * by more, and two grosses a wei or two apart can leave the same net (about one net in a hundred at a 1.00% fee).
 * The smallest is answered: every fee is then at most what the swap took, so a line read from it never overstates a
 * fee, and it can be a wei under the swap's own on the line whose rounding stepped. What reaches the trader is not
 * touched by the choice.
 */
export function grossLeaving(net: bigint, r: FeeRates): bigint | null {
  const total = BigInt(r.platform + r.tax + r.opening + r.referrer);
  if (net < 0n || total >= BPS) return null;
  // The fees together are at least the gross times the combined rate and less than that plus one wei a fee, so every
  // gross that fits lies between these two.
  const low = mulDivUp(net, BPS, BPS - total);
  const high = mulDivUp(net + 4n, BPS, BPS - total);
  for (let gross = low; gross <= high; gross++) if (gross - feesTotal(feesOnGross(gross, r)) === net) return gross;
  return null;
}
