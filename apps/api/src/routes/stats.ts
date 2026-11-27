import { Hono } from "hono";
import { and, count, eq, sql } from "drizzle-orm";
import type { PlatformStats } from "@launchpad/contract";
import { graduations, launches, quoteAssets, trades } from "@launchpad/db";
import type { AppEnv } from "../env";
import { chainFilter } from "../chains/filter";

/**
 * The platform's figures in one read (#133, the landing's strip): what has launched here since the first coin, how many
 * have graduated, and the last day's volume across every coin in SOL and USD at the Quote Registry's latest prices.
 * Every figure comes from what the Indexer wrote; the money figures (revenue, what Creators were paid, what was burned)
 * are the Ledger's and stay on `/revenue` and `/burns`.
 *
 * The figures are one chain's (#279): Solana's unless `?chain=` names another, since the volume is priced by a chain's
 * own Quote Assets, and a count of every chain's coins beside one chain's volume says nothing true. An EVM chain's
 * Quote Assets have no price until its jobs (#254), so its traded day is unknown (null), never zero.
 */
export const statsRoutes = new Hono<AppEnv>();

statsRoutes.get("/stats", async (c) => {
  const db = c.get("db");
  const chain = chainFilter(c) ?? "solana";
  const [[all], [grad], [day]] = await Promise.all([
    db.select({ since: sql<Date | string | null>`min(${launches.createdAt})`, launches: count() }).from(launches).where(eq(launches.chain, chain)),
    db.select({ graduated: count() }).from(graduations).where(eq(graduations.chain, chain)),
    db
      .select({
        trades: count(),
        sol: sql<number | string | null>`sum(${trades.quoteAmount}::double precision / power(10::double precision, ${quoteAssets.decimals}) * ${quoteAssets.priceSol}::double precision)`,
        usd: sql<number | string | null>`sum(${trades.quoteAmount}::double precision / power(10::double precision, ${quoteAssets.decimals}) * ${quoteAssets.priceUsd}::double precision)`,
      })
      .from(trades)
      .innerJoin(launches, eq(launches.mint, trades.mint))
      // Left, so a trade whose Quote Asset is in no priced registry is counted and leaves the sums unknown, never out.
      .leftJoin(quoteAssets, and(eq(quoteAssets.mint, launches.quoteMint), eq(quoteAssets.chain, launches.chain)))
      .where(and(eq(trades.chain, chain), sql`${trades.blockTime} > now() - interval '24 hours'`)),
  ]);
  const since = all!.since;
  const res: PlatformStats = {
    since: since === null ? null : new Date(since).toISOString(),
    launches: all!.launches,
    graduated: grad!.graduated,
    // A day with no trades is a volume of zero, not an unknown; a traded asset without a price leaves the sum partial.
    volume24h: day!.trades === 0 ? { sol: 0, usd: 0 } : { sol: day!.sol === null ? null : Number(day!.sol), usd: day!.usd === null ? null : Number(day!.usd) },
  };
  return c.json(res);
});
