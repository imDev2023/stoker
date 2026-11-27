import {
  ContractFunctionRevertedError, ContractFunctionZeroDataError, createPublicClient, erc20Abi, http, parseAbi, type Address, type Hex, type PublicClient,
  type TransactionReceipt,
} from "viem";
import { and, eq, ne, sql } from "drizzle-orm";
import {
  checksum, decodeBurns, decodeGraduations, decodeLaunches, decodeTrades, EvmDecodeError, NATIVE, priceFromSqrtX96, priceFromStartTick, type ChainContracts, type LaunchEvent,
  type PoolInfo,
} from "@launchpad/evm";
import { chainCursors, evmQuoteAssets, graduations, launches, launchMarkets, operatorAlerts, type Db } from "@launchpad/db";
import { insertTrade, openMarket } from "../../market";
import { preparedColumns } from "../../evm/prepared";
import type { EvmChainConfig } from "./config";

/** ERC-8056's one required read (the knowledge base's `09-eip-8056.md`): a Stock Token's multiplier in force, 18 decimals. */
const scaledUiAbi = parseAbi(["function uiMultiplier() view returns (uint256)"]);

/** How much one run does at most unless the deployment says otherwise: the rest waits for the next minute's run. */
const MAX_RANGES_PER_RUN = 60;
const MAX_RUN_SECONDS = 20;
/** The longest name and ticker an EVM coin is stored with; the factory takes any string. */
const NAME_MAX = 64;
const SYMBOL_MAX = 16;

export type EvmIndexRun = {
  chain: string;
  from: number | null;
  to: number | null;
  head: number;
  launched: number;
  traded: number;
  burned: number;
  graduated: number;
  /** Transactions that could never be written, each with why; each raised an `indexer_skipped` alert and the run went on. */
  skipped: { hash: string; error: string }[];
  /** The `eth_getLogs` range the run ended on, which the next starts from. */
  logBlockRange: number;
  /** Whether the run stopped at its budget with blocks still to read. */
  leftForLater: boolean;
};

/** A pool of ours as the Indexer carries it through a run: what a trade needs to be read, and the price it moved from. */
type Pool = PoolInfo & { coinDecimals: number; quoteDecimals: number; price: number };

export const evmClient = (c: EvmChainConfig): PublicClient => createPublicClient({ transport: http(c.rpcUrl, { retryCount: 2 }) });

/** Whether viem's error, or any error under it, is one of these. */
const has = (e: unknown, test: (x: unknown) => boolean) => {
  for (let x: unknown = e, i = 0; x && i < 10; x = (x as { cause?: unknown }).cause, i++) if (test(x)) return true;
  return false;
};
/** A call the contract refused or answered with nothing: a fact about the contract, the same on every retry. */
const isRevert = (e: unknown) => has(e, (x) => x instanceof ContractFunctionRevertedError || x instanceof ContractFunctionZeroDataError);
/** A provider refusing a `getLogs` range as too wide (Alchemy's free tier: -32600, "up to a 10 block range"). */
const isRangeRefused = (e: unknown) =>
  has(e, (x) => (x as { code?: unknown }).code === -32600 || /block range|range (is )?too (large|wide)|exceed/i.test(String((x as Error).message ?? "")));
/**
 * Whether a transaction's failure is its own and would recur on every retry: the decoder's refusal, a contract's revert,
 * or Postgres refusing the data (a SQLSTATE of class 22, a data exception such as a NUL byte, or 23, an integrity
 * violation). Anything else (the RPC, the network, the database's connection) is the moment's, and the run stops so
 * the next one reads the same blocks again.
 */
const isPermanent = (e: unknown) =>
  has(e, (x) => x instanceof EvmDecodeError || x instanceof ContractFunctionRevertedError || x instanceof ContractFunctionZeroDataError) ||
  has(e, (x) => /^2[23]/.test(String((x as { code?: unknown }).code ?? "")));

/** A coin's or an asset's name or ticker as it is stored: no control characters (Postgres refuses a NUL), at most `max` characters. */
export const cleanText = (s: string, max: number) =>
  [...s]
    .filter((ch) => {
      const code = ch.codePointAt(0)!;
      return code > 0x1f && code !== 0x7f;
    })
    .slice(0, max)
    .join("");

