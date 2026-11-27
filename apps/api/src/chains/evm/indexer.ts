import {
  ContractFunctionZeroDataError, createPublicClient, erc20Abi, http, isAddressEqual, parseAbi, parseEventLogs, type Address, type Hex, type PublicClient, type TransactionReceipt,
} from "viem";
import { and, count, eq, inArray, isNotNull, isNull, ne, sql } from "drizzle-orm";
import {
  checksum, decodeBurns, decodeGraduations, decodeLaunches, decodeTrades, EvmDecodeError, graduationQuote, NATIVE, poolsNamed, priceFromSqrtX96, priceFromStartTick, type ChainContracts,
  type LaunchEvent, type PoolInfo,
} from "@launchpad/evm";
import type { IndexerReplay, ReplayIndexer } from "@launchpad/contract";
import { chainCursors, evmQuoteAssets, graduations, indexerFailures, launches, launchMarkets, operatorAlerts, type Db } from "@launchpad/db";
import { insertTrade, openMarket } from "../../market";
import { writeBooks } from "./books";
import { withoutRpcUrl, type EvmChainConfig } from "./config";

/** ERC-8056's one required read (the knowledge base's `09-eip-8056.md`): a Stock Token's multiplier in force, 18 decimals. */
const scaledUiAbi = parseAbi(["function uiMultiplier() view returns (uint256)"]);

/**
 * A run's budget unless the deployment says otherwise (#279): 40 seconds of the minute between two runs, and 2,000 RPC
 * requests, a fifth of the 10,000 subrequests one invocation of the Worker may make, which the every-minute tick
 * shares with Solana's jobs. At 10 blocks a range that is up to 20,000 blocks a run against the 571 the chain makes
 * in a minute, so an hour's gap closes in two runs where the provider answers fast enough.
 */
const MAX_RUN_SECONDS = 40;
const MAX_REQUESTS_PER_RUN = 2_000;
/** Runs that fail on one transaction before it is set aside: one that can never be written, and one whose failure may be the provider's. */
const RETRY_RUNS = 3;
const RETRY_RUNS_UNCLEAR = 60;
/** Ranges read in a row before a halved range is doubled again, so a provider that refuses the wider one is asked it once in twenty. */
const GROW_AFTER_CLEAN_RANGES = 20;
/** The cursor is saved after any range that held a transaction of ours, and at least this often through empty ones. */
const SAVE_EVERY_RANGES = 20;
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
  /** Ledger entries written from our contracts' payments, burns and additions (#254). */
  recorded: number;
  /** How far behind the chain's head the run ended, in seconds, by the newest block it has written; null before its first. */
  secondsBehind: number | null;
  /** Transactions set aside on this run, each with why: tried on its runs, counted by the chain's alert, and the run went on. */
  skipped: { hash: string; error: string }[];
  /** The transaction the run stopped on, to be read again by the next run; null when it stopped for no transaction. */
  failed: { hash: string; attempts: number; error: string } | null;
  /** The `eth_getLogs` range the run ended on, which the next starts from. */
  logBlockRange: number;
  /** Whether the run stopped with blocks still to read: at its budget, at a rate limit, or on `failed`. */
  leftForLater: boolean;
  /** Whether the provider's rate limit ended the run. */
  rateLimited: boolean;
  /** The RPC requests the run made, retries included. */
  requests: number;
};

/** A pool of ours as the Indexer carries it through a run: what a trade needs to be read, and the price it moved from. */
type Pool = PoolInfo & { coinDecimals: number; quoteDecimals: number; price: number };

/** A client for the chain's RPC; `onRequest` is told of every HTTP request it makes, retries included. */
export const evmClient = (c: EvmChainConfig, onRequest?: () => void): PublicClient =>
  createPublicClient({ transport: http(c.rpcUrl, { retryCount: 2, ...(onRequest ? { onFetchRequest: onRequest } : {}) }) });

/** The first thing `test` finds in viem's chain of causes. */
function find<T>(e: unknown, test: (x: unknown) => T | undefined | false): T | undefined {
  for (let x: unknown = e, i = 0; x && i < 12; x = (x as { cause?: unknown }).cause, i++) {
    const found = test(x);
    if (found !== undefined && found !== false) return found;
  }
  return undefined;
}
const has = (e: unknown, test: (x: unknown) => boolean) => find(e, test) === true;

type NodeError = { code: number; message: string; data: unknown };

/**
 * The JSON-RPC error the node answered, under whatever viem made of it: viem reads `-32603` as a revert
 * (`ContractFunctionRevertedError`), so its own classes cannot say what the node said (#279). The innermost error
 * that carries a code is the node's own.
 */
