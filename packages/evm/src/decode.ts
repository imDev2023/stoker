import { decodeEventLog, isAddressEqual, type Address, type Hex, type Log } from "viem";
import { checksum } from "./chains";
import { iPoolManagerAbi, stokerFactoryAbi, stokerHookAbi, taxVaultAbi } from "./generated/abis";
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
  /** The tax terms the hook's `TaxTermsRegistered` wrote (#245): the launch type and its shares, fixed at launch. */
  launchType: "standard" | "reward" | "liquidity";
  taxBps: number;
  burnShareBps: number;
  liquidityShareBps: number;
  payoutAsset: "quote" | "coin";
  /** The Creator Lock the factory held out of the Seed Position (#244): its contract, its coins and its schedule; null without one. */
  creatorLock: { lock: Address; amount: bigint; cliff: number; unlock: number } | null;
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
  /** The coin's Reward Tax or Stoke Tax the swap paid, in the Quote Asset, to the Tax Vault (#245). */
  tax: bigint;
  /** The Opening Fee a buy in a Launch's first seconds paid, in the Quote Asset, to the Tax Vault (#246). */
  openingFee: bigint;
  /** Uniswap's protocol fee, at the rate the swap reports: in the Quote Asset on a buy, in coins on a sell. */
  protocolFee: bigint;
  sqrtPriceX96: bigint;
  /** Who called the PoolManager: a router for a wallet's trade, the Tax Vault for its own buys, the factory for a First Buy. */
  sender: Address;
  /** The `Swap` log's index in its block. */
  logIndex: number;
};

type Decoded =
  | { kind: "launched"; logIndex: number; args: { poolId: Hex; coin: Address; creator: Address; quote: Address; creatorDestination: Address; startTick: number; seedLiquidity: bigint; firstBuy: bigint; firstBuyCoins: bigint } }
  | { kind: "registered"; logIndex: number; args: { poolId: Hex; platformFeeBps: number; creatorShareBps: number; referrerFeeCapBps: number; quoteIsCurrency0: boolean; graduationMultiple: number } }
  | { kind: "fee"; logIndex: number; poolId: Hex; fee: bigint; creatorCredit: bigint }
  | { kind: "referrer"; logIndex: number; poolId: Hex; referrer: Address; fee: bigint }
  | { kind: "tax"; logIndex: number; poolId: Hex; tax: bigint }
  | { kind: "opening"; logIndex: number; poolId: Hex; fee: bigint }
  | { kind: "taxTerms"; logIndex: number; args: { poolId: Hex; launchType: number; taxBps: number; burnShareBps: number; liquidityShareBps: number; payoutAsset: number } }
  | { kind: "swap"; logIndex: number; poolId: Hex; sender: Address; amount0: bigint; amount1: bigint; sqrtPriceX96: bigint; feePips: number }
  | { kind: "burned"; logIndex: number; poolId: Hex; coinsBurned: bigint }
  | { kind: "locked"; logIndex: number; poolId: Hex; lock: Address; amount: bigint; cliff: number; unlock: number }
  | { kind: "graduated"; logIndex: number; poolId: Hex; graduatedAt: bigint };

/** A receipt the decoder cannot read as our contracts log a swap: it can never be written, whatever the retries. */
export class EvmDecodeError extends Error {}

export type ChainContracts = { factory: Address; hook: Address; poolManager: Address; taxVault: Address };

