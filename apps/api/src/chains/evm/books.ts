// The Ledger on an EVM chain (#254): every payment our contracts make, written by the chain's Indexer from the events
// of the transaction that made it, with the chain and its transaction hash, as Solana's Ledger is written from its
// transactions. Nothing here sends anything: the Keeper's calls are recorded when the Indexer reads them, like anyone's.
import type { Address, Hex, TransactionReceipt } from "viem";
import { and, asc, eq, lte, ne, sql } from "drizzle-orm";
import { decodeCredits, decodeEarningsApplied, decodeTierRaises, decodeVaultWork, NATIVE, type ChainContracts } from "@launchpad/evm";
import { creatorLadders, creatorTiers, evmQuoteAssets, graduations, launches, ledgerEntries, trades, type Db } from "@launchpad/db";
import type { EvmChainConfig } from "./config";

/** Entries of one log share its index this many times over: a Payout Call's payment to one owner can cover several coins. */
const PER_LOG = 100;
/** The burn address a coin's burned coins are recorded as sent to: `StokerCoin.burn` lowers the supply. */
const BURNED: Address = "0x0000000000000000000000000000000000000000";

type Pool = { coin: string; quote: string; decimals: number };
type Entry = typeof ledgerEntries.$inferInsert;

/**
 * Writes what one receipt's events say was paid, burned, added or handed on, and the Creator Tiers it raised. `pools`
 * are this deployment's pools the receipt names, as the Indexer knows them. Idempotent: an entry already recorded is
 * left as it is, so a block read again writes nothing twice. Answers the entries written.
 */
export async function writeBooks(db: Db, c: EvmChainConfig, contracts: ChainContracts, receipt: TransactionReceipt, blockTime: Date, pools: Map<Hex, Pool>) {
  const block = Number(receipt.blockNumber);
  const hash = receipt.transactionHash;
  const entries: Entry[] = [];
  const entry = (logIndex: number, n: number, e: Omit<Entry, "chain" | "signature" | "eventIndex" | "slot" | "blockTime">): Entry => ({
    chain: c.chain, signature: hash, eventIndex: logIndex * PER_LOG + n, slot: block, blockTime, ...e,
  });
  const decimals = await decimalsOf(db, c);

  for (const p of decodeCredits(receipt.logs, contracts)) {
    if (!p.paid) continue;
    entries.push(...(await creditEntries(db, c, receipt, p, await decimals(p.currency))).map((e, n) => entry(p.logIndex, n, e)));
  }

  const ours = new Set((c.destinations ? Object.values(c.destinations) : []).map((d) => d.toLowerCase()));
  for (const w of decodeVaultWork(receipt.logs, contracts)) {
    const pool = pools.get(w.poolId);
    if (!pool) continue;
    const quote = { assetMint: pool.quote, assetDecimals: await decimals(pool.quote as Address) };
    const coin = { assetMint: pool.coin, assetDecimals: pool.decimals };
    const base = { launchMint: pool.coin };
    const work = w.work;
    if (work.kind === "support") {
      // A piece of Support Liquidity is the coin's own tax and Opening Fees first and what was funded after; the funded
      // part is logged apart in the same call, so the coin's own part is the rest.
      const funded = decodeVaultWork(receipt.logs, contracts).find((o) => o.poolId === w.poolId && o.work.kind === "fundedSupport" && o.logIndex > w.logIndex);
      const own = work.quoteAdded - (funded && funded.work.kind === "fundedSupport" ? funded.work.quoteAdded : 0n);
      if (own > 0n) entries.push(entry(w.logIndex, 0, { kind: "support_liquidity", ...quote, amount: own.toString(), source: c.taxVault, destination: w.poolId, ...base }));
    } else if (work.kind === "fundedSupport") {
      entries.push(entry(w.logIndex, 0, { kind: "funded_liquidity", ...quote, amount: work.quoteAdded.toString(), source: c.taxVault, destination: w.poolId, ...base }));
    } else if (work.kind === "rewardBurn" || work.kind === "fundedBurn") {
      entries.push(entry(w.logIndex, 0, { kind: work.kind === "rewardBurn" ? "reward_burn" : "funded_burn", ...coin, amount: work.coinsBurned.toString(), source: c.taxVault, destination: BURNED, ...base }));
    } else if (!ours.has(work.funder.toLowerCase())) {
      // A Destination's funding is its `EarningsApplied`, recorded below: the same movement is written once.
      entries.push(entry(w.logIndex, 0, { kind: work.kind === "burnFunded" ? "burn_funded" : "support_funded", ...quote, amount: work.amount.toString(), source: work.funder, destination: c.taxVault, ...base }));
    }
  }

  for (const a of decodeEarningsApplied(receipt.logs, contracts)) {
    const pool = pools.get(a.poolId);
    if (!pool) continue;
    // The holders' Destination hands the earnings to the Distributor, the burn's and the liquidity's to the Tax Vault.
    const to = a.destination.toLowerCase() === c.destinations?.holders.toLowerCase() ? c.distributor : c.taxVault;
    entries.push(entry(a.logIndex, 0, { kind: "earnings_applied", assetMint: a.asset, assetDecimals: await decimals(a.asset), amount: a.amount.toString(), source: a.destination, destination: to, launchMint: pool.coin }));
  }

  const written = entries.length ? (await db.insert(ledgerEntries).values(entries).onConflictDoNothing().returning({ signature: ledgerEntries.signature })).length : 0;
  await writeTierRaises(db, c, contracts, receipt, blockTime, pools);
  return written;
}

