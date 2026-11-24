import { decodeEventLog, isAddressEqual, type Address, type Hex, type Log } from "viem";
import { checksum } from "./chains";
import { iPoolManagerAbi, stokerFactoryAbi, stokerHookAbi } from "./generated/abis";
import { protocolFeeOn } from "./math";

/**
 * The event decoder for one EVM chain (#252): what a transaction's receipt says about our Launches and their trades.
 * Every event comes from the contracts' own build (`generated/abis.ts`); nothing about them is typed here.
 */

/** A Launch as the factory's `Launched` and the hook's `LaunchRegistered` say it, from one launch transaction. */
export type LaunchEvent = {
  poolId: Hex;
  coin: Address;
  creator: Address;
  quote: Address;
  creatorDestination: Address;
  startTick: number;
  seedLiquidity: bigint;
  firstBuy: bigint;
  firstBuyCoins: bigint;
  quoteIsCurrency0: boolean;
  platformFeeBps: number;
  creatorShareBps: number;
  referrerFeeCapBps: number;
  graduationMultiple: number;
  logIndex: number;
};

/** What the Indexer knows about one of our pools, which a trade needs to be read. */
export type PoolInfo = { poolId: Hex; coin: Address; quote: Address; quoteIsCurrency0: boolean };

/**
 * One trade in one of our pools: the PoolManager's `Swap` with the fees the hook booked on it. The amounts are what the
 * trader's side of the swap moved: coins bought or sold, and the Quote Asset paid with every fee (a buy) or received
 * after every fee (a sell), raw units.
 */
export type TradeEvent = {
  poolId: Hex;
  side: "buy" | "sell";
  coinAmount: bigint;
  quoteAmount: bigint;
  /** The Platform Fee, the Creator's Credit among it. */
  platformFee: bigint;
  creatorCredit: bigint;
  referrer: Address | null;
  referrerFee: bigint;
  /** Uniswap's protocol fee, at the rate the swap reports: in the Quote Asset on a buy, in coins on a sell. */
  protocolFee: bigint;
  sqrtPriceX96: bigint;
  /** The `Swap` log's index in its block. */
  logIndex: number;
};

type Decoded =
  | { kind: "launched"; logIndex: number; args: { poolId: Hex; coin: Address; creator: Address; quote: Address; creatorDestination: Address; startTick: number; seedLiquidity: bigint; firstBuy: bigint; firstBuyCoins: bigint } }
  | { kind: "registered"; logIndex: number; args: { poolId: Hex; platformFeeBps: number; creatorShareBps: number; referrerFeeCapBps: number; quoteIsCurrency0: boolean; graduationMultiple: number } }
  | { kind: "fee"; logIndex: number; poolId: Hex; fee: bigint; creatorCredit: bigint }
  | { kind: "referrer"; logIndex: number; poolId: Hex; referrer: Address; fee: bigint }
  | { kind: "swap"; logIndex: number; poolId: Hex; amount0: bigint; amount1: bigint; sqrtPriceX96: bigint; feePips: number };

export type ChainContracts = { factory: Address; hook: Address; poolManager: Address };

/** The events of ours in a receipt's logs, in log order. Another contract's log, or one of theirs we do not read, is passed over. */
function decodeLogs(logs: readonly Log[], c: ChainContracts): Decoded[] {
  const out: Decoded[] = [];
  for (const log of logs) {
    const logIndex = log.logIndex ?? 0;
    const topics = log.topics as [Hex, ...Hex[]];
    try {
      if (isAddressEqual(log.address, c.factory)) {
        const e = decodeEventLog({ abi: stokerFactoryAbi, data: log.data, topics });
        if (e.eventName === "Launched") out.push({ kind: "launched", logIndex, args: { ...e.args, coin: checksum(e.args.coin), creator: checksum(e.args.creator), quote: checksum(e.args.quote), creatorDestination: checksum(e.args.creatorDestination) } });
      } else if (isAddressEqual(log.address, c.hook)) {
        const e = decodeEventLog({ abi: stokerHookAbi, data: log.data, topics });
        if (e.eventName === "LaunchRegistered") out.push({ kind: "registered", logIndex, args: e.args });
        else if (e.eventName === "FeeCredited") out.push({ kind: "fee", logIndex, poolId: e.args.poolId, fee: e.args.fee, creatorCredit: e.args.creatorCredit });
        else if (e.eventName === "ReferrerFeeCredited") out.push({ kind: "referrer", logIndex, poolId: e.args.poolId, referrer: checksum(e.args.referrer), fee: e.args.fee });
      } else if (isAddressEqual(log.address, c.poolManager)) {
        const e = decodeEventLog({ abi: iPoolManagerAbi, data: log.data, topics });
        if (e.eventName === "Swap") out.push({ kind: "swap", logIndex, poolId: e.args.id, amount0: e.args.amount0, amount1: e.args.amount1, sqrtPriceX96: e.args.sqrtPriceX96, feePips: e.args.fee });
      }
    } catch {
      // An event of that contract this decoder does not read (its ABI has no entry for the topic).
    }
  }
  return out.sort((a, b) => a.logIndex - b.logIndex);
}