/** The events of ours in a receipt's logs, in log order. Another contract's log, or one of theirs we do not read, is passed over. */
function decodeLogs(logs: readonly Log[], c: ChainContracts): Decoded[] {
  const out: Decoded[] = [];
  for (const log of logs) {
    const logIndex = log.logIndex ?? 0;
    const topics = log.topics as [Hex, ...Hex[]];
    try {
      if (isAddressEqual(log.address, c.factory)) {
        const e = decodeEventLog({ abi: stokerFactoryAbi, data: log.data, topics });
        if (e.eventName === "CreatorLocked") out.push({ kind: "locked", logIndex, poolId: e.args.poolId, lock: checksum(e.args.lock), amount: e.args.amount, cliff: e.args.cliff, unlock: e.args.unlock });
        else if (e.eventName === "Launched") out.push({ kind: "launched", logIndex, args: { ...e.args, coin: checksum(e.args.coin), creator: checksum(e.args.creator), quote: checksum(e.args.quote), creatorDestination: checksum(e.args.creatorDestination) } });
      } else if (isAddressEqual(log.address, c.hook)) {
        const e = decodeEventLog({ abi: stokerHookAbi, data: log.data, topics });
        if (e.eventName === "Graduated") out.push({ kind: "graduated", logIndex, poolId: e.args.poolId, graduatedAt: e.args.graduatedAt });
        else if (e.eventName === "LaunchRegistered") out.push({ kind: "registered", logIndex, args: e.args });
        else if (e.eventName === "FeeCredited") out.push({ kind: "fee", logIndex, poolId: e.args.poolId, fee: e.args.fee, creatorCredit: e.args.creatorCredit });
        else if (e.eventName === "OpeningFeeBooked") out.push({ kind: "opening", logIndex, poolId: e.args.poolId, fee: e.args.fee });
        else if (e.eventName === "TaxBooked") out.push({ kind: "tax", logIndex, poolId: e.args.poolId, tax: e.args.tax });
        else if (e.eventName === "TaxTermsRegistered") out.push({ kind: "taxTerms", logIndex, args: e.args });
        else if (e.eventName === "ReferrerFeeCredited") out.push({ kind: "referrer", logIndex, poolId: e.args.poolId, referrer: checksum(e.args.referrer), fee: e.args.fee });
      } else if (isAddressEqual(log.address, c.taxVault)) {
        const e = decodeEventLog({ abi: taxVaultAbi, data: log.data, topics });
        // A burn's coins: the part the coin's own Reward Burn share bought, and the part someone funded (#248), each
        // logged for the one buy that made it.
        if (e.eventName === "RewardBurned" || e.eventName === "FundedBurned") out.push({ kind: "burned", logIndex, poolId: e.args.poolId, coinsBurned: e.args.coinsBurned });
      } else if (isAddressEqual(log.address, c.poolManager)) {
        const e = decodeEventLog({ abi: iPoolManagerAbi, data: log.data, topics });
        if (e.eventName === "Swap") out.push({ kind: "swap", logIndex, poolId: e.args.id, sender: checksum(e.args.sender), amount0: e.args.amount0, amount1: e.args.amount1, sqrtPriceX96: e.args.sqrtPriceX96, feePips: e.args.fee });
      }
    } catch {
      // An event of that contract this decoder does not read (its ABI has no entry for the topic).
    }
  }
  return out.sort((a, b) => a.logIndex - b.logIndex);
}

/** `StokerHook.LaunchType` and `StokerHook.PayoutAsset`, in their declared order. */
const LAUNCH_TYPES = ["standard", "reward", "liquidity"] as const;
const PAYOUT_ASSETS = ["quote", "coin"] as const;