/**
 * One run of an EVM chain's Indexer (#252): reads our factory's, hook's and Tax Vault's events from the block after the
 * last one it wrote to the chain's head less its finality depth, a bounded range of blocks at a time, and writes each
 * Launch, its Quote Asset, every trade in its pool and every Reward Burn, as Solana's Indexer writes them
 * (`insertTrade`), so the board, the trades and the candles read both chains alike. Each transaction that logged an
 * event of ours is read whole from its receipt, so a trade's wallet (the transaction's sender) and the PoolManager's
 * `Swap` beside our hook's fees come together.
 *
 * The cursor moves after each range is written, so a run that dies reads that range again; every write is idempotent.
 * A transaction that can never be written is set aside with an operator alert and the run goes on; a provider that
 * refuses a range has it halved, and the size that worked is kept; a run stops at its budget of ranges and seconds.
 */
export async function indexEvmChain(db: Db, c: EvmChainConfig, client: PublicClient = evmClient(c)): Promise<EvmIndexRun> {
  const contracts: ChainContracts = { factory: c.factory, hook: c.hook, poolManager: c.profile.uniswap.poolManager, taxVault: c.taxVault };
  const head = await client.getBlock({ blockTag: "latest" });
  const target = Number(head.number) - c.profile.finalityDepth;
  const cursorKey = and(eq(chainCursors.chain, c.chain), eq(chainCursors.factory, c.factory));
  const [cursor] = await db.select().from(chainCursors).where(cursorKey).limit(1);
  const from = cursor ? cursor.indexedBlock + 1 : c.fromBlock;
  let range = cursor?.logBlockRange ?? c.logBlockRange ?? c.profile.logBlockRange;
  const run: EvmIndexRun = {
    chain: c.chain, from: from <= target ? from : null, to: null, head: Number(head.number), launched: 0, traded: 0, burned: 0, graduated: 0, skipped: [], logBlockRange: range,
    leftForLater: false,
  };
  const pools = await knownPools(db, c);
  const times = new Map<bigint, Date>([[head.number, new Date(Number(head.timestamp) * 1000)]]);
  const timeOf = async (block: bigint) => {
    let t = times.get(block);
    if (!t) times.set(block, (t = new Date(Number((await client.getBlock({ blockNumber: block })).timestamp) * 1000)));
    return t;
  };
  const saveCursor = (values: Partial<typeof chainCursors.$inferInsert>) =>
    db.insert(chainCursors).values({ chain: c.chain, factory: c.factory, indexedBlock: from - 1, ...values }).onConflictDoUpdate({ target: [chainCursors.chain, chainCursors.factory], set: values });

  const started = Date.now();
  const maxRanges = c.maxRangesPerRun ?? MAX_RANGES_PER_RUN;
  const maxMs = (c.maxRunSeconds ?? MAX_RUN_SECONDS) * 1000;
  let ranges = 0;
  for (let start = from; start <= target; ) {
    if (ranges >= maxRanges || Date.now() - started >= maxMs) {
      run.leftForLater = true;
      break;
    }
    const end = Math.min(target, start + range - 1);
    let logs;
    try {
      logs = await client.getLogs({ address: [c.factory, c.hook, c.taxVault], fromBlock: BigInt(start), toBlock: BigInt(end) });
    } catch (e) {
      if (range > 1 && isRangeRefused(e)) {
        range = Math.max(1, Math.floor(range / 2));
        continue;
      }
      throw e;
    }
    ranges++;
    for (const hash of [...new Set(logs.map((l) => l.transactionHash!))]) {
      try {
        const written = await writeTransaction(db, c, client, hash, contracts, pools, timeOf);
        run.launched += written.launched;
        run.traded += written.traded;
        run.burned += written.burned;
        run.graduated += written.graduated;
      } catch (e) {
        if (!isPermanent(e)) throw e;
        const error = (e as Error).message.split("\n")[0]!.slice(0, 300);
        run.skipped.push({ hash, error });
        await setAside(db, c, hash, error);
      }
    }
    // The block's time is read once a run, after the last range, so keeping up costs one `getLogs` a range and no more.
    await saveCursor({ indexedBlock: end, indexedBlockTime: null, logBlockRange: range });
    run.to = end;
    start = end + 1;
  }
  run.logBlockRange = range;
  if (run.to !== null) await saveCursor({ indexedBlock: run.to, indexedBlockTime: await timeOf(BigInt(run.to)) });
  await saveCursor({ headBlock: Number(head.number), headBlockTime: times.get(head.number)!, checkedAt: new Date(), logBlockRange: range });
  await refreshMultipliers(db, c, client);
  return run;
}

