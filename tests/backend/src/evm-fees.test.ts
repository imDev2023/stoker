// #253: the fee arithmetic a quote on an EVM chain shows is the hook's own. These are the figures contracts/README.md
// states for `StokerHook` ("The Referrer Fee", "The Opening Fee"), and the properties its tables promise; that the
// same functions equal the hook's events on the chain to the wei is `evm-trade.test.ts`. No chain is needed here.
import { describe, expect, test } from "vitest";
import {
  feeRatesAt, feesOnGross, feesOnNet, feesTotal, grossLeaving, mulDivUp, openingBpsAt, referrerBpsUnderTheStart, type FeeRates, type FeeTerms,
} from "@launchpad/evm";

const LAUNCHED = 1_800_000_000n;
/** A Launch as the test stack's factory writes it: a 1.00% Platform Fee, 99.00% at the launch's own second, 20 seconds. */
const terms = (taxBps = 0): FeeTerms => ({ platformFeeBps: 100, taxBps, launchedAt: LAUNCHED, openingFeeStartBps: 9_900, openingFeeDuration: 20 });
const at = (second: number) => LAUNCHED + BigInt(second);
const ceilOf = (amount: bigint, bps: number) => mulDivUp(amount, BigInt(bps), 10_000n);
/** A seeded generator, so a failure names figures that fail again. */
function random(seed: number) {
  let s = seed >>> 0;
  return () => ((s = (Math.imul(s, 1_664_525) + 1_013_904_223) >>> 0), s / 2 ** 32);
}

describe("the Opening Fee's schedule", () => {
  test("a buy's fees together take the start figure at the launch's own second and the Opening Fee falls in a straight line to nothing", () => {
    expect(openingBpsAt(terms(), at(0))).toBe(9_800);
    // "At ten seconds a buy with no referrer on a standard coin pays 1.00% and 49.00%, 50.00% together."
    expect(openingBpsAt(terms(), at(10))).toBe(4_900);
    expect(openingBpsAt(terms(), at(19))).toBe(490);
    expect(openingBpsAt(terms(), at(20))).toBe(0);
    expect(openingBpsAt(terms(), at(86_400))).toBe(0);
    // It stands above the tax too, so a taxed coin's Opening Fee is that much less and its fees together the same.
    expect(openingBpsAt(terms(500), at(0))).toBe(9_300);
    expect(openingBpsAt(terms(300), at(7))).toBe(Math.ceil(((9_900 - 100 - 300) * 13) / 20));
  });

  test("it never rises with time, is held to the start figure on a clock read before the launch, and is nothing where the standing fees reach the start", () => {
    for (const tax of [0, 100, 300, 500]) {
      let last = Infinity;
      for (let s = -5; s <= 25; s++) {
        const bps = openingBpsAt(terms(tax), at(s));
        expect(bps).toBeLessThanOrEqual(last);
        expect(bps + 100 + tax).toBeLessThanOrEqual(9_900);
        last = bps;
      }
      expect(openingBpsAt(terms(tax), at(-5))).toBe(9_800 - tax);
    }
    expect(openingBpsAt({ ...terms(), openingFeeStartBps: 100 }, at(0))).toBe(0);
    expect(openingBpsAt({ ...terms(), openingFeeDuration: 0 }, at(0))).toBe(0);
  });

  test("a sell never pays it, and a sell's Referrer Fee is whole inside the window", () => {
    expect(feeRatesAt(terms(300), at(0), "sell", 100)).toEqual({ platform: 100, tax: 300, opening: 0, referrer: 100 });
    expect(feeRatesAt(terms(300), at(0), "buy", 100)).toEqual({ platform: 100, tax: 300, opening: 9_500, referrer: 0 });
  });
});

describe("a Referrer Fee under the start figure", () => {
  test("it takes only the room the other three leave: nothing at the launch's second, whole two seconds in at a 5.00% cap, whole after the window", () => {
    const named = 500;
    const rate = (second: number) => referrerBpsUnderTheStart(terms(), named, openingBpsAt(terms(), at(second)));
    expect(rate(0)).toBe(0);
    expect(rate(1)).toBe(490);
    expect(rate(2)).toBe(500);
    expect(rate(20)).toBe(500);
    for (let s = 0; s <= 25; s++) {
      const r = feeRatesAt(terms(300), at(s), "buy", named);
      expect(r.platform + r.tax + r.opening + r.referrer).toBeLessThanOrEqual(9_900);
      expect(r.referrer).toBeLessThanOrEqual(named);
    }
  });
});