function nodeError(e: unknown): NodeError | null {
  let last = null as NodeError | null;
  for (let x: unknown = e, i = 0; x && i < 12; x = (x as { cause?: unknown }).cause, i++) {
    const o = x as { code?: unknown; data?: unknown; details?: unknown; shortMessage?: unknown; message?: unknown; status?: unknown };
    if (typeof o.code === "number") last = { code: o.code, message: String(o.details ?? o.shortMessage ?? o.message ?? ""), data: o.data ?? last?.data };
    // A provider may answer its JSON-RPC error under an HTTP status, which viem keeps as text: Alchemy's free tier
    // refuses a wide `getLogs` with 400 and `{"code":-32600,"message":"... up to a 10 block range ..."}` (measured, #279).
    else if (typeof o.status === "number" && typeof o.details === "string") {
      const said = parsed(o.details) as { code?: unknown; message?: unknown; data?: unknown } | null;
      if (typeof said?.code === "number") last = { code: said.code, message: String(said.message ?? ""), data: said.data };
    }
  }
  return last;
}
const parsed = (text: string): unknown => {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
};
/** The HTTP status a request ended on, when the provider answered with one. */
const httpStatus = (e: unknown) => find(e, (x) => (typeof (x as { status?: unknown }).status === "number" ? (x as { status: number }).status : undefined));

/** Whether an error's data is a revert's: the bytes a contract reverted with, as a node carries them. */
const isRevertData = (data: unknown): boolean =>
  typeof data === "string" ? /^0x[0-9a-fA-F]{2,}$/.test(data) : typeof data === "object" && data !== null && isRevertData((data as { data?: unknown }).data);

/** The provider throttling us: HTTP 429, or its JSON-RPC error. The moment's, never a fact about a range or a transaction. */
const isRateLimited = (e: unknown) => {
  const node = nodeError(e);
  return httpStatus(e) === 429 || node?.code === 429 || /rate limit|too many requests|compute units|request rate|throttl/i.test(node?.message ?? "");
};
/**
 * A provider refusing a `getLogs` for its width or its answer's size, by what it says: Alchemy's "up to a 10 block
 * range" and "Log response size exceeded", Infura's "query returned more than 10000 results", "block range is too
 * wide", "ranges over 10000 blocks", "limited to a 10,000 range". Never by a code alone, and never a rate limit, whose
 * text also says "exceeded".
 */
const isRangeRefused = (e: unknown) =>
  !isRateLimited(e) &&
  /blocks? range|range (is )?too (large|wide)|ranges? over [\d,]+ blocks|more than [\d,]+ (results|logs)|response size|limited to (a )?[\d,]+/i.test(nodeError(e)?.message ?? "");
/** The node saying a call reverted: JSON-RPC code 3, or a revert's data with any code. Never `-32603` alone, which is the provider's own failure. */
export const nodeSaysRevert = (e: unknown) => {
  const node = nodeError(e);
  return node !== null && node.code !== 429 && (node.code === 3 || isRevertData(node.data));
};
/** A contract that answered a call with nothing, or with what its function's type cannot be read from (a `bytes32` symbol). */
const answeredUnreadably = (e: unknown) =>
  has(e, (x) => x instanceof ContractFunctionZeroDataError || /^(AbiDecoding|PositionOutOfBounds|InvalidBytesBoolean|IntegerOutOfRange|SizeOverflow)/.test(String((x as Error).name ?? "")));
/** A call the contract refused or answered unreadably: a fact about the contract, the same on every retry. */
const isContractsAnswer = (e: unknown) => nodeSaysRevert(e) || answeredUnreadably(e);
/**
 * Whether a transaction's failure is its own and would recur on every retry: the decoder's refusal, a contract's
 * answer, or Postgres refusing the data (a SQLSTATE of class 22, a data exception such as a NUL byte, or 23, an
 * integrity violation). Anything else (an internal error, a timeout, the database's connection) may be the moment's.
 */
const isPermanent = (e: unknown) =>
  has(e, (x) => x instanceof EvmDecodeError) || isContractsAnswer(e) || has(e, (x) => /^2[23]/.test(String((x as { code?: unknown }).code ?? "")));

/** Why a transaction failed, in one line an operator can act on, with the RPC's URL taken out. */
function reasonOf(e: unknown, c: EvmChainConfig) {
  const node = nodeError(e);
  const first = withoutRpcUrl(e, c).message.split("\n")[0]!;
  return (node ? `${first} (JSON-RPC ${node.code}: ${withoutRpcUrl(node.message, c).message.split("\n")[0]})` : first).slice(0, 400);
}

/**
 * A coin's or an asset's name or ticker as it is stored (#279): no control characters (Postgres refuses a NUL) and no
 * format characters, which hide or reorder what a page shows (a right-to-left override, a zero-width space or joiner,
 * a byte-order mark), no line or paragraph separator, none of the letters and symbols that draw as nothing (the Hangul
 * fillers, the blank Braille pattern), trimmed, at most `max` characters. It can come out empty.
 */