/** The Launches a receipt's logs record: each factory `Launched` with its hook `LaunchRegistered`. */
export function decodeLaunches(logs: readonly Log[], c: ChainContracts): LaunchEvent[] {
  const events = decodeLogs(logs, c);
  const terms = new Map(events.flatMap((e) => (e.kind === "registered" ? [[e.args.poolId, e.args] as const] : [])));
  const taxes = new Map(events.flatMap((e) => (e.kind === "taxTerms" ? [[e.args.poolId, e.args] as const] : [])));
  const locks = new Map(events.flatMap((e) => (e.kind === "locked" ? [[e.poolId, e] as const] : [])));
  return events.flatMap((e) => {
    if (e.kind !== "launched") return [];
    const t = terms.get(e.args.poolId);
    const x = taxes.get(e.args.poolId);
    if (!t || !x) throw new EvmDecodeError(`launch of ${e.args.coin} has no LaunchRegistered and TaxTermsRegistered in its transaction`);
    return [{
      ...e.args, quoteIsCurrency0: t.quoteIsCurrency0, platformFeeBps: t.platformFeeBps, creatorShareBps: t.creatorShareBps, referrerFeeCapBps: t.referrerFeeCapBps,
      graduationMultiple: t.graduationMultiple, launchType: LAUNCH_TYPES[x.launchType]!, taxBps: x.taxBps, burnShareBps: x.burnShareBps,
      liquidityShareBps: x.liquidityShareBps, payoutAsset: PAYOUT_ASSETS[x.payoutAsset]!, logIndex: e.logIndex,
      creatorLock: ((l) => (l ? { lock: l.lock, amount: l.amount, cliff: l.cliff, unlock: l.unlock } : null))(locks.get(e.args.poolId)),
    }];
  });
}

/**
 * The trades in our pools a receipt's logs record. Within one `PoolManager.swap` the hook books its fees either before
 * the pool runs (an exact-in buy, an exact-out sell: `[ReferrerFeeCredited] FeeCredited [TaxBooked] Swap`) or after it
 * (an exact-in sell, an exact-out buy: `Swap [ReferrerFeeCredited] FeeCredited [TaxBooked]`), and nothing of ours is
 * logged in between, so read in order each `Swap` takes the fee group just before it if one is waiting, and otherwise
 * the one just after it. A swap that moved no Quote Asset at all (selling dust worth less than one raw unit) books no
 * fee and is the only swap with no group.
 */