/** Writes what one transaction did: its Launches, its trades and its Reward Burns. */
async function writeTransaction(
  db: Db, c: EvmChainConfig, client: PublicClient, hash: Hex, contracts: ChainContracts, pools: Map<Hex, Pool>, timeOf: (block: bigint) => Promise<Date>,
) {
  const written = { launched: 0, traded: 0, burned: 0, graduated: 0 };
  const receipt = await client.getTransactionReceipt({ hash });
  if (receipt.status !== "success") return written;
  const blockTime = await timeOf(receipt.blockNumber);
  for (const e of decodeLaunches(receipt.logs, contracts)) written.launched += await writeLaunch(db, c, client, e, receipt, blockTime, pools);
  written.traded += await writeTrades(db, c, receipt, blockTime, contracts, pools);
  for (const b of decodeBurns(receipt.logs, contracts)) {
    const pool = pools.get(b.poolId);
    if (!pool) continue;
    // The supply after the burn, read at its own block, so a range read again writes the same figure.
    const supply = await client.readContract({ address: pool.coin, abi: erc20Abi, functionName: "totalSupply", blockNumber: receipt.blockNumber });
    await db.update(launches).set({ supply: supply.toString() }).where(and(eq(launches.chain, c.chain), eq(launches.mint, pool.coin)));
    written.burned++;
  }
  // Graduation (#244): recorded once by the hook and never undone; it moves nothing and takes no fee (ADR 0024, 0027).
  for (const g of decodeGraduations(receipt.logs, contracts)) {
    const pool = pools.get(g.poolId);
    if (!pool) continue;
    const inserted = await db
      .insert(graduations)
      .values({ chain: c.chain, mint: pool.coin, pool: g.poolId, signature: receipt.transactionHash, slot: Number(receipt.blockNumber), graduatedAt: new Date(Number(g.graduatedAt) * 1000) })
      .onConflictDoNothing()
      .returning({ mint: graduations.mint });
    written.graduated += inserted.length;
  }
  return written;
}