export const cleanText = (s: string, max: number) => [...s.replace(/[\p{Cc}\p{Cf}\p{Cs}\p{Co}\p{Cn}\p{Zl}\p{Zp}\u115F\u1160\u3164\uFFA0\u2800]/gu, "").trim()].slice(0, max).join("").trim();

/** A coin with no name or ticker a page can show goes by its address, shortened as an explorer shows one. */
const orAddress = (text: string, address: Address) => text || `${address.slice(0, 6)}...${address.slice(-4)}`;

/** What one reading of a chain shares: its client, the pools met so far, each block's time, and the budget. */
type Session = {
  db: Db;
  c: EvmChainConfig;
  client: PublicClient;
  contracts: ChainContracts;
  pools: Map<Hex, Pool>;
  /** Pool ids met that are not this deployment's: another hook's pools, which a router's path may cross. */
  notOurs: Set<Hex>;
  timeOf: (block: bigint) => Promise<Date>;
  /** The failures still open for this deployment, by transaction. */
  failures: Map<string, typeof indexerFailures.$inferSelect>;
  requests: { made: number };
  started: number;
  ranges: number;
  blocks: number;
  /** The `getLogs` range in use, the deployment's ceiling on it, and the ranges read in a row at this size. */
  range: number;
  ceiling: number;
  clean: number;
  counts: { launched: number; traded: number; burned: number; graduated: number; recorded: number };
  resolved: number;
};

async function session(db: Db, c: EvmChainConfig): Promise<Session & { head: { number: bigint; time: Date }; cursor: typeof chainCursors.$inferSelect | undefined }> {
  const requests = { made: 0 };
  const client = evmClient(c, () => void requests.made++);
  const started = Date.now();
  const head = await client.getBlock({ blockTag: "latest" });
  const times = new Map<bigint, Date>([[head.number, new Date(Number(head.timestamp) * 1000)]]);
  const [cursor] = await db.select().from(chainCursors).where(and(eq(chainCursors.chain, c.chain), eq(chainCursors.factory, c.factory))).limit(1);
  // The deployment's setting is the ceiling, and what was remembered under another setting is forgotten.
  const ceiling = c.logBlockRange ?? c.profile.logBlockRange;
  const remembered = cursor?.logBlockRangeSetting === ceiling ? cursor : null;
  const open = await db.select().from(indexerFailures).where(and(eq(indexerFailures.chain, c.chain), eq(indexerFailures.factory, c.factory), isNull(indexerFailures.resolvedAt)));
  return {
    db, c, client, requests, started, head: { number: head.number, time: times.get(head.number)! }, cursor,
    contracts: contractsOf(c),
    pools: new Map(), notOurs: new Set(),
    async timeOf(block) {
      let t = times.get(block);
      if (!t) times.set(block, (t = new Date(Number((await client.getBlock({ blockNumber: block })).timestamp) * 1000)));
      return t;
    },
    failures: new Map(open.map((f) => [f.transaction, f])),
    ranges: 0, blocks: 0, ceiling, range: remembered ? Math.min(ceiling, Math.max(1, remembered.logBlockRange ?? ceiling)) : ceiling, clean: remembered?.logCleanRanges ?? 0,
    counts: { launched: 0, traded: 0, burned: 0, graduated: 0, recorded: 0 }, resolved: 0,
  };
}

/** Our contracts on the deployment, as the decoder reads them: the Destinations' too, when the deployment names them (#254). */
export const contractsOf = (c: EvmChainConfig): ChainContracts => ({
  factory: c.factory, hook: c.hook, poolManager: c.profile.uniswap.poolManager, taxVault: c.taxVault, ...(c.destinations ? { destinations: Object.values(c.destinations) } : {}),
});

/** Whether a reading has spent its budget of seconds, requests or ranges. */
const spent = (s: Session) =>
  Date.now() - s.started >= (s.c.maxRunSeconds ?? MAX_RUN_SECONDS) * 1000 ||
  s.requests.made >= (s.c.maxRequestsPerRun ?? MAX_REQUESTS_PER_RUN) ||
  (s.c.maxRangesPerRun !== undefined && s.ranges >= s.c.maxRangesPerRun);

type Stop = "budget" | "rate limit" | "failed";

/**
 * Reads the blocks `from` to `to` a range at a time and hands every transaction that logged an event of ours to
 * `write`, block by block in the chain's order. It answers the last block it finished, and why it stopped short if it
 * did. The budget is looked at between ranges and between blocks, never inside one, and the first block of a reading
 * is always finished, so a reading always gets somewhere; `progress` is told of each range or block finished.
 */
