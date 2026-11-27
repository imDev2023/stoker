// Volume Rebates on an EVM chain (ADR 0021, ADR 0030, #254): the Budget Table's `rebates` row of that chain's own net,
// paid back to the traders whose Platform Fees made it, on the chain of their trades and in its native asset. A week is
// settled as Solana's are (`rebates/engine.ts`): its trades' fees valued in SOL, the pot the row's budget or the row's
// share of those fees where that is less, split by each trader's part. Each rebate is turned into the native asset at
// the settlement's price, and paid by the Keeper once a wallet's waiting rebates reach the minimum: marked `sending`
// with the transaction's hash before it is sent, `paid` and on the Ledger once it has landed.
import { and, desc, eq, gte, inArray, lt, notInArray, or, sql } from "drizzle-orm";
import type { Address, Hex } from "viem";
import { BUDGET_TOTAL_BPS } from "@launchpad/contract";
import { NATIVE, stokerKeysAbi } from "@launchpad/evm";
import { evmJobTransactions, evmRebates, evmRebateWeeks, launches, ledgerEntries, trades, type Db } from "@launchpad/db";
import type { Bindings, Config } from "../../env";
import { budgets, budgetVersions, split } from "../../fees/budget";
import { allPrices, evmRawFor, priceKey, worthOn, type QuotePrice } from "../../fees/value";
import { dueWeeks, earningSpans, weekIndex, weekStart } from "../../rebates/engine";
import { ourAddresses, type EvmChainConfig } from "./config";
import { evmClient } from "./indexer";
import { keeperMinBalanceOf, perChain } from "./keeper";
import { EvmSender } from "./sender";

/** Weeks settled per run, as on Solana: one in the ordinary course, more after the job has been down. */
const WEEKS_PER_RUN = 8;
/** Wallets paid per run: one transfer each. */
const MAX_PAYMENTS = 100;

export type EvmRebatesRun = {
  chain: string;
  settled: { weekStart: string; traders: number; potLamports: string; credited: string }[];
  paid: { wallet: string; amount: string; hash: Hex }[];
  /** Why a week or a payment waits, when one does. */
  waits: string[];
};

/** One run on every EVM chain (job `evm-rebates`), on the Fee Collector's cron after Solana's `rebates`. */
export const runEvmRebates = (env: Bindings, cfg: Config, db: Db, now = new Date()) => perChain(env, (c) => rebateChain(db, cfg, c, now));

async function rebateChain(db: Db, cfg: Config, c: EvmChainConfig, now: Date): Promise<EvmRebatesRun> {
  const run: EvmRebatesRun = { chain: c.chain, settled: [], paid: [], waits: [] };
  const client = evmClient(c);
  // Nothing is paid on what the chain could still take back: the clock is its `safe` block's where its profile says so.
  const safe = await client.getBlock({ blockTag: c.profile.paysAtSafe ? "safe" : "latest" });
  const clock = new Date(Math.min(now.getTime(), Number(safe.timestamp) * 1000));
  const sender = c.keeperKey ? new EvmSender(db, c, c.keeperKey, "evm-rebates") : null;
  if (sender) await settlePayments(db, c, sender);

  const weekMs = cfg.rebateWeekSeconds * 1000;
  const spans = earningSpans(split(await budgetVersions(db), clock).inEffect);
  const [latest] = await db.select({ start: evmRebateWeeks.weekStart }).from(evmRebateWeeks).where(eq(evmRebateWeeks.chain, c.chain)).orderBy(desc(evmRebateWeeks.weekStart)).limit(1);
  const due = dueWeeks(spans, latest ? weekIndex(latest.start.getTime(), weekMs) : null, clock.getTime(), weekMs, WEEKS_PER_RUN);
  // The platform's own wallets earn nothing, as on Solana: our contracts, the Admin and the Keeper.
  const admin = await client.readContract({ address: c.keys, abi: stokerKeysAbi, functionName: "admin" });
  const excluded = [...ourAddresses(c), admin.toLowerCase(), ...(sender ? [sender.address.toLowerCase()] : [])];
  for (const index of due) {
    const prices = await allPrices(db);
    const native = prices.get(priceKey(c.chain, NATIVE));
    if (!native) {
      run.waits.push(`week ${new Date(weekStart(index, weekMs)).toISOString()} waits for a price of ${c.profile.native.symbol}`);
      break;
    }
    run.settled.push(await settleWeek(db, cfg, c, spans, index, weekMs, excluded, prices, native, clock));
  }
  if (!sender) {
    run.waits.push(`no Keeper key: the secret ${c.chain.toUpperCase()}_KEEPER_KEY is not set, so nothing is paid`);
    return run;
  }
  await pay(db, cfg, c, sender, run);
  return run;
}

