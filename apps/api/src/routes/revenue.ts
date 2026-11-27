import { Hono, type Context } from "hono";
import type { Chain } from "@launchpad/contract";
import { desc, eq, inArray, sql } from "drizzle-orm";
import { WSOL_MINT } from "@launchpad/chain";
import {
  JobName, LedgerQuery, type JobRunList, type LedgerKind, type LedgerPage, type Revenue, type RevenueStreams,
} from "@launchpad/contract";
import { jobRuns, jobTransactions, launches, ledgerEntries } from "@launchpad/db";
import { operationsKey, type AppEnv } from "../env";
import { creatorMoney, unforwarded } from "../fees/creatorShares";
import { revenueAssets } from "../fees/ledger";
import { chainNets } from "../fees/budget";
import { chainFilter } from "../chains/filter";
import { toJobRun } from "../jobs";

/** Platform revenue in public: the Ledger, and totals per asset and per day. Every figure is a sum of Ledger entries. */
export const revenueRoutes = new Hono<AppEnv>();

const WSOL = WSOL_MINT.toBase58();
/** Days with revenue the answer carries: enough for the Stats page's 90-day average. */
const REVENUE_DAYS = 90;

type StreamSums = { platform_fee?: bigint; pool_fee?: bigint; fee_key?: bigint };

function streams(s: StreamSums): RevenueStreams {
  const platformFee = s.platform_fee ?? 0n;
  const poolFee = s.pool_fee ?? 0n;
  const feeKey = s.fee_key ?? 0n;
  return { platformFee: platformFee.toString(), poolFee: poolFee.toString(), feeKey: feeKey.toString(), total: (platformFee + poolFee + feeKey).toString() };
}

/**
 * `GET /v1/revenue`: what every chain collected (#254), per chain and asset, and the Platform Net per chain and
 * together; `?chain=` answers one chain's totals and days. An asset is keyed by its chain and its address, since an EVM
 * chain's native asset is the zero address on every one of them.
 */
revenueRoutes.get("/revenue", async (c) => {
  const db = c.get("db");
  const cfg = c.get("cfg");
  const only = chainFilter(c);
  const onChain = only ? sql`and ${ledgerEntries.chain} = ${only}` : sql``;
  const [totals, daily, creators, nets] = await Promise.all([
    db
      .select({ chain: ledgerEntries.chain, mint: ledgerEntries.assetMint, decimals: sql<number>`max(${ledgerEntries.assetDecimals})`, kind: ledgerEntries.kind, amount: sql<string>`sum(${ledgerEntries.amount})::text` })
      .from(ledgerEntries)
      .where(only ? sql`${ledgerEntries.chain} = ${only}` : undefined)
      .groupBy(ledgerEntries.chain, ledgerEntries.assetMint, ledgerEntries.kind),
    db.execute<{ day: string; chain: string; mint: string; decimals: number; kind: string; amount: string }>(sql`
      with daily as (
        select to_char(${ledgerEntries.blockTime} at time zone 'UTC', 'YYYY-MM-DD') as day, ${ledgerEntries.chain} as chain, ${ledgerEntries.assetMint} as mint,
          max(${ledgerEntries.assetDecimals}) as decimals, ${ledgerEntries.kind} as kind, sum(${ledgerEntries.amount})::text as amount
        from ${ledgerEntries}
        where ${ledgerEntries.kind} in ('platform_fee', 'pool_fee', 'fee_key') ${onChain}
        group by 1, 2, 3, 5
      )
      select * from daily where day in (select distinct day from daily order by day desc limit ${REVENUE_DAYS})`),
    creatorMoney(db),
    chainNets(db),
  ]);
  const asset = await revenueAssets(db, cfg.publicApiUrl, new Map([...totals, ...daily].map((r) => [r.mint, Number(r.decimals)])));
  // One key for an asset on one chain; Solana's mints keep their own (a Creator's share is Solana's alone).
  const keyOf = (chain: string, mint: string) => `${chain}|${mint}`;
  const parts = (key: string) => {
    const [chain, mint] = key.split("|") as [Chain, string];
    return { chain, mint };
  };

  const byAsset = new Map<string, StreamSums & { sweep?: bigint; graduation_fee?: bigint }>();
  for (const r of totals) byAsset.set(keyOf(r.chain, r.mint), { ...byAsset.get(keyOf(r.chain, r.mint)), [r.kind]: BigInt(r.amount) });
  const collected = (s: StreamSums) => (s.platform_fee ?? 0n) + (s.pool_fee ?? 0n) + (s.fee_key ?? 0n);
  // Solana first and SOL first within it, then by chain and ticker: amounts in different assets don't compare.
  const label = (key: string) => asset(parts(key).mint).symbol ?? parts(key).mint;
  const order = ([a]: [string, StreamSums], [b]: [string, StreamSums]) =>
    Number(parts(b).chain === "solana") - Number(parts(a).chain === "solana") || parts(a).chain.localeCompare(parts(b).chain) ||
    Number(b === keyOf("solana", WSOL)) - Number(a === keyOf("solana", WSOL)) || label(a).localeCompare(label(b), "en", { sensitivity: "base" }) || a.localeCompare(b);

  const days = new Map<string, Map<string, StreamSums>>();
  for (const r of daily) {
    const day = days.get(r.day) ?? new Map<string, StreamSums>();
    day.set(keyOf(r.chain, r.mint), { ...day.get(keyOf(r.chain, r.mint)), [r.kind]: BigInt(r.amount) });
    days.set(r.day, day);
  }

  const ops = operationsKey(c.env).publicKey;
  const res: Revenue = {
    operationsWallet: ops.toBase58(),
    treasury: cfg.treasury?.toBase58() ?? null,
    sweepThresholdLamports: cfg.sweepThresholdLamports.toString(),
    sweepFloatLamports: cfg.sweepFloatLamports.toString(),
    totals: [...byAsset.entries()]
      .filter(([, s]) => collected(s) > 0n)
      .sort(order)
      .map(([key, s]) => {
        const { chain, mint } = parts(key);
        // A Creator's share is collected and forwarded on Solana alone; on an EVM chain the hook credits it apart (ADR 0025).
        const solana = chain === "solana";
        return {
          chain, asset: asset(mint), ...streams(s), swept: (s.sweep ?? 0n).toString(),
          creatorForwarded: (solana ? (creators.get(mint)?.forwarded ?? 0n) : 0n).toString(), creatorPending: (solana ? unforwarded(creators, mint) : 0n).toString(),
          graduationFee: (s.graduation_fee ?? 0n).toString(),
        };
      }),
    days: [...days.entries()]
      .sort(([a], [b]) => b.localeCompare(a))
      .map(([day, assets]) => ({ day, assets: [...assets.entries()].sort(order).map(([key, s]) => ({ chain: parts(key).chain, asset: asset(parts(key).mint), ...streams(s) })) })),
    platformNet: { lamports: nets.together.toString(), chains: nets.chains.map((n) => ({ chain: n.chain as Chain, lamports: n.lamports.toString() })) },
  };
  return c.json(res);
});