/** How to read amounts of each asset on the chain: the native asset by the chain's profile, an ERC-20 by its row. */
async function decimalsOf(db: Db, c: EvmChainConfig) {
  const known = new Map<string, number>([[NATIVE.toLowerCase(), c.profile.native.decimals]]);
  return async (asset: Address) => {
    const key = asset.toLowerCase();
    if (!known.has(key)) {
      const [row] = await db.select({ decimals: evmQuoteAssets.decimals }).from(evmQuoteAssets).where(and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, asset))).limit(1);
      // A Credit is only ever in a Quote Asset some Launch of ours is paired with, which the Indexer wrote first.
      if (!row) throw new Error(`a Credit in ${asset}, which no Launch on ${c.chain} is paired with`);
      known.set(key, row.decimals);
    }
    return known.get(key)!;
  };
}

/**
 * One owner's Credit in one asset, paid by a Payout Call, as Ledger entries (ADR 0025): the hook keeps one Credit per
 * owner and asset, whatever earned it, so the payment is split by what the indexed trades credited the owner and the
 * Ledger has not shown paid yet: its Creator shares first, coin by coin, oldest coin first, then its Referrer Fees, and
 * what is left is the platform's share, booked to the Admin of the moment. A trade in a later transaction of the same
 * block may already be counted; whatever such a split moves comes back on the owner's next payment.
 */