/** The rebates given on the chain and not paid yet, in lamports at the latest price: no later week may give them again. */
async function owedLamports(db: Db, c: EvmChainConfig, prices: Map<string, QuotePrice>) {
  const [row] = await db
    .select({ amount: sql<string>`coalesce(sum(${evmRebates.amount}), 0)::text` })
    .from(evmRebates)
    .where(and(eq(evmRebates.chain, c.chain), inArray(evmRebates.status, ["waiting", "sending"])));
  return worthOn(c.chain, NATIVE, BigInt(row!.amount), prices) ?? 0n;
}

/** Settles one week: what the chain's trades in it paid, the pot, each trader's rebate in the native asset; all in one write. */
async function settleWeek(
  db: Db, cfg: Config, c: EvmChainConfig, spans: ReturnType<typeof earningSpans>, index: number, weekMs: number, excluded: string[], prices: Map<string, QuotePrice>,
  native: QuotePrice, clock: Date,
) {
  const start = weekStart(index, weekMs);
  const end = start + weekMs;
  const earning = spans.map((s) => ({ from: Math.max(s.from, start), to: Math.min(s.to, end), shareBps: s.shareBps })).filter((s) => s.from < s.to);
  const capBps = earning.reduce((most, s) => Math.max(most, s.shareBps), 0);
  const paid = earning.length
    ? await db
        .select({ wallet: trades.trader, mint: launches.quoteMint, amount: sql<string>`sum(${trades.platformFee})::text` })
        .from(trades)
        .innerJoin(launches, eq(launches.mint, trades.mint))
        .where(and(
          eq(trades.chain, c.chain), eq(launches.factory, c.factory),
          or(...earning.map((s) => and(gte(trades.blockTime, new Date(s.from)), lt(trades.blockTime, new Date(s.to))))),
          notInArray(sql`lower(${trades.trader})`, excluded),
        ))
        .groupBy(trades.trader, launches.quoteMint)
    : [];
  const feesOf = new Map<string, bigint>();
  for (const p of paid) {
    const worth = worthOn(c.chain, p.mint, BigInt(p.amount), prices) ?? 0n;
    if (worth > 0n) feesOf.set(p.wallet, (feesOf.get(p.wallet) ?? 0n) + worth);
  }
  const fees = [...feesOf.values()].reduce((a, b) => a + b, 0n);
  const { rows } = await budgets(db, clock, c.chain);
  const owed = await owedLamports(db, c, prices);
  const budget = rows.rebates.available > owed ? rows.rebates.available - owed : 0n;
  const cap = (fees * BigInt(capBps)) / BigInt(BUDGET_TOTAL_BPS);
  const pot = fees === 0n ? 0n : budget < cap ? budget : cap;
  const shares = [...feesOf]
    .map(([wallet, f]) => ({ wallet, fees: f, amount: evmRawFor((pot * f) / fees, native) ?? 0n }))
    .filter((s) => s.amount > 0n)
    .sort((a, b) => a.wallet.localeCompare(b.wallet));
  const credited = shares.reduce((sum, s) => sum + s.amount, 0n);
  await db.transaction(async (tx) => {
    await tx.insert(evmRebateWeeks).values({
      chain: c.chain, weekStart: new Date(start), weekEnd: new Date(end), capBps, budget: budget.toString(), fees: fees.toString(), pot: pot.toString(), priceSol: native.priceSol,
      traders: shares.length, credited: credited.toString(),
    });
    if (shares.length) await tx.insert(evmRebates).values(shares.map((s) => ({ chain: c.chain, weekStart: new Date(start), wallet: s.wallet, fees: s.fees.toString(), amount: s.amount.toString() })));
  });
  return { weekStart: new Date(start).toISOString(), traders: shares.length, potLamports: pot.toString(), credited: credited.toString() };
}