async function scan(
  s: Session, from: number, to: number, write: (hash: Hex, block: number) => Promise<Stop | null>, progress: (through: number, wrote: boolean) => Promise<void>,
): Promise<{ through: number; stopped: Stop | null }> {
  let through = from - 1;
  for (let start = from; start <= to; ) {
    if (s.ranges > 0 && spent(s)) return { through, stopped: "budget" };
    const end = Math.min(to, start + s.range - 1);
    let logs;
    try {
      logs = await s.client.getLogs({ address: [s.c.factory, s.c.hook, s.c.taxVault, ...(s.contracts.destinations ?? [])], fromBlock: BigInt(start), toBlock: BigInt(end) });
    } catch (e) {
      if (isRateLimited(e)) return { through, stopped: "rate limit" };
      if (s.range > 1 && isRangeRefused(e)) {
        s.range = Math.max(1, Math.floor(s.range / 2));
        s.clean = 0;
        continue;
      }
      throw e;
    }
    s.ranges++;
    const byBlock = new Map<number, Hex[]>();
    for (const l of [...logs].sort((a, b) => Number(a.blockNumber! - b.blockNumber!) || a.logIndex! - b.logIndex!)) {
      const hashes = byBlock.get(Number(l.blockNumber)) ?? [];
      if (!hashes.includes(l.transactionHash!)) byBlock.set(Number(l.blockNumber), [...hashes, l.transactionHash!]);
    }
    for (const [block, hashes] of byBlock) {
      if (s.blocks > 0 && spent(s)) return { through: Math.max(through, block - 1), stopped: "budget" };
      for (const hash of hashes) {
        const stop = await write(hash, block);
        if (stop) return { through: Math.max(through, block - 1), stopped: stop };
      }
      s.blocks++;
      through = block;
      await progress(through, true);
    }
    through = end;
    if (++s.clean >= GROW_AFTER_CLEAN_RANGES && s.range < s.ceiling) {
      s.range = Math.min(s.ceiling, s.range * 2);
      s.clean = 0;
    }
    await progress(through, byBlock.size > 0);
    start = end + 1;
  }
  return { through, stopped: null };
}

const failureKey = (c: EvmChainConfig, hash: string) => and(eq(indexerFailures.chain, c.chain), eq(indexerFailures.factory, c.factory), eq(indexerFailures.transaction, hash));

/** Writes one transaction and counts what it wrote; a failure of its own that it had before is closed. */
async function writeCounted(s: Session, hash: Hex) {
  const written = await writeTransaction(s, hash);
  for (const k of ["launched", "traded", "burned", "graduated", "recorded"] as const) s.counts[k] += written[k];
  if (s.failures.has(hash)) {
    await s.db.update(indexerFailures).set({ resolvedAt: sql`now()` }).where(failureKey(s.c, hash));
    s.failures.delete(hash);
    s.resolved++;
  }
}

/**
 * One run of an EVM chain's Indexer (#252, #279): reads our factory's, hook's and Tax Vault's events from the block
 * after the last one it wrote, and a few before it again, to the chain's head less its finality depth, a bounded range
 * of blocks at a time, and writes each Launch, its Quote Asset, every trade in its pool and every Reward Burn, as
 * Solana's Indexer writes them (`insertTrade`), so the board, the trades and the candles read both chains alike. Each
 * transaction that logged an event of ours is read whole from its receipt, so a trade's wallet (the transaction's
 * sender) and the PoolManager's `Swap` beside our hook's fees come together.
 *
 * The cursor moves as blocks are written, so a run that dies reads from there again; every write is idempotent. A
 * transaction that fails stops the run, which reads it again on its next runs (by its hash when the cursor is already
 * past its block), and is set aside only after them (three when it can never be written, sixty when the failure may be
 * the provider's), counted by the chain's one alert until a replay writes it. A provider that refuses a range has it halved, and it grows back to the deployment's setting; a
 * rate limit ends the run where it is; a run stops at its budget of seconds and requests, between two blocks.
 */