async function creditEntries(db: Db, c: EvmChainConfig, receipt: TransactionReceipt, p: { owner: Address; currency: Address; amount: bigint }, assetDecimals: number) {
  const block = Number(receipt.blockNumber);
  const out: Omit<Entry, "chain" | "signature" | "eventIndex" | "slot" | "blockTime">[] = [];
  const paidEntry = (kind: string, amount: bigint, launchMint: string | null) =>
    out.push({ kind, assetMint: p.currency, assetDecimals, amount: amount.toString(), source: c.hook, destination: p.owner, launchMint });
  const before = and(eq(ledgerEntries.chain, c.chain), eq(ledgerEntries.destination, p.owner), eq(ledgerEntries.assetMint, p.currency), ne(ledgerEntries.signature, receipt.transactionHash));
  let left = p.amount;

  const coins = await db
    .select({
      mint: launches.mint,
      credited: sql<string>`coalesce((select sum(${trades.creatorCredit}) from ${trades} where ${trades.chain} = ${c.chain} and ${trades.mint} = ${launches.mint} and ${trades.slot} <= ${block}), 0)::text`,
      paid: sql<string>`coalesce((select sum(le.amount) from ${ledgerEntries} le where le.chain = ${c.chain} and le.kind = 'creator_credit' and le.launch_mint = ${launches.mint} and le.destination = ${p.owner} and le.asset_mint = ${p.currency} and le.signature <> ${receipt.transactionHash}), 0)::text`,
    })
    .from(launches)
    .where(and(eq(launches.chain, c.chain), eq(launches.factory, c.factory), eq(launches.creatorDestination, p.owner), eq(launches.quoteMint, p.currency)))
    .orderBy(asc(launches.createdSlot), asc(launches.mint));
  for (const coin of coins) {
    const owed = BigInt(coin.credited) - BigInt(coin.paid);
    if (owed <= 0n || left === 0n) continue;
    const part = owed < left ? owed : left;
    paidEntry("creator_credit", part, coin.mint);
    left -= part;
  }

  if (left > 0n) {
    const [referred] = await db
      .select({ credited: sql<string>`coalesce(sum(${trades.shareFee}), 0)::text` })
      .from(trades)
      .innerJoin(launches, eq(launches.mint, trades.mint))
      .where(and(eq(trades.chain, c.chain), eq(launches.factory, c.factory), eq(trades.referrer, p.owner), eq(launches.quoteMint, p.currency), lte(trades.slot, block)));
    const [paid] = await db.select({ amount: sql<string>`coalesce(sum(${ledgerEntries.amount}), 0)::text` }).from(ledgerEntries).where(and(before, eq(ledgerEntries.kind, "referrer_fee")));
    const owed = BigInt(referred!.credited) - BigInt(paid!.amount);
    if (owed > 0n) {
      const part = owed < left ? owed : left;
      paidEntry("referrer_fee", part, null);
      left -= part;
    }
  }
  // Every Credit is a Creator's, a referrer's or the platform's: the rest went to the Admin the trades booked it to.
  if (left > 0n) paidEntry("platform_fee", left, null);
  return out;
}

/**
 * A Creator Tier the ladder key raised (#248, ADR 0027), recorded as Solana's are (`creator_tiers`), once per coin and
 * tier: with the coin's Active Days as the `evm-ladder` job last counted them and the ladder version in force when the
 * raise landed. A raise past one tier records each tier it passed.
 */
async function writeTierRaises(db: Db, c: EvmChainConfig, contracts: ChainContracts, receipt: TransactionReceipt, blockTime: Date, pools: Map<Hex, Pool>) {
  const raises = decodeTierRaises(receipt.logs, contracts);
  if (!raises.length) return;
  const [ladder] = await db
    .select({ version: creatorLadders.version })
    .from(creatorLadders)
    .where(sql`${creatorLadders.version} = 1 or ${creatorLadders.effectiveAt} <= ${blockTime.toISOString()}::timestamptz`)
    .orderBy(sql`${creatorLadders.version} desc`)
    .limit(1);
  for (const r of raises) {
    const pool = pools.get(r.poolId);
    if (!pool) continue;
    const [g] = await db.select({ days: graduations.activeDays }).from(graduations).where(and(eq(graduations.chain, c.chain), eq(graduations.mint, pool.coin))).limit(1);
    const rows = [];
    for (let tier = r.fromTier + 1; tier <= r.toTier; tier++) {
      rows.push({ chain: c.chain, mint: pool.coin, tier, activeDays: g?.days ?? 0, ladderVersion: ladder?.version ?? 1, reachedSlot: Number(receipt.blockNumber), reachedAt: blockTime });
    }
    if (rows.length) await db.insert(creatorTiers).values(rows).onConflictDoNothing();
  }
}