/** The Launches a receipt's logs record: each factory `Launched` with its hook `LaunchRegistered`. */
export function decodeLaunches(logs: readonly Log[], c: ChainContracts): LaunchEvent[] {
  const events = decodeLogs(logs, c);
  const terms = new Map(events.flatMap((e) => (e.kind === "registered" ? [[e.args.poolId, e.args] as const] : [])));
  return events.flatMap((e) => {
    if (e.kind !== "launched") return [];
    const t = terms.get(e.args.poolId);
    if (!t) throw new Error(`launch of ${e.args.coin} has no LaunchRegistered in its transaction`);
    return [{ ...e.args, quoteIsCurrency0: t.quoteIsCurrency0, platformFeeBps: t.platformFeeBps, creatorShareBps: t.creatorShareBps, referrerFeeCapBps: t.referrerFeeCapBps, graduationMultiple: t.graduationMultiple, logIndex: e.logIndex }];
  });
}

/**
 * The trades in our pools a receipt's logs record. Within one `PoolManager.swap` the hook books its fees either before
 * the pool runs (an exact-in buy, an exact-out sell: `[ReferrerFeeCredited] FeeCredited Swap`) or after it (an exact-in
 * sell, an exact-out buy: `Swap [ReferrerFeeCredited] FeeCredited`), and nothing of ours is logged in between, so read in
 * order each `Swap` takes the fee group just before it if one is waiting, and otherwise the one just after it. A swap
 * that moved no Quote Asset at all (selling dust worth less than one raw unit) books no fee and is the only swap with
 * no group.
 */
export function decodeTrades(logs: readonly Log[], c: ChainContracts, pools: ReadonlyMap<Hex, PoolInfo>): TradeEvent[] {
  type Ours = Extract<Decoded, { kind: "swap" | "fee" | "referrer" }>;
  const events = decodeLogs(logs, c).filter((e): e is Ours => (e.kind === "swap" || e.kind === "fee" || e.kind === "referrer") && pools.has(e.poolId));
  type Group = { poolId: Hex; fee: bigint; creatorCredit: bigint; referrer: Address | null; referrerFee: bigint };
  const trades: TradeEvent[] = [];
  let waiting: Group | null = null;
  let pendingReferrer: { poolId: Hex; referrer: Address; fee: bigint } | null = null;
  let open: { trade: TradeEvent; info: PoolInfo; quoteDelta: bigint; coinDelta: bigint; feePips: number } | null = null;

  const settle = (o: NonNullable<typeof open>, g: Group | null) => {
    const buy = o.coinDelta > 0n;
    const poolQuote = buy ? -o.quoteDelta : o.quoteDelta;
    const taken = (g?.fee ?? 0n) + (g?.referrerFee ?? 0n);
    o.trade.side = buy ? "buy" : "sell";
    o.trade.coinAmount = buy ? o.coinDelta : -o.coinDelta;
    o.trade.quoteAmount = buy ? poolQuote + taken : poolQuote - taken;
    o.trade.platformFee = g?.fee ?? 0n;
    o.trade.creatorCredit = g?.creatorCredit ?? 0n;
    o.trade.referrer = g?.referrer ?? null;
    o.trade.referrerFee = g?.referrerFee ?? 0n;
    o.trade.protocolFee = protocolFeeOn(buy ? poolQuote : o.trade.coinAmount, o.feePips);
    trades.push(o.trade);
  };

  for (const e of events) {
    if (e.kind === "referrer") {
      pendingReferrer = { poolId: e.poolId, referrer: e.referrer, fee: e.fee };
      continue;
    }
    if (e.kind === "fee") {
      const referrer = pendingReferrer?.poolId === e.poolId ? pendingReferrer : null;
      pendingReferrer = null;
      const group: Group = { poolId: e.poolId, fee: e.fee, creatorCredit: e.creatorCredit, referrer: referrer?.referrer ?? null, referrerFee: referrer?.fee ?? 0n };
      if (open && open.trade.poolId === e.poolId) {
        settle(open, group);
        open = null;
      } else {
        if (open) throw new Error(`swap in ${open.trade.poolId} at log ${open.trade.logIndex} has no fee booked beside it`);
        waiting = group;
      }
      continue;
    }
    // A Swap.
    if (open) throw new Error(`swap in ${open.trade.poolId} at log ${open.trade.logIndex} has no fee booked beside it`);
    const info = pools.get(e.poolId)!;
    const quoteDelta = info.quoteIsCurrency0 ? e.amount0 : e.amount1;
    const coinDelta = info.quoteIsCurrency0 ? e.amount1 : e.amount0;
    const trade: TradeEvent = {
      poolId: e.poolId, side: "buy", coinAmount: 0n, quoteAmount: 0n, platformFee: 0n, creatorCredit: 0n, referrer: null, referrerFee: 0n, protocolFee: 0n,
      sqrtPriceX96: e.sqrtPriceX96, logIndex: e.logIndex,
    };
    const o = { trade, info, quoteDelta, coinDelta, feePips: e.feePips };
    if (waiting && waiting.poolId === e.poolId) {
      settle(o, waiting);
      waiting = null;
    } else if (quoteDelta === 0n) {
      settle(o, null);
    } else {
      if (waiting) throw new Error(`fee booked in ${waiting.poolId} has no swap beside it`);
      open = o;
    }
  }
  if (open) throw new Error(`swap in ${open.trade.poolId} at log ${open.trade.logIndex} has no fee booked beside it`);
  if (waiting) throw new Error(`fee booked in ${waiting.poolId} has no swap beside it`);
  return trades;
}