export async function indexEvmChain(db: Db, c: EvmChainConfig): Promise<EvmIndexRun> {
  const s = await session(db, c);
  const target = Number(s.head.number) - c.profile.finalityDepth;
  const unread = s.cursor ? s.cursor.indexedBlock + 1 : c.fromBlock;
  // A node behind the one that gave the head answers a range with what it has, so the blocks read last are read again:
  // those that were within the finality depth and the re-read of the head when the last run read them. A run that
  // is catching up read old blocks, which no node lacks, and reads none of them twice.
  const fresh = s.cursor?.headBlock == null ? unread : s.cursor.headBlock - c.profile.finalityDepth - c.profile.rereadBlocks + 1;
  const from = Math.max(c.fromBlock, Math.min(unread, Math.max(unread - c.profile.rereadBlocks, fresh)));
  const run: EvmIndexRun = {
    chain: c.chain, from: unread <= target ? unread : null, to: null, head: Number(s.head.number), launched: 0, traded: 0, burned: 0, graduated: 0, recorded: 0, secondsBehind: null, skipped: [], failed: null,
    logBlockRange: s.range, leftForLater: false, rateLimited: false, requests: 0,
  };
  let indexed = unread - 1;
  let unsaved = 0;
  const saveCursor = (values: Partial<typeof chainCursors.$inferInsert>) =>
    db
      .insert(chainCursors)
      .values({ chain: c.chain, factory: c.factory, indexedBlock: indexed, ...values })
      .onConflictDoUpdate({ target: [chainCursors.chain, chainCursors.factory], set: { ...values, indexedBlock: sql`greatest(${chainCursors.indexedBlock}, ${indexed})` } });
  const rangeState = () => ({ logBlockRange: s.range, logBlockRangeSetting: s.ceiling, logCleanRanges: s.clean });

  /** One transaction: written, or its failure counted and the run stopped on it, or set aside after its runs. */
  const write = async (hash: Hex, block: number): Promise<Stop | null> => {
    // Set aside already: the run goes on without it until a replay writes it.
    if (s.failures.get(hash)?.setAsideAt) return null;
    try {
      await writeCounted(s, hash);
      return null;
    } catch (e) {
      if (isRateLimited(e)) return "rate limit";
      const error = reasonOf(e, c);
      const [failure] = await db
        .insert(indexerFailures)
        .values({ chain: c.chain, factory: c.factory, transaction: hash, block, error })
        .onConflictDoUpdate({
          target: [indexerFailures.chain, indexerFailures.factory, indexerFailures.transaction],
          set: { attempts: sql`${indexerFailures.attempts} + 1`, error, lastFailedAt: sql`now()`, resolvedAt: null },
        })
        .returning();
      s.failures.set(hash, failure!);
      if (failure!.attempts < (isPermanent(e) ? (c.retryRuns ?? RETRY_RUNS) : (c.retryRunsUnclear ?? RETRY_RUNS_UNCLEAR))) {
        run.failed = { hash, attempts: failure!.attempts, error };
        return "failed";
      }
      console.error(`${c.chain}: setting aside ${hash} after ${failure!.attempts} runs: ${error}`);
      const [aside] = await db.update(indexerFailures).set({ setAsideAt: sql`now()` }).where(failureKey(c, hash)).returning();
      s.failures.set(hash, aside!);
      run.skipped.push({ hash, error });
      return null;
    }
  };
  const hadFailures = s.failures.size > 0;
  try {
    // A transaction that failed while its block was read again sits behind the cursor, where no later scan meets it
    // (the blocks read again are the last run's, and that run moved on). Each one still being tried is read by its
    // hash before anything else, oldest first, and counts, stops the run and is set aside like any other.
    let stopped: Stop | null = null;
    const behind = [...s.failures.values()].filter((f) => !f.setAsideAt && f.block < unread).sort((a, b) => a.block - b.block);
    for (const f of behind) if ((stopped = await write(f.transaction as Hex, f.block))) break;
    // An old trade written late moves no market back (`insertTrade`), so the prices the blocks ahead start from are read again.
    if (behind.length > 0) s.pools.clear();
    if (!stopped) {
      const scanned = await scan(s, from, target, write, async (to, wrote) => {
        indexed = Math.max(indexed, to);
        if (!wrote && ++unsaved < SAVE_EVERY_RANGES) return;
        unsaved = 0;
        // The block's time is read once a run, at its end, so keeping up costs one `getLogs` a range and no more.
        await saveCursor({ indexedBlockTime: null, ...rangeState() });
      });
      indexed = Math.max(indexed, scanned.through);
      stopped = scanned.stopped;
    }
    run.leftForLater = stopped !== null;
    run.rateLimited = stopped === "rate limit";
  } finally {
    // What was read stays read, whatever ended the run, and so does what it learned about the provider's range.
    if (indexed >= unread) await saveCursor({ indexedBlockTime: null, ...rangeState() });
    else if (s.cursor) await db.update(chainCursors).set(rangeState()).where(and(eq(chainCursors.chain, c.chain), eq(chainCursors.factory, c.factory)));
  }
  Object.assign(run, s.counts, { logBlockRange: s.range, to: indexed >= unread ? indexed : null });
  const indexedTime = indexed >= unread && !run.rateLimited ? await s.timeOf(BigInt(indexed)) : (s.cursor?.indexedBlockTime ?? null);
  await saveCursor({
    ...(indexed >= unread && !run.rateLimited ? { indexedBlockTime: indexedTime } : {}),
    headBlock: Number(s.head.number), headBlockTime: s.head.time, checkedAt: new Date(), ...rangeState(),
  });
  run.secondsBehind = indexedTime ? Math.max(0, (s.head.time.getTime() - indexedTime.getTime()) / 1000) : null;
  await syncBehind(db, c, run.secondsBehind);
  if (!run.rateLimited) await refreshMultipliers(db, c, s.client).catch((e: unknown) => (isRateLimited(e) ? void (run.rateLimited = true) : Promise.reject(e)));
  if (hadFailures || run.skipped.length > 0) await syncAlert(db, c);
  run.requests = s.requests.made;
  return run;
}

