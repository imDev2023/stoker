// The Creator Ladder on an EVM chain (ADR 0027, #248, #254): the factory writes a coin's three shares into its terms,
// the hook credits the first from launch, and the ladder key raises a graduated coin to the second and the top tier
// when its Active Days reach them. Active Days are counted here from the indexed trades, as Solana's are, after the
// coin's Graduation: a UTC day on which its pool traded at least the ladder's floor of the Quote Asset it took to carry
// the coin from its start price to its Graduation Target. The raise is the chain's to record: the Indexer writes the
// tier from the hook's `CreatorTierRaised`, so a page never shows a tier the chain has not given.
import { encodeFunctionData, type Hex } from "viem";
import { and, asc, eq, sql } from "drizzle-orm";
import { stokerHookAbi } from "@launchpad/evm";
import { creatorTiers, graduations, launches, trades, type Db } from "@launchpad/db";
import type { Config } from "../../env";
import type { Bindings } from "../../env";
import { ladderVersions, split, tierFor } from "../../fees/ladder";
import type { EvmChainConfig } from "./config";
import { perChain } from "./keeper";
import { EvmSender, Refused } from "./sender";

const TOP_TIER = 3;

export type LadderRun = {
  chain: string;
  skipped: string | null;
  /** Every climbing coin's Active Days as counted now. */
  counted: { coin: string; activeDays: number; tier: number }[];
  raised: { coin: string; tier: number; hash: Hex }[];
  refused: { coin: string; reason: string }[];
};

/** One run of the ladder on every EVM chain (job `evm-ladder`). */
export const runEvmLadder = (env: Bindings, cfg: Config, db: Db) => perChain(env, (c) => climb(db, cfg, c));

async function climb(db: Db, cfg: Config, c: EvmChainConfig): Promise<LadderRun> {
  const run: LadderRun = { chain: c.chain, skipped: null, counted: [], raised: [], refused: [] };
  const { inForce } = split(await ladderVersions(db));
  const days = await countActiveDays(db, c, cfg.activeDaySeconds, inForce.activeDayFloorBps);
  const climbing = await db
    .select({ mint: graduations.mint, pool: graduations.pool, counted: graduations.activeDays, tier: sql<number>`coalesce(max(${creatorTiers.tier}), 1)::int` })
    .from(graduations)
    .innerJoin(launches, eq(launches.mint, graduations.mint))
    .leftJoin(creatorTiers, eq(creatorTiers.mint, graduations.mint))
    .where(and(eq(graduations.chain, c.chain), eq(launches.factory, c.factory)))
    .groupBy(graduations.mint, graduations.pool, graduations.activeDays)
    .having(sql`coalesce(max(${creatorTiers.tier}), 1) < ${TOP_TIER}::int`)
    .orderBy(asc(graduations.mint));
  const due: { mint: string; pool: Hex; tier: number }[] = [];
  for (const coin of climbing) {
    const count = days.get(coin.mint) ?? 0;
    if (count !== coin.counted) await db.update(graduations).set({ activeDays: count }).where(and(eq(graduations.chain, c.chain), eq(graduations.mint, coin.mint)));
    run.counted.push({ coin: coin.mint, activeDays: count, tier: coin.tier });
    const tier = tierFor(inForce, count);
    if (tier > coin.tier) due.push({ mint: coin.mint, pool: coin.pool as Hex, tier });
  }
  if (!due.length) return run;
  if (!c.ladderKey) return { ...run, skipped: `no ladder key: the secret ${c.chain.toUpperCase()}_LADDER_KEY is not set, so ${due.length} raise${due.length === 1 ? " waits" : "s wait"}` };
  const sender = new EvmSender(db, c, c.ladderKey, "evm-ladder");
  await sender.settle();
  for (const d of due) {
    if (await sender.waiting("raise", d.mint)) continue;
    // The chain's own tier is the one that counts: a raise the Indexer has not read yet is not made again.
    const onChain = await sender.client.readContract({ address: c.hook, abi: stokerHookAbi, functionName: "creatorTierOf", args: [d.pool] });
    if (onChain >= d.tier) continue;
    const call = { to: c.hook, data: encodeFunctionData({ abi: stokerHookAbi, functionName: "raiseTier", args: [d.pool, d.tier] }) };
    try {
      const receipt = await sender.send("raise", d.mint, call, await sender.simulate(call, stokerHookAbi));
      if (receipt?.status === "success") run.raised.push({ coin: d.mint, tier: d.tier, hash: receipt.transactionHash });
    } catch (e) {
      if (e instanceof Refused) run.refused.push({ coin: d.mint, reason: e.reason });
      else throw e;
    }
  }
  return run;
}

/**
 * The Active Days of every graduated coin of the deployment below the top tier (ADR 0027): the days, `daySeconds` long
 * and counted from the epoch (UTC days in production), from its Graduation on, on which its pool's trades came to at
 * least `floorBps` of the Quote Asset that carries it to its Graduation Target. A coin with none is absent.
 */
async function countActiveDays(db: Db, c: EvmChainConfig, daySeconds: number, floorBps: number) {
  if (!Number.isInteger(daySeconds) || daySeconds <= 0) throw new Error(`an Active Day must be a whole number of seconds above zero (got ${daySeconds})`);
  const day = sql`floor(extract(epoch from ${trades.blockTime}) / ${sql.raw(String(daySeconds))})`;
  const active = db
    .select({ mint: trades.mint, day: day.as("day") })
    .from(trades)
    .innerJoin(launches, eq(launches.mint, trades.mint))
    .innerJoin(graduations, eq(graduations.mint, trades.mint))
    .where(sql`${trades.chain} = ${c.chain} and ${launches.factory} = ${c.factory} and ${trades.blockTime} >= ${graduations.graduatedAt}
      and not exists (select 1 from ${creatorTiers} ct where ct.mint = ${trades.mint} and ct.tier = ${TOP_TIER}::int)`)
    .groupBy(trades.mint, day, launches.graduationQuote)
    .having(sql`sum(${trades.quoteAmount}) * 10000 >= coalesce(${launches.graduationQuote}, 0) * ${floorBps}::int`)
    .as("active");
  const rows = await db.select({ mint: active.mint, days: sql<number>`count(*)::int` }).from(active).groupBy(active.mint);
  return new Map(rows.map((r) => [r.mint, r.days]));
}
