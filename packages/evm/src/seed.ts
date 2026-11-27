/**
 * The Direct Seed in integers (#253): the Seed Position `StokerFactory._placeSeed` places and the Creator's First Buy
 * `_firstBuy` makes against it, computed as the contracts compute them, so the coins a launch form shows are the coins
 * the launch delivers, to the last raw unit. Pure functions, no chain.
 *
 * The arithmetic is Uniswap's own, ported to BigInt from v4-core's `TickMath`, `SqrtPriceMath`, `SwapMath`, `TickBitmap`
 * and `Pool.swap`, and v4-periphery's `LiquidityAmounts` (all MIT licensed, copyright Uniswap Labs). Only what a pool
 * holding one position and taking no LP and no protocol fee needs is here: an exact-in swap, stepped word by word of
 * the tick bitmap as the PoolManager steps it, since each step rounds on its own.
 */
import { BPS, feeOnGross, mulDivUp } from "./math";

/** A coin's whole supply and its decimals: `StokerFactory.SUPPLY`, 1 trillion at 18 decimals (the Launch Shape, ADR 0024). */
export const COIN_DECIMALS = 18;
export const COIN_SUPPLY = 10n ** 12n * 10n ** BigInt(COIN_DECIMALS);

const Q96 = 1n << 96n;
const MAX_UINT128 = (1n << 128n) - 1n;
const MAX_UINT160 = (1n << 160n) - 1n;
const MAX_UINT256 = (1n << 256n) - 1n;

export const MIN_TICK = -887_272;
export const MAX_TICK = 887_272;
export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

/** `TickMath.getSqrtPriceAtTick`'s factors: 1 / sqrt(1.0001^(2^i)) as Q128.128, for bits 1 to 19 of the tick's size. */
const TICK_FACTORS = [
  0xfff97272373d413259a46990580e213an, 0xfff2e50f5f656932ef12357cf3c7fdccn, 0xffe5caca7e10e4e61c3624eaa0941cd0n, 0xffcb9843d60f6159c9db58835c926644n,
  0xff973b41fa98c081472e6896dfb254c0n, 0xff2ea16466c96a3843ec78b326b52861n, 0xfe5dee046a99a2a811c461f1969c3053n, 0xfcbe86c7900a88aedcffc83b479aa3a4n,
  0xf987a7253ac413176f2b074cf7815e54n, 0xf3392b0822b70005940c7a398e4b70f3n, 0xe7159475a2c29b7443b29c7fa6e889d9n, 0xd097f3bdfd2022b8845ad8f792aa5825n,
  0xa9f746462d870fdf8a65dc1f90e061e5n, 0x70d869a156d2a1b890bb3df62baf32f7n, 0x31be135f97d08fd981231505542fcfa6n, 0x9aa508b5b7a84e1c677de54f3e99bc9n,
  0x5d6af8dedb81196699c329225ee604n, 0x2216e584f5fa1ea926041bedfe98n, 0x48a170391f7dc42444e8fa2n,
];

/** `TickMath.getSqrtPriceAtTick`: sqrt(1.0001^tick) as a Q64.96, rounded up in its last place. */
export function getSqrtPriceAtTick(tick: number): bigint {
  if (!Number.isInteger(tick) || tick < MIN_TICK || tick > MAX_TICK) throw new RangeError(`tick ${tick} is outside Uniswap's range`);
  const abs = Math.abs(tick);
  let price = abs & 1 ? 0xfffcb933bd6fad37aa2d162d1a594001n : 1n << 128n;
  TICK_FACTORS.forEach((factor, i) => {
    if (abs & (2 << i)) price = (price * factor) >> 128n;
  });
  if (tick > 0) price = MAX_UINT256 / price;
  return (price + (1n << 32n) - 1n) >> 32n;
}

