import { isNotNull } from "drizzle-orm";
import { WSOL_MINT } from "@launchpad/chain";
import { evmQuoteAssets, quoteAssets, type Db } from "@launchpad/db";

const WSOL = WSOL_MINT.toBase58();
const LAMPORTS_PER_SOL = 1_000_000_000n;

/** A Quote Asset's price in SOL as the Quote Registry carries it: a decimal string, with the asset's decimals. */
export type QuotePrice = { priceSol: string; decimals: number };

/** The Quote Registry's latest price per priced Quote Asset, by mint; SOL is not listed, being the unit. */
export async function quotePrices(db: Db): Promise<Map<string, QuotePrice>> {
  const rows = await db.select({ mint: quoteAssets.mint, priceSol: quoteAssets.priceSol, decimals: quoteAssets.decimals }).from(quoteAssets).where(isNotNull(quoteAssets.priceSol));
  return new Map(rows.map((q) => [q.mint, { priceSol: q.priceSol!, decimals: q.decimals }]));
}

/**
 * The key an asset's price is kept under (#254): a Solana mint as it is, an EVM chain's asset as `chain:address`, since
 * the same address (the native asset's zero address above all) names a different asset on every EVM chain.
 */
export const priceKey = (chain: string, mint: string) => (chain === "solana" ? mint : `${chain}:${mint}`);

/**
 * Every priced asset of every chain by `priceKey`: Solana's Quote Registry's prices and the EVM chains' (#254), each in
 * SOL, so an amount on any chain is valued as Solana's are. SOL itself is not listed, being the unit.
 */
export async function allPrices(db: Db): Promise<Map<string, QuotePrice>> {
  const [solana, evm] = await Promise.all([
    quotePrices(db),
    db.select({ chain: evmQuoteAssets.chain, address: evmQuoteAssets.address, priceSol: evmQuoteAssets.priceSol, decimals: evmQuoteAssets.decimals }).from(evmQuoteAssets).where(isNotNull(evmQuoteAssets.priceSol)),
  ]);
  for (const a of evm) solana.set(priceKey(a.chain, a.address), { priceSol: a.priceSol!, decimals: a.decimals });
  return solana;
}

/** What `amount` raw units of an asset on `chain` are worth in lamports at the prices given (`allPrices`); null without a price. */
export const worthOn = (chain: string, mint: string, amount: bigint, prices: Map<string, QuotePrice>) =>
  chain === "solana" ? lamportsWorth(mint, amount, prices.get(mint)) : rawWorthOf(amount, prices.get(priceKey(chain, mint)));

const rawWorthOf = (amount: bigint, q: QuotePrice | undefined) => {
  if (!q) return null;
  const { price, scale, unit } = scaled(q);
  return (amount * price * LAMPORTS_PER_SOL) / (unit * scale);
};

/** How many raw units of an EVM chain's asset are worth `lamports`, rounded down; null without a price. */
export function evmRawFor(lamports: bigint, q: QuotePrice | undefined) {
  if (!q) return null;
  const { price, scale, unit } = scaled(q);
  const divisor = price * LAMPORTS_PER_SOL;
  return divisor === 0n ? null : (lamports * unit * scale) / divisor;
}

/** The price as integers: `price / 10^scale` SOL per whole unit. */
function scaled(q: QuotePrice) {
  const [whole, fraction = ""] = q.priceSol.split(".");
  return { price: BigInt(whole! + fraction), scale: 10n ** BigInt(fraction.length), unit: 10n ** BigInt(q.decimals) };
}

/** What `amount` raw units of a Quote Asset are worth in lamports at its price, rounded down; lamports for SOL itself. */
export function lamportsWorth(mint: string, amount: bigint, q: QuotePrice | undefined) {
  if (mint === WSOL) return amount;
  if (!q) return null;
  const { price, scale, unit } = scaled(q);
  return (amount * price * LAMPORTS_PER_SOL) / (unit * scale);
}

/** How many raw units of a Quote Asset are worth `lamports` at its price, rounded up so they cover it; lamports for SOL itself. */
export function rawWorth(mint: string, lamports: bigint, q: QuotePrice | undefined) {
  if (mint === WSOL) return lamports;
  if (!q) return null;
  const { price, scale, unit } = scaled(q);
  const divisor = price * LAMPORTS_PER_SOL;
  if (divisor === 0n) return null;
  return (lamports * unit * scale + divisor - 1n) / divisor;
}

/**
 * Whether an amount of an asset is worth acting on: at least the minimum in SOL at the Quote Registry's latest price.
 * An asset without a price always is, whenever there is any, since there is no telling what it is worth.
 */
export async function valuer(db: Db, minLamports: bigint) {
  const prices = await quotePrices(db);
  return (mint: string, amount: bigint) => {
    if (amount <= 0n) return false;
    const lamports = lamportsWorth(mint, amount, prices.get(mint));
    return lamports === null ? true : lamports >= minLamports;
  };
}