/** Raises the operator's alert for a transaction the Indexer could not write, and set aside to go on. */
async function setAside(db: Db, c: EvmChainConfig, hash: string, error: string) {
  console.error(`${c.chain}: setting aside ${hash}: ${error}`);
  await db
    .insert(operatorAlerts)
    .values({ kind: "indexer_skipped", subject: hash, message: `${c.profile.name}'s Indexer could not write transaction ${hash} and went on without it: ${error}` })
    .onConflictDoNothing();
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
      // The factory takes any string: a NUL would be refused by Postgres and a long one would fill the page.
      name: cleanText(name, NAME_MAX),
      symbol: cleanText(symbol, SYMBOL_MAX),
      // Its record when it was prepared through the API (#253), and the earlier coin it copies: ../../evm/prepared.ts.
      ...(await preparedColumns(db, c, e, { name, symbol }, blockTime)),
      decimals,
      supply: supply.toString(),
      // The Seed Position holds the whole supply but a Creator Lock (#244): there is no curve to sell from.
      totalBaseSell: (supply - (e.creatorLock?.amount ?? 0n)).toString(),
      // A Creator Lock as the factory held it out (ADR 0023, #244): the coins, and its cliff and unlock time from Graduation.
      ...(e.creatorLock ? { lockedAmount: e.creatorLock.amount.toString(), lockCliffSeconds: e.creatorLock.cliff, lockUnlockSeconds: e.creatorLock.unlock } : {}),
      // On an EVM chain the Graduation Target is a price (ADR 0024), written into the Launch's terms; Graduation is #244.
      graduationTarget: "0",
      // The tax terms the hook registered (#245): a Reward Launch's tax and shares, or a Stoke Launch's tax alone.
      ...taxColumns(e),
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

/** A Launch's tax terms as Solana's columns hold them (ADR 0006): none for a standard coin. */
function taxColumns(e: LaunchEvent): Partial<typeof launches.$inferInsert> {
  if (e.launchType === "standard") return {};
  if (e.launchType === "liquidity") return { taxKind: "liquidity", rewardTaxBps: e.taxBps };
  return { taxKind: "reward", rewardTaxBps: e.taxBps, rewardPayout: e.payoutAsset, rewardBurnBps: e.burnShareBps, rewardLiquidityBps: e.liquidityShareBps };
}

/**
 * Writes every trade in our pools the receipt records, each moving its coin's market (`insertTrade`). A trade is the
 * wallet's that sent the transaction, whatever router carried it, except the Tax Vault's own buys (the Reward Burn's, a
 * Payout Asset of the coin's), which anyone may set off and which are the vault's: the caller never receives a coin.
 */
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
      trader: t.sender === c.taxVault ? c.taxVault : checksum(receipt.from),
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

/** A read that answers null when the contract refuses it (it has no such function) and throws on anything else. */
const unlessReverted = <T>(read: Promise<T>) => read.catch((e: unknown) => (isRevert(e) ? null : Promise.reject(e)));

/** The chain's row for a Quote Asset, read from its contract (or the chain's profile, for the native asset) the first time. */
export async function quoteAsset(db: Db, c: EvmChainConfig, client: PublicClient, address: Address) {
  const key = and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, address));
  const [known] = await db.select().from(evmQuoteAssets).where(key).limit(1);
  if (known) return known;
  let row: typeof evmQuoteAssets.$inferInsert;
  if (address === NATIVE) {
    row = { chain: c.chain, address, symbol: c.profile.native.symbol, name: c.profile.native.name, decimals: c.profile.native.decimals, category: "native" };
  } else {
    const [symbol, name, decimals, multiplier] = await Promise.all([
      unlessReverted(client.readContract({ address, abi: erc20Abi, functionName: "symbol" })),
      unlessReverted(client.readContract({ address, abi: erc20Abi, functionName: "name" })),
      // An asset without decimals cannot be shown in any amount: its launch is set aside.
      client.readContract({ address, abi: erc20Abi, functionName: "decimals" }),
      readMultiplier(client, address),
    ]);
    // An asset is a Stock Token by what its contract does (ERC-8056's multiplier), never by its name; anything else waits
    // for the chain's Quote Registry job to classify it (#254).
    row = {
      chain: c.chain, address, symbol: symbol === null ? null : cleanText(symbol, SYMBOL_MAX), name: name === null ? null : cleanText(name, NAME_MAX), decimals,
      category: multiplier === null ? "community" : "tokenized_stock", multiplier: multiplier?.toString() ?? null, multiplierAt: multiplier === null ? null : new Date(),
    };
  }
  const [inserted] = await db.insert(evmQuoteAssets).values(row).onConflictDoNothing().returning();
  return inserted ?? (await db.select().from(evmQuoteAssets).where(key))[0]!;
}

/** A Stock Token's multiplier in force; null only when the contract has none (it refuses the call), never on a failed read. */
const readMultiplier = (client: PublicClient, address: Address) => unlessReverted(client.readContract({ address, abi: scaledUiAbi, functionName: "uiMultiplier" }));

/**
 * Reads every ERC-20 Quote Asset's multiplier again, so the one in force is answered beside every raw amount (an
 * issuer's corporate action changes it with no transfer; ADR 0028, story 31), and an asset first read without one is
 * asked again. One read per asset in use per run.
 */
async function refreshMultipliers(db: Db, c: EvmChainConfig, client: PublicClient) {
  const assets = await db
    .select({ address: evmQuoteAssets.address, category: evmQuoteAssets.category })
    .from(evmQuoteAssets)
    .where(and(eq(evmQuoteAssets.chain, c.chain), ne(evmQuoteAssets.address, NATIVE)));
  for (const a of assets) {
    const multiplier = await readMultiplier(client, a.address as Address);
    if (multiplier === null) continue;
    await db
      .update(evmQuoteAssets)
      .set({ multiplier: multiplier.toString(), multiplierAt: sql`now()`, ...(a.category === "community" ? { category: "tokenized_stock" as const } : {}) })
      .where(and(eq(evmQuoteAssets.chain, c.chain), eq(evmQuoteAssets.address, a.address)));
  }
}