/** `TickMath.minUsableTick` and `maxUsableTick`: the outermost ticks on a spacing (Solidity's division truncates). */
export const maxUsableTick = (tickSpacing: number) => Math.trunc(MAX_TICK / tickSpacing) * tickSpacing;
export const minUsableTick = (tickSpacing: number) => -maxUsableTick(tickSpacing);

const divUp = (a: bigint, d: bigint) => (a + d - 1n) / d;
const ordered = (a: bigint, b: bigint): [bigint, bigint] => (a > b ? [b, a] : [a, b]);
const uint128 = (v: bigint) => {
  if (v > MAX_UINT128) throw new RangeError("the liquidity does not fit Uniswap's uint128");
  return v;
};

/** `LiquidityAmounts.getLiquidityForAmount0`, rounded down twice as there. */
export function getLiquidityForAmount0(sqrtA: bigint, sqrtB: bigint, amount0: bigint): bigint {
  const [a, b] = ordered(sqrtA, sqrtB);
  return uint128((amount0 * ((a * b) / Q96)) / (b - a));
}

/** `LiquidityAmounts.getLiquidityForAmount1`. */
export function getLiquidityForAmount1(sqrtA: bigint, sqrtB: bigint, amount1: bigint): bigint {
  const [a, b] = ordered(sqrtA, sqrtB);
  return uint128((amount1 * Q96) / (b - a));
}

/** `SqrtPriceMath.getAmount0Delta`. */
function getAmount0Delta(sqrtA: bigint, sqrtB: bigint, liquidity: bigint, roundUp: boolean): bigint {
  const [a, b] = ordered(sqrtA, sqrtB);
  const numerator1 = liquidity << 96n;
  const numerator2 = b - a;
  return roundUp ? divUp(mulDivUp(numerator1, numerator2, b), a) : (numerator1 * numerator2) / b / a;
}

/** `SqrtPriceMath.getAmount1Delta`. */
function getAmount1Delta(sqrtA: bigint, sqrtB: bigint, liquidity: bigint, roundUp: boolean): bigint {
  const [a, b] = ordered(sqrtA, sqrtB);
  return roundUp ? mulDivUp(liquidity, b - a, Q96) : (liquidity * (b - a)) / Q96;
}

/**
 * `SqrtPriceMath.getNextSqrtPriceFromInput`. Its first branch for currency0 holds only while the product and the sum
 * fit 256 bits, as the contract's overflow checks decide; past them it takes the less precise form the contract takes.
 */
function getNextSqrtPriceFromInput(sqrtP: bigint, liquidity: bigint, amountIn: bigint, zeroForOne: boolean): bigint {
  if (zeroForOne) {
    if (amountIn === 0n) return sqrtP;
    const numerator1 = liquidity << 96n;
    const product = amountIn * sqrtP;
    if (product <= MAX_UINT256 && numerator1 + product <= MAX_UINT256) return mulDivUp(numerator1, sqrtP, numerator1 + product);
    return divUp(numerator1, numerator1 / sqrtP + amountIn);
  }
  const next = sqrtP + (amountIn << 96n) / liquidity;
  if (next > MAX_UINT160) throw new RangeError("the price does not fit Uniswap's uint160");
  return next;
}

/** The Seed Position of one Launch: where the pool opens, the position's ticks and its liquidity. */
export type Seed = {
  /** Whether the Quote Asset is the pool's currency0: its address is the lower of the two (the native asset's always is). */
  quoteIsCurrency0: boolean;
  tickSpacing: number;
  openTick: number;
  tickLower: number;
  tickUpper: number;
  /** The coins the factory places, the supply less a Creator Lock's, and the liquidity they make. */
  seedCoins: bigint;
  liquidity: bigint;
};

/**
 * The Seed Position `StokerFactory._launch` and `_placeSeed` make: the pool's price is currency1 per currency0, so with
 * the coin as currency0 the pool opens at the Listing's start tick and the seed spans from it upward, and with the
 * Quote Asset as currency0 it opens at the start tick's negative and the seed spans from it downward. Either way the
 * pool opens on the seed's edge holding only coins, the supply less a Creator Lock's `supply x lockBps / 10,000`.
 */
