// The EVM chains' Quote Asset prices (#254), so what each chain collects, rebates and budgets is valued in SOL as
// Solana's is (ADR 0019). A chain's native asset is priced through its twin on Solana, the same asset as Solana's price
// source knows it (the chain's profile); an asset with no twin has no price and counts for nothing until it has one, as
// an unpriced Quote Asset does on Solana.
import { and, eq, sql } from "drizzle-orm";
import { NATIVE } from "@launchpad/evm";
import { WSOL_MINT } from "@launchpad/chain";
import { evmQuoteAssets, type Db } from "@launchpad/db";
import type { Bindings } from "../../env";
import { divide, formatDecimal, type QuoteMarket } from "../../quotes/pricing";
import type { EvmChainConfig } from "./config";
import { perChain } from "./keeper";

export type QuotesRun = { chain: string; priced: { asset: string; priceSol: string }[]; unpriced: string[] };

/** One run on every EVM chain (job `evm-quotes`), on the Quote Registry's cron after Solana's refresh. */
export const runEvmQuotes = (env: Bindings, db: Db, market: QuoteMarket) => perChain(env, (c) => priceChain(db, c, market));

async function priceChain(db: Db, c: EvmChainConfig, market: QuoteMarket): Promise<QuotesRun> {
  const run: QuotesRun = { chain: c.chain, priced: [], unpriced: [] };
  // The native asset is a Quote Asset of every chain (#242), priced before any coin pairs with it.
  await db
    .insert(evmQuoteAssets)
    .values({ chain: c.chain, address: NATIVE, symbol: c.profile.native.symbol, name: c.profile.native.name, decimals: c.profile.native.decimals, category: "native" })
    .onConflictDoNothing();
  const twin = c.profile.native.priceTwin;
  const usd = twin ? await market.usdPrices([twin, WSOL_MINT.toBase58()]) : new Map();
  const nativeUsd = twin ? usd.get(twin) : undefined;
  const solUsd = usd.get(WSOL_MINT.toBase58());
  if (nativeUsd && solUsd) {
    const priceSol = formatDecimal(divide(nativeUsd, solUsd));
    await db.update(evmQuoteAssets).set({ priceSol, pricedAt: sql`now()` }).where(and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, NATIVE)));
    run.priced.push({ asset: NATIVE, priceSol });
  } else {
    run.unpriced.push(NATIVE);
  }
  const others = await db.select({ address: evmQuoteAssets.address, symbol: evmQuoteAssets.symbol }).from(evmQuoteAssets).where(and(eq(evmQuoteAssets.chain, c.chain), sql`${evmQuoteAssets.address} <> ${NATIVE}`));
  run.unpriced.push(...others.map((o) => o.symbol ?? o.address));
  return run;
}
