import { createPublicClient, erc20Abi, http, parseAbi, type Address, type Hex, type PublicClient, type TransactionReceipt } from "viem";
import { and, eq, isNotNull, sql } from "drizzle-orm";
import {
  checksum, decodeLaunches, decodeTrades, NATIVE, priceFromSqrtX96, priceFromStartTick, type ChainContracts, type LaunchEvent, type PoolInfo,
} from "@launchpad/evm";
import { chainCursors, evmQuoteAssets, launches, launchMarkets, type Db } from "@launchpad/db";
import { insertTrade, openMarket } from "../../market";
import type { EvmChainConfig } from "./config";

/** ERC-8056's one required read (the knowledge base's `09-eip-8056.md`): a Stock Token's multiplier in force, 18 decimals. */
const scaledUiAbi = parseAbi(["function uiMultiplier() view returns (uint256)"]);

export type EvmIndexRun = { chain: string; from: number | null; to: number | null; head: number; launched: number; traded: number };

/** A pool of ours as the Indexer carries it through a run: what a trade needs to be read, and the price it moved from. */
type Pool = PoolInfo & { coinDecimals: number; quoteDecimals: number; price: number };

export const evmClient = (c: EvmChainConfig): PublicClient => createPublicClient({ transport: http(c.rpcUrl, { retryCount: 2 }) });

/**
 * One run of an EVM chain's Indexer (#252): reads our factory's and hook's events from the block after the last one it
 * wrote to the chain's head less its finality depth, a bounded range of blocks at a time, and writes each Launch, its
 * Quote Asset, and every trade in its pool as Solana's Indexer writes them (`insertTrade`), so the board, the trades and
 * the candles read both chains alike. Each transaction that logged an event of ours is read whole from its receipt, so
 * the trade's wallet (the transaction's sender) and the PoolManager's `Swap` beside our hook's fees come together.
 * The cursor moves only after a range is written, so a run that dies reads that range again; every write is idempotent.
 */
export async function indexEvmChain(db: Db, c: EvmChainConfig, client: PublicClient = evmClient(c)): Promise<EvmIndexRun> {
  const contracts: ChainContracts = { factory: c.factory, hook: c.hook, poolManager: c.profile.uniswap.poolManager };
  const head = await client.getBlock({ blockTag: "latest" });
  const target = Number(head.number) - c.profile.finalityDepth;
  const [cursor] = await db.select().from(chainCursors).where(eq(chainCursors.chain, c.chain)).limit(1);
  const from = cursor ? cursor.indexedBlock + 1 : c.fromBlock;
  const run: EvmIndexRun = { chain: c.chain, from: from <= target ? from : null, to: null, head: Number(head.number), launched: 0, traded: 0 };
  const pools = await knownPools(db, c);
  const times = new Map<bigint, Date>([[head.number, new Date(Number(head.timestamp) * 1000)]]);
  const timeOf = async (block: bigint) => {
    let t = times.get(block);
    if (!t) times.set(block, (t = new Date(Number((await client.getBlock({ blockNumber: block })).timestamp) * 1000)));
    return t;
  };

  for (let start = from; start <= target; start += c.profile.logBlockRange) {
    const end = Math.min(target, start + c.profile.logBlockRange - 1);
    const logs = await client.getLogs({ address: [c.factory, c.hook], fromBlock: BigInt(start), toBlock: BigInt(end) });
    const txs = [...new Set(logs.map((l) => l.transactionHash!))];
    for (const hash of txs) {
      const receipt = await client.getTransactionReceipt({ hash });
      if (receipt.status !== "success") continue;
      const blockTime = await timeOf(receipt.blockNumber);
      for (const e of decodeLaunches(receipt.logs, contracts)) run.launched += await writeLaunch(db, c, client, e, receipt, blockTime, pools);
      run.traded += await writeTrades(db, c, receipt, blockTime, contracts, pools);
    }
    const endTime = await timeOf(BigInt(end));
    await db
      .insert(chainCursors)
      .values({ chain: c.chain, indexedBlock: end, indexedBlockTime: endTime })
      .onConflictDoUpdate({ target: chainCursors.chain, set: { indexedBlock: end, indexedBlockTime: endTime } });
    run.to = end;
  }
  const headTime = times.get(head.number)!;
  await db
    .insert(chainCursors)
    .values({ chain: c.chain, indexedBlock: from - 1, headBlock: Number(head.number), headBlockTime: headTime, checkedAt: sql`now()` })
    .onConflictDoUpdate({ target: chainCursors.chain, set: { headBlock: Number(head.number), headBlockTime: headTime, checkedAt: sql`now()` } });
  await refreshMultipliers(db, c, client);
  return run;
}