describe("the four fees of a known gross", () => {
  test("outside the window each is its own rate of the gross, rounded up", () => {
    const gross = 20_000_000_000_000_001n;
    expect(feesOnGross(gross, { platform: 100, tax: 300, opening: 0, referrer: 50 })).toEqual({
      platform: ceilOf(gross, 100), tax: ceilOf(gross, 300), opening: 0n, referrer: ceilOf(gross, 50),
    });
    expect(feesOnGross(1n, { platform: 100, tax: 0, opening: 0, referrer: 0 })).toEqual({ platform: 1n, tax: 0n, opening: 0n, referrer: 0n });
  });

  test("inside the window a buy pays its combined rate rounded up once: at 99% a buy of 100 wei keeps one wei", () => {
    const fees = feesOnGross(100n, feeRatesAt(terms(), at(0), "buy"));
    expect(fees).toEqual({ platform: 1n, tax: 0n, opening: 98n, referrer: 0n });
    // "one of 99 wei is refused": the fees take all of it, which the hook reverts as `SwapTooSmall`.
    expect(feesTotal(feesOnGross(99n, feeRatesAt(terms(), at(0), "buy")))).toBe(99n);
    const whole = 10n ** 18n;
    expect(feesOnGross(whole, feeRatesAt(terms(), at(10), "buy"))).toEqual({ platform: whole / 100n, tax: 0n, opening: (whole * 49n) / 100n, referrer: 0n });
  });

  test("inside the window the Opening Fee is the same to the wei with or without a referrer, and naming one costs exactly its fee", () => {
    const next = random(246);
    for (let i = 0; i < 2_000; i++) {
      const gross = BigInt(Math.floor(next() * 1e15)) + 100n;
      const tax = [0, 100, 300, 500][i % 4]!;
      const second = Math.floor(next() * 20);
      const plain = feesOnGross(gross, feeRatesAt(terms(tax), at(second), "buy"));
      const rates = feeRatesAt(terms(tax), at(second), "buy", 500);
      const referred = feesOnGross(gross, rates);
      expect(referred.opening).toBe(plain.opening);
      expect(referred.platform).toBe(plain.platform);
      expect(feesTotal(referred) - feesTotal(plain)).toBe(referred.referrer);
      expect(feesTotal(referred)).toBe(ceilOf(gross, rates.platform + rates.tax + rates.opening + rates.referrer));
    }
  });
});

describe("the four fees of a gross known as its net", () => {
  test("each is its rate of net plus every fee, so the Platform Fee stays its rate of what the buyer pays", () => {
    const net = 10n ** 18n;
    const rates: FeeRates = { platform: 100, tax: 300, opening: 0, referrer: 50 };
    const fees = feesOnNet(net, rates);
    expect(fees).toEqual({
      platform: mulDivUp(net, 100n, 9_550n), tax: mulDivUp(net, 300n, 9_550n), opening: 0n, referrer: mulDivUp(net, 50n, 9_550n),
    });
    const paid = net + feesTotal(fees);
    expect(Number(fees.platform) / Number(paid)).toBeCloseTo(0.01, 12);
  });

  test("the same buy costs the same expressed either way, to a few wei of rounding", () => {
    const next = random(253);
    for (let i = 0; i < 2_000; i++) {
      const gross = BigInt(Math.floor(next() * 1e15)) + 10n ** 9n;
      const rates = feeRatesAt(terms([0, 300][i % 2]!), at(Math.floor(next() * 25)), "buy", [0, 100][i % 2]!);
      const onGross = feesOnGross(gross, rates);
      const onNet = feesOnNet(gross - feesTotal(onGross), rates);
      const off = feesTotal(onNet) - feesTotal(onGross);
      // Rounded up on a net a hundredth of the gross at the start figure: within a few hundred wei of 10^9 and more.
      expect(off >= -400n && off <= 400n).toBe(true);
    }
  });
});

describe("the gross a sell's net came from", () => {
  test("it leaves exactly that net, is never above the pool's own output, and each fee line is the swap's or a wei under it", () => {
    const next = random(271);
    let apart = 0;
    for (let i = 0; i < 20_000; i++) {
      const rates: FeeRates = { platform: 100, tax: [0, 100, 300, 500][i % 4]!, opening: 0, referrer: [0, 50, 100, 500][i % 3]! };
      const gross = BigInt(Math.floor(next() * 1e13)) + 1n;
      const real = feesOnGross(gross, rates);
      const net = gross - feesTotal(real);
      const found = grossLeaving(net, rates);
      expect(found).not.toBeNull();
      const quoted = feesOnGross(found!, rates);
      expect(found! - feesTotal(quoted)).toBe(net);
      expect(found! <= gross).toBe(true);
      for (const line of ["platform", "tax", "referrer"] as const) expect(real[line] - quoted[line] === 0n || real[line] - quoted[line] === 1n).toBe(true);
      if (found !== gross) apart++;
    }
    // Two grosses leave one net wherever a rounding steps: a few in a hundred, and never none in twenty thousand.
    expect(apart).toBeGreaterThan(0);
    expect(apart).toBeLessThan(4_000);
  });

  test("a net of nothing came from nothing, and a rate that takes everything leaves no gross", () => {
    expect(grossLeaving(0n, { platform: 100, tax: 0, opening: 0, referrer: 0 })).toBe(0n);
    expect(grossLeaving(1n, { platform: 5_000, tax: 5_000, opening: 0, referrer: 0 })).toBeNull();
  });
});
