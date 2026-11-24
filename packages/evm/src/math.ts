/**
 * Quoting on an EVM chain: prices from the pool's state and the hook's fee arithmetic, as `StokerHook` computes them,
 * so a figure the API shows is the figure the contract booked. Pure functions, no chain.
 */

export const BPS = 10_000n;
const Q96 = 2 ** 96;

/** The ceiling of a * b / d, as v4's `FullMath.mulDivRoundingUp`. */
export const mulDivUp = (a: bigint, b: bigint, d: bigint) => (a * b + d - 1n) / d;

/** The fee on a known gross amount, rounded up: what the hook takes of an exact-in buy or an exact-in sell. */
export const feeOnGross = (gross: bigint, feeBps: bigint) => mulDivUp(gross, feeBps, BPS);

/**
 * The fee on a known net amount, so that it is `feeBps` of net plus every fee taken together (`totalBps`), rounded up:
 * what the hook takes of an exact-out buy or an exact-out sell.
 */
export const feeOnNet = (net: bigint, feeBps: bigint, totalBps: bigint = feeBps) => mulDivUp(net, feeBps, BPS - totalBps);

/**
 * The price of one whole coin in whole Quote Asset units, from the pool's sqrt price (currency1 per currency0, raw
 * units, as a Q64.96). With the Quote Asset as currency0 the pool's price is coins per Quote Asset, so it is inverted.
 */
export function priceFromSqrtX96(sqrtPriceX96: bigint, quoteIsCurrency0: boolean, coinDecimals: number, quoteDecimals: number) {
  const ratio = Number(sqrtPriceX96) / Q96;
  const rawCurrency1PerCurrency0 = ratio * ratio;
  const rawQuotePerCoin = quoteIsCurrency0 ? 1 / rawCurrency1PerCurrency0 : rawCurrency1PerCurrency0;
  return rawQuotePerCoin * 10 ** (coinDecimals - quoteDecimals);
}

/**
 * The price of one whole coin in whole Quote Asset units from a Listing's start tick, which the registry writes as
 * Quote Asset raw units per coin raw unit whatever the pool's order (`IQuoteListings.Listing.startTick`).
 */
export const priceFromStartTick = (startTick: number, coinDecimals: number, quoteDecimals: number) =>
  1.0001 ** startTick * 10 ** (coinDecimals - quoteDecimals);

/** Uniswap's protocol fee on a swap's input at the rate the `Swap` event reports, in pips (millionths), rounded up. */
export const protocolFeeOn = (input: bigint, pips: number) => (pips === 0 ? 0n : mulDivUp(input, BigInt(pips), 1_000_000n));