/** Every pool of ours on the chain, with the price it last traded at. */
async function knownPools(db: Db, c: EvmChainConfig) {
  const rows = await db
    .select({ pool: launches.pool, coin: launches.mint, quote: launches.quoteMint, decimals: launches.decimals, quoteDecimals: evmQuoteAssets.decimals, price: launchMarkets.price })
    .from(launches)
    .innerJoin(evmQuoteAssets, and(eq(evmQuoteAssets.chain, launches.chain), eq(evmQuoteAssets.address, launches.quoteMint)))
    .leftJoin(launchMarkets, eq(launchMarkets.mint, launches.mint))
    .where(eq(launches.chain, c.chain));
  return new Map<Hex, Pool>(
    rows.map((r) => [
      r.pool as Hex,
      {
        poolId: r.pool as Hex, coin: r.coin as Address, quote: r.quote as Address, quoteIsCurrency0: BigInt(r.quote) < BigInt(r.coin),
        coinDecimals: r.decimals, quoteDecimals: r.quoteDecimals, price: r.price ?? 0,
      },
    ]),
  );
}

/**
 * Writes a Launch and opens its market at the Listing's start price. Its Quote Asset is read from its contract the
 * first time a Launch pairs with it (the native asset from the chain's profile), and the coin's name, ticker and
 * supply at the launch's own block: the supply is what the factory left after burning the seed's rounding dust.
 */
async function writeLaunch(db: Db, c: EvmChainConfig, client: PublicClient, e: LaunchEvent, receipt: TransactionReceipt, blockTime: Date, pools: Map<Hex, Pool>) {
  const quote = await quoteAsset(db, c, client, e.quote);
  const at = { blockNumber: receipt.blockNumber };
  const [name, symbol, decimals, supply] = await Promise.all([
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "name", ...at }),
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "symbol", ...at }),
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "decimals", ...at }),
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "totalSupply", ...at }),
  ]);
  const inserted = await db
    .insert(launches)
    .values({
      chain: c.chain,
      mint: e.coin,
      pool: e.poolId,
      creator: e.creator,
      quoteMint: e.quote,
      globalConfig: null,
      name,
      symbol,
      // No metadata of ours until a launch is prepared through the API on an EVM chain (#253).
      metadataUri: "",
      decimals,
      supply: supply.toString(),
      // The whole supply is the Seed Position's: there is no curve to sell from.
      totalBaseSell: supply.toString(),
      // On an EVM chain the Graduation Target is a price (ADR 0024), written into the Launch's terms; Graduation is #244.
      graduationTarget: "0",
      createdSignature: receipt.transactionHash,
      createdSlot: Number(receipt.blockNumber),
      createdAt: blockTime,
    })
    .onConflictDoNothing()
    .returning({ mint: launches.mint });
  const start = priceFromStartTick(e.startTick, decimals, quote.decimals);
  await openMarket(db, e.coin, start, Number(receipt.blockNumber), c.chain);
  if (!pools.has(e.poolId)) {
    pools.set(e.poolId, { poolId: e.poolId, coin: e.coin, quote: e.quote, quoteIsCurrency0: e.quoteIsCurrency0, coinDecimals: decimals, quoteDecimals: quote.decimals, price: start });
  }
  return inserted.length;
}