revenueRoutes.get("/ledger", (c) => ledgerPage(c, null));

/**
 * `GET /v1/launches/:coin/ledger`: one coin's entries on the Ledger (#254), on either chain: what its Creator's
 * Credits, its Destination's work, its burns and its Support Liquidity moved, with the same paging as the Ledger.
 */
revenueRoutes.get("/launches/:mint/ledger", (c) => ledgerPage(c, c.req.param("mint")));

async function ledgerPage(c: Context<AppEnv>, launch: string | null) {
  const q = LedgerQuery.safeParse(c.req.query());
  if (!q.success) return c.json({ error: "invalid ledger query", details: q.error.issues }, 400);
  const { limit, before, kind, chain } = q.data;
  const db = c.get("db");
  const [slot, recorded, signature, index] = before?.split(".") ?? [];
  // Within a slot the entries list in the order the platform recorded them (two transactions of one job can land in
  // one slot, and a Graduation Fee is written in the slot of the collection it follows), which the signature alone would
  // leave to chance; the cursor carries that moment to the microsecond, as the same integer expression on both sides.
  const recordedMicros = sql`(extract(epoch from ${ledgerEntries.recordedAt}) * 1000000)::bigint`;
  const rows = await db
    .select({ e: ledgerEntries, recordedMicros: sql<string>`${recordedMicros}::text`, symbol: launches.symbol, name: launches.name })
    .from(ledgerEntries)
    .leftJoin(launches, eq(launches.mint, ledgerEntries.launchMint))
    .where(sql`true
      ${kind ? sql`and ${ledgerEntries.kind} = ${kind}` : sql``}
      ${chain ? sql`and ${ledgerEntries.chain} = ${chain}` : sql``}
      ${launch ? sql`and lower(${ledgerEntries.launchMint}) = lower(${launch})` : sql``}
      ${before ? sql`and (${ledgerEntries.slot}, ${recordedMicros}, ${ledgerEntries.signature}, ${ledgerEntries.eventIndex}) < (${Number(slot)}, ${recorded}::bigint, ${signature}, ${Number(index)})` : sql``}`)
    .orderBy(desc(ledgerEntries.slot), desc(recordedMicros), desc(ledgerEntries.signature), desc(ledgerEntries.eventIndex))
    .limit(limit + 1);
  const page = rows.slice(0, limit);
  const asset = await revenueAssets(db, c.get("cfg").publicApiUrl, new Map(page.map((r) => [r.e.assetMint, r.e.assetDecimals])));
  const last = page.at(-1);
  const res: LedgerPage = {
    entries: page.map(({ e, symbol, name }) => ({
      chain: e.chain as Chain,
      signature: e.signature,
      index: e.eventIndex,
      kind: e.kind as LedgerKind,
      asset: asset(e.assetMint),
      amount: e.amount,
      source: e.source,
      destination: e.destination,
      launch: e.launchMint && symbol !== null && name !== null ? { mint: e.launchMint, symbol, name } : null,
      slot: e.slot,
      time: e.blockTime.toISOString(),
    })),
    next: rows.length > limit && last ? `${last.e.slot}.${last.recordedMicros}.${last.e.signature}.${last.e.eventIndex}` : null,
  };
  return c.json(res);
}

/** Operator: recent runs of the scheduled jobs, and any transaction a job sent that has not settled yet. */
export const operatorJobRoutes = new Hono<AppEnv>();

operatorJobRoutes.get("/jobs", async (c) => {
  const job = c.req.query("job");
  const name = job === undefined ? null : JobName.safeParse(job);
  if (name && !name.success) return c.json({ error: "unknown job" }, 400);
  const db = c.get("db");
  const [runs, pending] = await Promise.all([
    db
      .select()
      .from(jobRuns)
      .where(name?.success ? eq(jobRuns.job, name.data) : undefined)
      .orderBy(desc(jobRuns.startedAt))
      .limit(100),
    db.select().from(jobTransactions).where(inArray(jobTransactions.status, ["pending"])).orderBy(desc(jobTransactions.createdAt)),
  ]);
  const res: JobRunList = {
    runs: runs.map(toJobRun),
    pending: pending.map((p) => ({ signature: p.signature, job: p.job, purpose: p.purpose, subject: p.subject, createdAt: p.createdAt.toISOString() })),
  };
  return c.json(res);
});