/**
 * The operator's replay (#279): reads a transaction's block, or a range of blocks, again and writes what is missing,
 * a transaction set aside among it. A transaction that launched a coin is followed to where the Indexer has read, so
 * the trades it passed over while the coin was unknown are found. It never moves the cursor, and it stops at the same
 * budget as a run, answering where to go on from. Its caller holds the Indexer's lease: a run that met a coin's pool
 * before the replay wrote the coin would go on passing its trades over, past where the replay reads to.
 */
export async function replayEvmChain(db: Db, c: EvmChainConfig, ask: ReplayIndexer): Promise<IndexerReplay> {
  const s = await session(db, c);
  const read = s.cursor?.indexedBlock ?? c.fromBlock;
  let from: number;
  let to: number;
  if (ask.transaction !== undefined) {
    const receipt = await s.client.getTransactionReceipt({ hash: ask.transaction as Hex }).catch(() => null);
    if (!receipt) throw new ReplayRefused(`${c.profile.name} has no transaction ${ask.transaction}`);
    from = Number(receipt.blockNumber);
    to = decodeLaunches(receipt.logs, s.contracts).length > 0 ? Math.max(from, read) : from;
  } else {
    from = ask.fromBlock!;
    to = Math.min(ask.toBlock ?? Math.max(from, read), Number(s.head.number));
    if (from > to) throw new ReplayRefused(`block ${from} is past ${c.profile.name}'s head, ${Number(s.head.number)}`);
  }
  const failed: { hash: string; error: string }[] = [];
  const { through, stopped } = await scan(
    s, from, to,
    async (hash) => {
      try {
        await writeCounted(s, hash);
        return null;
      } catch (e) {
        if (isRateLimited(e)) return "rate limit";
        failed.push({ hash, error: reasonOf(e, c) });
        return null;
      }
    },
    async () => undefined,
  );
  if (s.resolved > 0) await syncAlert(db, c);
  return { chain: c.chain, from, to, next: stopped ? through + 1 : null, ...s.counts, resolved: s.resolved, failed };
}

/** A replay the operator asked for that cannot be made, with why. */
export class ReplayRefused extends Error {}

/** The failures still open on a deployment, newest first: those the Indexer is trying again, and those set aside. */
export const openFailures = (db: Db, c: EvmChainConfig) =>
  db
    .select()
    .from(indexerFailures)
    .where(and(eq(indexerFailures.chain, c.chain), eq(indexerFailures.factory, c.factory), isNull(indexerFailures.resolvedAt)))
    .orderBy(sql`${indexerFailures.block} desc`)
    .limit(500);

/**
 * The chain's one alert for what its Indexer has set aside (#279): raised, with the count, while any transaction is
 * set aside and not yet written, and resolved when none is. The transactions are `indexer_failures`' rows.
 */
async function syncAlert(db: Db, c: EvmChainConfig) {
  const [counted] = await db
    .select({ n: count() })
    .from(indexerFailures)
    .where(and(eq(indexerFailures.chain, c.chain), eq(indexerFailures.factory, c.factory), isNotNull(indexerFailures.setAsideAt), isNull(indexerFailures.resolvedAt)));
  const n = counted?.n ?? 0;
  const alert = and(eq(operatorAlerts.kind, "indexer_skipped"), eq(operatorAlerts.subject, c.chain));
  if (n === 0) return void (await db.update(operatorAlerts).set({ resolvedAt: sql`now()` }).where(and(alert, isNull(operatorAlerts.resolvedAt))));
  const message =
    `${c.profile.name}'s Indexer has set aside ${n} transaction${n === 1 ? "" : "s"} it could not write and went on without ${n === 1 ? "it" : "them"}. ` +
    `GET /v1/operator/indexer/failures?chain=${c.chain} lists ${n === 1 ? "it" : "them"}; POST /v1/operator/indexer/replay writes one again.`;
  await db
    .insert(operatorAlerts)
    .values({ kind: "indexer_skipped", subject: c.chain, message })
    .onConflictDoUpdate({
      target: [operatorAlerts.kind, operatorAlerts.subject],
      // Kept current with the count while it is open, and posted once; raised again after it was resolved.
      set: {
        message,
        raisedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.raisedAt} else now() end`,
        notifiedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.notifiedAt} else null end`,
        resolvedAt: null,
      },
    });
}