export function decodeTrades(logs: readonly Log[], c: ChainContracts, pools: ReadonlyMap<Hex, PoolInfo>): TradeEvent[] {
  type Ours = Extract<Decoded, { kind: "swap" | "fee" | "referrer" | "tax" | "opening" }>;
  const events = decodeLogs(logs, c).filter(
    (e): e is Ours => (e.kind === "swap" || e.kind === "fee" || e.kind === "referrer" || e.kind === "tax" || e.kind === "opening") && pools.has(e.poolId),
  );
  type Group = { poolId: Hex; fee: bigint; creatorCredit: bigint; referrer: Address | null; referrerFee: bigint; tax: bigint; openingFee: bigint };
  type Swap = { poolId: Hex; sender: Address; logIndex: number; quoteDelta: bigint; coinDelta: bigint; sqrtPriceX96: bigint; feePips: number; group: Group | null };
  const swaps: Swap[] = [];
  let waiting: Group | null = null;
  let open: Swap | null = null;
  let last: Group | null = null;
  let pendingReferrer: { poolId: Hex; referrer: Address; fee: bigint } | null = null;
  const orphan = (what: string, poolId: Hex) => new EvmDecodeError(`${what} in ${poolId} has no ${what.startsWith("swap") ? "fee booked" : "swap"} beside it`);

  for (const e of events) {
    if (e.kind === "referrer") {
      pendingReferrer = { poolId: e.poolId, referrer: e.referrer, fee: e.fee };
      continue;
    }
    if (e.kind === "tax" || e.kind === "opening") {
      // The tax and the Opening Fee are booked right after `_book` in the same callback: they belong to the group just booked.
      if (!last || last.poolId !== e.poolId) throw orphan(e.kind === "tax" ? "tax" : "Opening Fee", e.poolId);
      if (e.kind === "tax") last.tax += e.tax;
      else last.openingFee += e.fee;
      continue;
    }
    if (e.kind === "fee") {
      const referrer = pendingReferrer?.poolId === e.poolId ? pendingReferrer : null;
      pendingReferrer = null;
      const group: Group = { poolId: e.poolId, fee: e.fee, creatorCredit: e.creatorCredit, referrer: referrer?.referrer ?? null, referrerFee: referrer?.fee ?? 0n, tax: 0n, openingFee: 0n };
      last = group;
      if (open && open.poolId === e.poolId) {
        open.group = group;
        open = null;
      } else {
        if (open) throw orphan(`swap at log ${open.logIndex}`, open.poolId);
        waiting = group;
      }
      continue;
    }
    if (open) throw orphan(`swap at log ${open.logIndex}`, open.poolId);
    const info = pools.get(e.poolId)!;
    const swap: Swap = {
      poolId: e.poolId, sender: e.sender, logIndex: e.logIndex, sqrtPriceX96: e.sqrtPriceX96, feePips: e.feePips, group: null,
      quoteDelta: info.quoteIsCurrency0 ? e.amount0 : e.amount1, coinDelta: info.quoteIsCurrency0 ? e.amount1 : e.amount0,
    };
    swaps.push(swap);
    last = null;
    if (waiting && waiting.poolId === e.poolId) {
      swap.group = waiting;
      waiting = null;
    } else if (swap.quoteDelta !== 0n) {
      if (waiting) throw orphan("fee", waiting.poolId);
      open = swap;
    }
  }
  if (open) throw orphan(`swap at log ${open.logIndex}`, open.poolId);
  if (waiting) throw orphan("fee", waiting.poolId);

  return swaps.map((s) => {
    const buy = s.coinDelta > 0n;
    const poolQuote = buy ? -s.quoteDelta : s.quoteDelta;
    const g = s.group;
    const taken = (g?.fee ?? 0n) + (g?.referrerFee ?? 0n) + (g?.tax ?? 0n) + (g?.openingFee ?? 0n);
    const coinAmount = buy ? s.coinDelta : -s.coinDelta;
    return {
      poolId: s.poolId, side: buy ? "buy" : "sell", coinAmount, quoteAmount: buy ? poolQuote + taken : poolQuote - taken,
      platformFee: g?.fee ?? 0n, creatorCredit: g?.creatorCredit ?? 0n, referrer: g?.referrer ?? null, referrerFee: g?.referrerFee ?? 0n, tax: g?.tax ?? 0n, openingFee: g?.openingFee ?? 0n,
      protocolFee: protocolFeeOn(buy ? poolQuote : coinAmount, s.feePips), sqrtPriceX96: s.sqrtPriceX96, sender: s.sender, logIndex: s.logIndex,
    };
  });
}

/**
 * The coins the Tax Vault burned in a receipt, by event: #245's Reward Burn (`RewardBurned`) and a burn someone funded
 * (#248, `FundedBurned`, a Creator Earnings Destination of the burn among them). One buy may log both, and each lowers
 * its coin's supply.
 */
export function decodeBurns(logs: readonly Log[], c: ChainContracts): { poolId: Hex; coinsBurned: bigint }[] {
  return decodeLogs(logs, c).flatMap((e) => (e.kind === "burned" ? [{ poolId: e.poolId, coinsBurned: e.coinsBurned }] : []));
}

/** The Graduations a receipt records (#244): a coin whose price held its Graduation Target for the Graduation Hold, once for good. */
export function decodeGraduations(logs: readonly Log[], c: ChainContracts): { poolId: Hex; graduatedAt: bigint }[] {
  return decodeLogs(logs, c).flatMap((e) => (e.kind === "graduated" ? [{ poolId: e.poolId, graduatedAt: e.graduatedAt }] : []));
}

/**
 * Every pool id a receipt's logs name (#279): the PoolManager's swaps, which are in any pool on the chain, and our own
 * contracts' events. The Indexer looks these up among its deployment's pools before it reads the receipt's trades, so
 * it never needs every pool in memory.
 */
export function poolsNamed(logs: readonly Log[], c: ChainContracts): Hex[] {
  const ids = new Set<Hex>();
  for (const e of decodeLogs(logs, c)) ids.add("poolId" in e ? e.poolId : e.args.poolId);
  return [...ids];
}