export function seedPosition(p: { startTick: number; tickSpacing: number; quoteIsCurrency0: boolean; lockBps?: number }): Seed {
  const seedCoins = COIN_SUPPLY - (COIN_SUPPLY * BigInt(p.lockBps ?? 0)) / BPS;
  const [openTick, tickLower, tickUpper] = p.quoteIsCurrency0
    ? [-p.startTick, minUsableTick(p.tickSpacing), -p.startTick]
    : [p.startTick, p.startTick, maxUsableTick(p.tickSpacing)];
  const [sqrtLower, sqrtUpper] = [getSqrtPriceAtTick(tickLower), getSqrtPriceAtTick(tickUpper)];
  const liquidity = p.quoteIsCurrency0 ? getLiquidityForAmount1(sqrtLower, sqrtUpper, seedCoins) : getLiquidityForAmount0(sqrtLower, sqrtUpper, seedCoins);
  return { quoteIsCurrency0: p.quoteIsCurrency0, tickSpacing: p.tickSpacing, openTick, tickLower, tickUpper, seedCoins, liquidity };
}

/**
 * `TickBitmap.nextInitializedTickWithinOneWord` for a pool whose only initialized ticks are the seed's two: the next
 * one in the swap's direction inside the current word of 256 spacings, or that word's edge when it holds none.
 */
function nextTickWithinOneWord(seed: Seed, tick: number, lte: boolean): { next: number; initialized: boolean } {
  const spacing = seed.tickSpacing;
  const compressed = Math.floor(tick / spacing);
  const ticks = [seed.tickLower / spacing, seed.tickUpper / spacing];
  if (lte) {
    const word = Math.floor(compressed / 256);
    const found = ticks.filter((t) => Math.floor(t / 256) === word && t <= compressed);
    return found.length ? { next: Math.max(...found) * spacing, initialized: true } : { next: word * 256 * spacing, initialized: false };
  }
  const from = compressed + 1;
  const word = Math.floor(from / 256);
  const found = ticks.filter((t) => Math.floor(t / 256) === word && t >= from);
  return found.length ? { next: Math.min(...found) * spacing, initialized: true } : { next: (word * 256 + 255) * spacing, initialized: false };
}

/** More steps than any spacing needs to cross Uniswap's whole range a word at a time (6,932 at a spacing of 1). */
const MAX_STEPS = 8_000;

/**
 * An exact-in buy of `amountIn` of the Quote Asset against a pool that holds only the Seed Position and stands at its
 * opening price, as `Pool.swap` runs it with no LP fee and no protocol fee (a pool has neither in its launch's own
 * transaction) and the factory's price limit, the last price Uniswap allows. Answers the coins out and what the pool
 * could not take: more than nothing only when the buy asked for more than the seed holds.
 */