/** Ten minutes: how far behind its head a chain's Indexer may end a run before its `indexer_behind` alert is raised. */
const BEHIND_ALERT_SECONDS = 600;

/**
 * The chain's one alert for an Indexer that stays behind its head (#254): raised when a run ends further behind than
 * the deployment's setting, by the newest block it has written, and resolved by a run that ends within it. It covers
 * every stall that is not a failed run: a provider's rate limit that lasts (which ends each run as succeeded), a budget
 * too small for the chain's pace, a gap left by runs that did not happen. A run with no block written yet says nothing.
 */
async function syncBehind(db: Db, c: EvmChainConfig, secondsBehind: number | null) {
  if (secondsBehind === null) return;
  const limit = c.behindAlertSeconds ?? BEHIND_ALERT_SECONDS;
  const alert = and(eq(operatorAlerts.kind, "indexer_behind"), eq(operatorAlerts.subject, c.chain));
  if (secondsBehind <= limit) return void (await db.update(operatorAlerts).set({ resolvedAt: sql`now()` }).where(and(alert, isNull(operatorAlerts.resolvedAt))));
  const message =
    `${c.profile.name}'s Indexer ended its run ${Math.round(secondsBehind)} seconds behind the chain's head, past the ${limit} it may be: ` +
    `a rate limit that lasts, a budget too small for the chain's pace or runs that stopped. GET /v1/chains shows how far behind it is.`;
  await db
    .insert(operatorAlerts)
    .values({ kind: "indexer_behind", subject: c.chain, message })
    .onConflictDoUpdate({
      target: [operatorAlerts.kind, operatorAlerts.subject],
      set: {
        message,
        raisedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.raisedAt} else now() end`,
        notifiedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.notifiedAt} else null end`,
        resolvedAt: null,
      },
    });
}

/** The pools of this deployment among `ids`, read once a reading: what a receipt's trades need, with the price each last traded at. */
async function knowPools(s: Session, ids: Hex[]) {
  const unknown = ids.filter((id) => !s.pools.has(id) && !s.notOurs.has(id));
  if (unknown.length === 0) return;
  const rows = await s.db
    .select({ pool: launches.pool, coin: launches.mint, quote: launches.quoteMint, decimals: launches.decimals, quoteDecimals: evmQuoteAssets.decimals, price: launchMarkets.price })
    .from(launches)
    .innerJoin(evmQuoteAssets, and(eq(evmQuoteAssets.chain, launches.chain), eq(evmQuoteAssets.address, launches.quoteMint)))
    .leftJoin(launchMarkets, eq(launchMarkets.mint, launches.mint))
    // This deployment's alone: a factory deployed again never reads the old one's pools as its own.
    .where(and(eq(launches.chain, s.c.chain), eq(launches.factory, s.c.factory), inArray(launches.pool, unknown)));
  for (const r of rows) {
    s.pools.set(r.pool as Hex, {
      poolId: r.pool as Hex, coin: r.coin as Address, quote: r.quote as Address, quoteIsCurrency0: BigInt(r.quote) < BigInt(r.coin),
      coinDecimals: r.decimals, quoteDecimals: r.quoteDecimals, price: r.price ?? 0,
    });
  }
  for (const id of unknown) if (!s.pools.has(id)) s.notOurs.add(id);
}