/** Pays every wallet whose waiting rebates reach the minimum, one transfer each, while the Keeper keeps its least. */
async function pay(db: Db, cfg: Config, c: EvmChainConfig, sender: EvmSender, run: EvmRebatesRun) {
  const native = (await allPrices(db)).get(priceKey(c.chain, NATIVE));
  const least = native ? (evmRawFor(cfg.rebateMinLamports, native) ?? 0n) : null;
  if (least === null) return void run.waits.push(`payments wait for a price of ${c.profile.native.symbol}`);
  const total = sql<string>`sum(${evmRebates.amount})`;
  const due = await db
    .select({ wallet: evmRebates.wallet, amount: sql<string>`${total}::text` })
    .from(evmRebates)
    .where(and(eq(evmRebates.chain, c.chain), eq(evmRebates.status, "waiting")))
    .groupBy(evmRebates.wallet)
    .having(sql`${total} >= ${least.toString()}::numeric`)
    .orderBy(desc(total))
    .limit(MAX_PAYMENTS);
  let balance = await sender.client.getBalance({ address: sender.address });
  for (const d of due) {
    const amount = BigInt(d.amount);
    if (balance - amount < keeperMinBalanceOf(c)) {
      run.waits.push(`the Keeper holds ${balance}, too little to pay ${d.wallet} ${amount} and keep its least`);
      break;
    }
    const call = { to: d.wallet as Address, data: "0x" as Hex, value: amount };
    const mine = and(eq(evmRebates.chain, c.chain), eq(evmRebates.wallet, d.wallet), eq(evmRebates.status, "waiting"));
    const receipt = await sender.send("rebate", d.wallet, call, await sender.simulate(call, []), async (hash) => {
      await db.update(evmRebates).set({ status: "sending", transaction: hash }).where(mine);
    });
    if (receipt) await settleOne(db, c, sender, receipt.transactionHash, receipt.status === "success" ? "landed" : "failed");
    if (receipt?.status === "success") run.paid.push({ wallet: d.wallet, amount: d.amount, hash: receipt.transactionHash });
    balance = await sender.client.getBalance({ address: sender.address });
  }
}

/** Every rebate payment left waiting by an earlier run, settled by its transaction's end. */
async function settlePayments(db: Db, c: EvmChainConfig, sender: EvmSender) {
  await sender.settle();
  const sending = await db
    .selectDistinct({ hash: evmRebates.transaction, status: evmJobTransactions.status })
    .from(evmRebates)
    .innerJoin(evmJobTransactions, and(eq(evmJobTransactions.chain, evmRebates.chain), eq(evmJobTransactions.hash, evmRebates.transaction)))
    .where(and(eq(evmRebates.chain, c.chain), eq(evmRebates.status, "sending")));
  for (const s of sending) if (s.status !== "pending") await settleOne(db, c, sender, s.hash as Hex, s.status);
}

/** One payment's end: its rebates paid and on the Ledger once it landed, or waiting again when it never can. */
async function settleOne(db: Db, c: EvmChainConfig, sender: EvmSender, hash: Hex, status: string) {
  const carried = and(eq(evmRebates.chain, c.chain), eq(evmRebates.transaction, hash), eq(evmRebates.status, "sending"));
  if (status !== "landed") return void (await db.update(evmRebates).set({ status: "waiting", transaction: null }).where(carried));
  const receipt = await sender.client.getTransactionReceipt({ hash });
  const block = await sender.client.getBlock({ blockNumber: receipt.blockNumber });
  const time = new Date(Number(block.timestamp) * 1000);
  const [paid] = await db.select({ wallet: evmRebates.wallet, amount: sql<string>`sum(${evmRebates.amount})::text` }).from(evmRebates).where(carried).groupBy(evmRebates.wallet);
  if (!paid) return;
  await db.transaction(async (tx) => {
    await tx.insert(ledgerEntries).values({
      chain: c.chain, signature: hash, eventIndex: 0, kind: "rebate", assetMint: NATIVE, assetDecimals: c.profile.native.decimals, amount: paid.amount,
      source: sender.address, destination: paid.wallet, launchMint: null, slot: Number(receipt.blockNumber), blockTime: time,
    }).onConflictDoNothing();
    await tx.update(evmRebates).set({ status: "paid", paidAt: time }).where(carried);
  });
}