export function buyFromSeed(seed: Seed, amountIn: bigint): { coinsOut: bigint; unspent: bigint } {
  const zeroForOne = seed.quoteIsCurrency0;
  const limit = zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n;
  let sqrtP = getSqrtPriceAtTick(seed.openTick);
  let tick = seed.openTick;
  // A position is in range from its lower tick up to, and not at, its upper one.
  let liquidity = seed.tickLower <= tick && tick < seed.tickUpper ? seed.liquidity : 0n;
  let remaining = amountIn;
  let coinsOut = 0n;
  for (let steps = 0; remaining !== 0n && sqrtP !== limit; steps++) {
    if (steps >= MAX_STEPS) throw new RangeError("the swap did not end");
    const { next, initialized } = nextTickWithinOneWord(seed, tick, zeroForOne);
    const tickNext = Math.min(MAX_TICK, Math.max(MIN_TICK, next));
    const sqrtNext = getSqrtPriceAtTick(tickNext);
    const target = zeroForOne ? (sqrtNext > limit ? sqrtNext : limit) : sqrtNext < limit ? sqrtNext : limit;
    // `SwapMath.computeSwapStep`, exact in, with a swap fee of zero: nothing is held back from the amount.
    let stepIn = zeroForOne ? getAmount0Delta(target, sqrtP, liquidity, true) : getAmount1Delta(sqrtP, target, liquidity, true);
    let reached = target;
    if (remaining < stepIn) {
      stepIn = remaining;
      reached = getNextSqrtPriceFromInput(sqrtP, liquidity, remaining, zeroForOne);
    }
    coinsOut += zeroForOne ? getAmount1Delta(reached, sqrtP, liquidity, false) : getAmount0Delta(sqrtP, reached, liquidity, false);
    remaining -= stepIn;
    sqrtP = reached;
    if (sqrtP === sqrtNext) {
      if (initialized) {
        // Crossing the seed's lower tick upward adds its liquidity and its upper tick takes it away; downward, the reverse.
        const net = tickNext === seed.tickLower ? seed.liquidity : -seed.liquidity;
        liquidity += zeroForOne ? -net : net;
      }
      tick = zeroForOne ? tickNext - 1 : tickNext;
    }
    // Otherwise the amount is spent (there is no fee to leave a remainder), and the loop ends.
  }
  return { coinsOut, unspent: remaining };
}

/** What the Creator's First Buy pays and gets, or why the hook or the pool would refuse it. */
export type FirstBuyQuote =
  | { ok: true; amountIn: bigint; coinsOut: bigint; platformFee: bigint; tax: bigint }
  | { ok: false; reason: "too_small" | "more_than_the_seed" };

/**
 * The Creator's First Buy inside the launch (`StokerFactory._firstBuy`): an exact-in buy by the factory, which pays
 * the Platform Fee and the coin's tax, each `ceil(amount x bps / 10,000)` of the whole amount (`StokerHook._feesOnGross`),
 * never the Opening Fee, and no protocol fee, since the pool is new. What is left enters the pool, which holds only
 * the Seed Position. The hook refuses a buy its fees swallow whole (`SwapTooSmall`) and one the pool could not take
 * whole (`SwapStoppedEarly`); one that would buy no coin at all is refused here, since it would only spend.
 */
export function quoteFirstBuy(seed: Seed, p: { amountIn: bigint; platformFeeBps: number; taxBps: number }): FirstBuyQuote {
  const platformFee = feeOnGross(p.amountIn, BigInt(p.platformFeeBps));
  const tax = feeOnGross(p.amountIn, BigInt(p.taxBps));
  const taken = platformFee + tax;
  if (taken >= p.amountIn) return { ok: false, reason: "too_small" };
  const { coinsOut, unspent } = buyFromSeed(seed, p.amountIn - taken);
  if (unspent > 0n) return { ok: false, reason: "more_than_the_seed" };
  if (coinsOut === 0n) return { ok: false, reason: "too_small" };
  return { ok: true, amountIn: p.amountIn, coinsOut, platformFee, tax };
}

/**
 * The Opening Value of a Listing: what a coin's whole supply is worth at the start price, in the Quote Asset's raw
 * units. The start tick is Quote Asset raw units per coin raw unit (`IQuoteListings.Listing.startTick`), so the value
 * is `supply x sqrtPrice^2 / 2^192` with Uniswap's own Q64.96 sqrt price at that tick, in integers and rounded down
 * once at the end; the sqrt price itself is rounded up in its last place by `getSqrtPriceAtTick`, a part in 2^64 at most.
 */
export function openingValue(startTick: number): bigint {
  const sqrtP = getSqrtPriceAtTick(startTick);
  return (COIN_SUPPLY * sqrtP * sqrtP) >> 192n;
}