/** Writes what one transaction did: its Launches, its trades and its Reward Burns. */
async function writeTransaction(s: Session, hash: Hex) {
  const { db, c, client, contracts, pools } = s;
  const written = { launched: 0, traded: 0, burned: 0, graduated: 0, recorded: 0 };
  const receipt = await client.getTransactionReceipt({ hash });
  if (receipt.status !== "success") return written;
  const blockTime = await s.timeOf(receipt.blockNumber);
  for (const e of decodeLaunches(receipt.logs, contracts)) written.launched += await writeLaunch(db, c, client, e, receipt, blockTime, pools);
  // The pools this transaction names that are this deployment's, the ones just launched among them.
  await knowPools(s, poolsNamed(receipt.logs, contracts));
  written.traded += await writeTrades(db, c, receipt, blockTime, contracts, pools);
  // One read of the supply for each pool burned in, whichever parts of the burn its events name.
  for (const poolId of new Set(decodeBurns(receipt.logs, contracts).map((b) => b.poolId))) {
    const pool = pools.get(poolId);
    if (!pool) continue;
    // The supply as it stands now. A coin is only ever burned, so the figure kept is the lowest read: a block read
    // again, or replayed long after, never puts back what a later burn took, and no past block's state is asked for,
    // which a node that is not an archive (and a fork, after a few blocks) no longer has (#279).
    const supply = await client.readContract({ address: pool.coin, abi: erc20Abi, functionName: "totalSupply" });
    await db.update(launches).set({ supply: sql`least(${launches.supply}, ${supply.toString()}::numeric)` }).where(and(eq(launches.chain, c.chain), eq(launches.mint, pool.coin)));
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
  // What the transaction paid, burned, added or handed on, and the tiers it raised, on the Ledger (#254).
  const books = new Map([...pools].map(([id, p]) => [id, { coin: p.coin, quote: p.quote, decimals: p.coinDecimals }]));
  written.recorded += await writeBooks(db, c, contracts, receipt, blockTime, books);
  return written;
}

/**
 * Writes a Launch and opens its market at the Listing's start price. Its Quote Asset is read from its contract the
 * first time a Launch pairs with it (the native asset from the chain's profile). The coin's name, ticker and decimals
 * are read from its contract as it stands, since nothing can change them, and its supply from the launch's own
 * `Transfer` events (what was minted less the seed's rounding dust, which the factory burns): no read of a past
 * block's state, so a launch can be read, and replayed, however old it is (#279).
 */
async function writeLaunch(db: Db, c: EvmChainConfig, client: PublicClient, e: LaunchEvent, receipt: TransactionReceipt, blockTime: Date, pools: Map<Hex, Pool>) {
  const quote = await quoteAsset(db, c, client, e.quote);
  const [name, symbol, decimals] = await Promise.all([
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "name" }),
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "symbol" }),
    client.readContract({ address: e.coin, abi: erc20Abi, functionName: "decimals" }),
  ]);
  const supply = supplyAfter(receipt, e.coin);
  const inserted = await db
    .insert(launches)
    .values({
      chain: c.chain,
      factory: c.factory,
      mint: e.coin,
      pool: e.poolId,
      creator: e.creator,
      quoteMint: e.quote,
      globalConfig: null,
      // The factory takes any string: a NUL would be refused by Postgres, a long one would fill the page, an override
      // would reorder it, and one with nothing to show goes by the coin's address.
      name: orAddress(cleanText(name, NAME_MAX), e.coin),
      symbol: orAddress(cleanText(symbol, SYMBOL_MAX), e.coin),
      // No metadata of ours until a launch is prepared through the API on an EVM chain (#253).
      metadataUri: "",
      decimals,
      supply: supply.toString(),
      // The Seed Position holds the whole supply but a Creator Lock (#244): there is no curve to sell from.
      totalBaseSell: (supply - (e.creatorLock?.amount ?? 0n)).toString(),
      // Where the hook credits the Creator's share (ADR 0025), and which of the deployment's Destinations that is (#254).
      creatorDestination: e.creatorDestination,
      earningsDestination: destinationKind(c, e.creatorDestination),
      // The Quote Asset that carries the coin to its Graduation Target, which an Active Day is a share of (ADR 0027).
      graduationQuote: graduationQuote(e.seedLiquidity, e.openSqrtPriceX96, e.graduationSqrtPriceX96, e.quoteIsCurrency0).toString(),
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

/** Which Creator Earnings Destination a Launch names (ADR 0011, #248): one of the deployment's three contracts, or a wallet. */
function destinationKind(c: EvmChainConfig, destination: Address): "wallet" | "holders" | "burn" | "liquidity" {
  for (const kind of ["holders", "burn", "liquidity"] as const) if (c.destinations && isAddressEqual(c.destinations[kind], destination)) return kind;
  return "wallet";
}

/** A coin's supply after the transaction that made it: what its `Transfer` events minted, less what they burned. */
function supplyAfter(receipt: TransactionReceipt, coin: Address) {
  let supply = 0n;
  for (const t of parseEventLogs({ abi: erc20Abi, eventName: "Transfer", logs: receipt.logs })) {
    if (!isAddressEqual(t.address, coin)) continue;
    if (isAddressEqual(t.args.from, NATIVE)) supply += t.args.value;
    if (isAddressEqual(t.args.to, NATIVE)) supply -= t.args.value;
  }
  return supply;
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
      // The Creator's Credit from the trade's Platform Fee, at the tier the coin held (#254, ADR 0027).
      creatorCredit: t.creatorCredit.toString(),
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

/**
 * A read that answers null when the contract refuses it or answers what cannot be read (it has no such function, or a
 * `bytes32` where a string is asked), and throws on anything else: a provider's failure is never a fact about the contract.
 */
const unlessReverted = <T>(read: Promise<T>) => read.catch((e: unknown) => (isContractsAnswer(e) ? null : Promise.reject(e)));

/** The chain's row for a Quote Asset, read from its contract (or the chain's profile, for the native asset) the first time. */
async function quoteAsset(db: Db, c: EvmChainConfig, client: PublicClient, address: Address) {
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
      chain: c.chain, address, symbol: symbol === null ? null : cleanText(symbol, SYMBOL_MAX) || null, name: name === null ? null : cleanText(name, NAME_MAX) || null, decimals,
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