/** Writes every trade in our pools the receipt records, each moving its coin's market (`insertTrade`). */
async function writeTrades(db: Db, c: EvmChainConfig, receipt: TransactionReceipt, blockTime: Date, contracts: ChainContracts, pools: Map<Hex, Pool>) {
  let written = 0;
  for (const t of decodeTrades(receipt.logs, contracts, pools)) {
    const pool = pools.get(t.poolId)!;
    const priceAfter = priceFromSqrtX96(t.sqrtPriceX96, pool.quoteIsCurrency0, pool.coinDecimals, pool.quoteDecimals);
    const fresh = await insertTrade(db, {
      chain: c.chain,
      signature: receipt.transactionHash,
      eventIndex: t.logIndex,
      mint: pool.coin,
      // An EVM coin trades in its own pool from its first block.
      venue: "pool",
      trader: checksum(receipt.from),
      side: t.side,
      baseAmount: t.coinAmount.toString(),
      quoteAmount: t.quoteAmount.toString(),
      protocolFee: t.protocolFee.toString(),
      platformFee: t.platformFee.toString(),
      // The Creator's share is part of the Platform Fee, a Credit (ADR 0025): there is no Creator Fee on an EVM chain.
      creatorFee: "0",
      shareFee: t.referrerFee.toString(),
      referrer: t.referrer,
      priceBefore: pool.price,
      priceAfter,
      slot: Number(receipt.blockNumber),
      blockTime,
    });
    pool.price = priceAfter;
    if (fresh) written++;
  }
  return written;
}

/** The chain's row for a Quote Asset, read from its contract (or the chain's profile, for the native asset) the first time. */
async function quoteAsset(db: Db, c: EvmChainConfig, client: PublicClient, address: Address) {
  const [known] = await db.select().from(evmQuoteAssets).where(and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, address))).limit(1);
  if (known) return known;
  let row: typeof evmQuoteAssets.$inferInsert;
  if (address === NATIVE) {
    // The chain's native asset is the kind the ten categories call `sol` on Solana: the chain's own coin.
    row = { chain: c.chain, address, symbol: c.profile.native.symbol, name: c.profile.native.name, decimals: c.profile.native.decimals, category: "sol" };
  } else {
    const [symbol, name, decimals] = await Promise.all([
      client.readContract({ address, abi: erc20Abi, functionName: "symbol" }).catch(() => null),
      client.readContract({ address, abi: erc20Abi, functionName: "name" }).catch(() => null),
      client.readContract({ address, abi: erc20Abi, functionName: "decimals" }),
    ]);
    const multiplier = await readMultiplier(client, address);
    // An asset is a Stock Token by what its contract does (ERC-8056's multiplier), never by its name; anything else waits
    // for the chain's Quote Registry job to classify it (#254).
    row = {
      chain: c.chain, address, symbol, name, decimals, category: multiplier === null ? "community" : "tokenized_stock",
      multiplier: multiplier?.toString() ?? null, multiplierAt: multiplier === null ? null : new Date(),
    };
  }
  const [inserted] = await db.insert(evmQuoteAssets).values(row).onConflictDoNothing().returning();
  return inserted ?? (await db.select().from(evmQuoteAssets).where(and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, address))))[0]!;
}

const readMultiplier = (client: PublicClient, address: Address) =>
  client.readContract({ address, abi: scaledUiAbi, functionName: "uiMultiplier" }).catch(() => null);

/**
 * Reads every Stock Token's multiplier again, so the one in force is answered beside every raw amount: an issuer's
 * corporate action changes it with no transfer (ADR 0028, story 31). One read per asset in use per run.
 */
async function refreshMultipliers(db: Db, c: EvmChainConfig, client: PublicClient) {
  const scaled = await db.select({ address: evmQuoteAssets.address }).from(evmQuoteAssets).where(and(eq(evmQuoteAssets.chain, c.chain), isNotNull(evmQuoteAssets.multiplier)));
  for (const { address } of scaled) {
    const multiplier = await readMultiplier(client, address as Address);
    if (multiplier === null) continue;
    await db
      .update(evmQuoteAssets)
      .set({ multiplier: multiplier.toString(), multiplierAt: sql`now()` })
      .where(and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, address)));
  }
}
