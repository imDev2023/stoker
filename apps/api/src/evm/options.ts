import { and, eq } from "drizzle-orm";
import { ContractFunctionRevertedError, ContractFunctionZeroDataError, type Abi, type Address } from "viem";
import { REWARD_BURN_SHARES, REWARD_SHARES_MAX_BPS, REWARD_TAX_RATES, type EvmLaunchOptions, type EvmQuoteOption } from "@launchpad/contract";
import { checksum, COIN_DECIMALS, COIN_SUPPLY, NATIVE, openingValue, priceFromStartTick, quoteRegistryAbi, stokerFactoryAbi } from "@launchpad/evm";
import { evmQuoteAssets, type Db } from "@launchpad/db";
import { quoteAsset } from "../chains/evm/indexer";
import { evmQuoteRef } from "../chains/evm/quotes";
import { reading, type EvmContext } from "./context";

/** One Listing as the Quote Registry answers it (`IQuoteListings.Listing`). */
export type Listing = { listed: boolean; startTick: number; graduationMultiple: number; referrerFeeCapBps: number };

/** The factory's own settings and bounds, fixed at its deployment: every Launch on it takes them. */
export type FactorySettings = {
  platformFeeBps: number;
  tickSpacing: number;
  openingFee: { startBps: number; seconds: number };
  creatorLock: { maxBps: number; minSeconds: number; maxPartSeconds: number };
};

/** A listed Quote Asset: what the form shows of it, and its start tick, which the seed's arithmetic needs whole. */
export type ListedQuote = { option: EvmQuoteOption; startTick: number };

/** What one chain offers a Launch, as last read from its contracts. */
export type ChainOptions = { body: EvmLaunchOptions; settings: FactorySettings; listed: Map<Address, ListedQuote> };

/**
 * How long an answer is kept in the Worker's memory: each one is a read of the chain, the page is public, and a form
 * asks again as the Creator changes it. A Listing written or withdrawn shows within these seconds; a launch's own
 * prepare never trusts the kept answer for whether an asset is listed (`listedQuote` with `fresh`).
 */
const CACHE_MS = 5_000;
const kept = new Map<string, { at: number; loading: Promise<ChainOptions> }>();

/** A contract's own refusal of a read (it has no such function), which is a fact about it; anything else is the moment's. */
const refused = (e: unknown) => {
  for (let x: unknown = e, i = 0; x && i < 10; x = (x as { cause?: unknown }).cause, i++) {
    if (x instanceof ContractFunctionRevertedError || x instanceof ContractFunctionZeroDataError) return true;
  }
  return false;
};

function quoteOption(row: typeof evmQuoteAssets.$inferSelect, listing: Listing): ListedQuote {
  return {
    startTick: listing.startTick,
    option: {
      ...evmQuoteRef(row),
      native: row.address === NATIVE,
      listing: {
        startPrice: priceFromStartTick(listing.startTick, COIN_DECIMALS, row.decimals),
        openingValue: openingValue(listing.startTick).toString(),
        graduationMultiple: listing.graduationMultiple,
        referrerFeeCapBps: listing.referrerFeeCapBps,
      },
    },
  };
}

/**
 * A listed asset as the API knows it. Its row is the Indexer's own (`quoteAsset`): read from its contract the first
 * time anything asks, kept in `evm_quote_assets`, and its multiplier read again on every Indexer run, so the form, a
 * coin's page and the chain's naming rules (a Stock Token's ticker is refused as a coin's) all say the same of it.
 * Only an asset the registry lists is ever stored this way, and only the Admin lists one. Null for an asset whose
 * contract cannot be read as an asset (no decimals).
 */
async function knownAsset(db: Db, x: EvmContext, address: Address, known?: typeof evmQuoteAssets.$inferSelect) {
  if (known) return known;
  try {
    return await quoteAsset(db, x.config, x.client, address);
  } catch (e) {
    if (!refused(e)) throw e;
    console.error(`${x.config.chain}: the listed asset ${address} cannot be read as an asset, so the launch form leaves it out`);
    return null;
  }
}

async function load(db: Db, x: EvmContext): Promise<ChainOptions> {
  const { config, client } = x;
  const profile = config.profile;
  const rows = await db.select().from(evmQuoteAssets).where(eq(evmQuoteAssets.chain, config.chain));
  const byAddress = new Map(rows.map((r) => [r.address as Address, r]));
  // The registry has no list to read, only `listingOf`: the native asset, every asset the API has met, and the
  // deployment's own candidates are asked about, and only those it lists are answered. It alone gates a Launch.
  const candidates = [...new Set<Address>([NATIVE, ...byAddress.keys(), ...(config.quotes ?? [])])];
  // The factory's settings and bounds, then each candidate's Listing: one `eth_call` through Multicall3 however many
  // candidates there are (no size limit on the batch), so every figure is of one block. The calls are of two contracts
  // and a length known only here, so the answers are read by place.
  const views = ["platformFeeBps", "tickSpacing", "openingFeeStartBps", "openingFeeDuration", "MAX_CREATOR_LOCK_BPS", "MIN_CREATOR_LOCK_TIME", "MAX_CREATOR_LOCK_PART"] as const;
  const contracts: { address: Address; abi: Abi; functionName: string; args?: readonly unknown[] }[] = [
    ...views.map((functionName) => ({ address: config.factory, abi: stokerFactoryAbi as Abi, functionName })),
    ...candidates.map((quote) => ({ address: config.registry, abi: quoteRegistryAbi as Abi, functionName: "listingOf", args: [quote] })),
  ];
  const answers: unknown[] = await client.multicall({ allowFailure: false, multicallAddress: profile.multicall3, batchSize: 0, contracts });
  const [platformFeeBps, tickSpacing, startBps, seconds, maxBps, minSeconds, maxPartSeconds] = answers.slice(0, views.length).map(Number) as [number, number, number, number, number, number, number];
  const listings = answers.slice(views.length) as Listing[];

  const listed = new Map<Address, ListedQuote>();
  await Promise.all(
    candidates.map(async (address, i) => {
      const listing = listings[i]!;
      if (!listing.listed) return;
      const row = await knownAsset(db, x, address, byAddress.get(address));
      if (row) listed.set(address, quoteOption(row, listing));
    }),
  );
  // The native asset first, then by ticker.
  const quotes = [...listed.values()]
    .map((l) => l.option)
    .sort((a, b) => Number(b.native) - Number(a.native) || (a.symbol ?? "￿").localeCompare(b.symbol ?? "￿") || a.mint.localeCompare(b.mint));
  const settings: FactorySettings = { platformFeeBps, tickSpacing, openingFee: { startBps, seconds }, creatorLock: { maxBps, minSeconds, maxPartSeconds } };
  const body: EvmLaunchOptions = {
    chain: config.chain,
    name: profile.name,
    chainId: profile.chainId,
    explorer: profile.explorer,
    wallet: {
      chainId: `0x${profile.chainId.toString(16)}`,
      chainName: profile.name,
      nativeCurrency: profile.native,
      rpcUrls: [profile.walletRpcUrl],
      blockExplorerUrls: [profile.explorer],
    },
    native: profile.native,
    stockName: profile.stockName,
    contracts: {
      factory: config.factory, hook: config.hook, registry: config.registry, taxVault: config.taxVault,
      // The factory's verified source on the chain's explorer: the link of the unaudited statement (ADR 0030).
      source: `${profile.explorer}/address/${config.factory}?tab=contract`,
    },
    quotes,
    supply: COIN_SUPPLY.toString(),
    decimals: COIN_DECIMALS,
    platformFeeBps,
    openingFee: settings.openingFee,
    // The factory holds a tax to Solana's rates and steps (`_writeTaxTerms`) and has no view of them: the contract
    // package's own lists are the same figures.
    taxRatesBps: [...REWARD_TAX_RATES],
    shareStepsBps: [...REWARD_BURN_SHARES],
    sharesMaxBps: REWARD_SHARES_MAX_BPS,
    payoutAssets: ["coin", "quote"],
    creatorLock: settings.creatorLock,
    // The Creator's own wallet alone until the other three Destinations have their contracts (#248).
    destinations: ["wallet"],
  };
  return { body, settings, listed };
}

/** What `chain` offers a Launch, read from its contracts and kept for a few seconds; a provider's failure is a 503 in words. */
export function chainOptions(db: Db, x: EvmContext): Promise<ChainOptions> {
  const key = `${x.config.chain}:${x.config.factory}`;
  const hit = kept.get(key);
  if (hit && Date.now() - hit.at < CACHE_MS) return hit.loading;
  const loading = reading(x, () => load(db, x));
  kept.set(key, { at: Date.now(), loading });
  // A failed read is not kept: the next request asks the chain again.
  loading.catch(() => {
    if (kept.get(key)?.loading === loading) kept.delete(key);
  });
  return loading;
}

/**
 * One asset's Listing, or null when the registry does not list it. `fresh` asks the registry now, which a launch's own
 * prepare does; otherwise the kept answer serves an asset it holds, and the registry is asked about any other, since
 * it alone gates a Launch and the form's candidates are only a list.
 */
export async function listedQuote(db: Db, x: EvmContext, quote: Address, { fresh = false } = {}): Promise<ListedQuote | null> {
  const address = checksum(quote);
  if (!fresh) {
    const held = (await chainOptions(db, x)).listed.get(address);
    if (held) return held;
  }
  return reading(x, async () => {
    const listing = await x.client.readContract({ address: x.config.registry, abi: quoteRegistryAbi, functionName: "listingOf", args: [address] });
    if (!listing.listed) return null;
    const [known] = await db.select().from(evmQuoteAssets).where(and(eq(evmQuoteAssets.chain, x.config.chain), eq(evmQuoteAssets.address, address))).limit(1);
    const row = await knownAsset(db, x, address, known);
    return row && quoteOption(row, listing);
  });
}

/**
 * The tickers of the Stock Tokens the API knows on a chain, which that chain's naming rules refuse as a coin's own
 * (ADR 0028). `chainOptions` is what stores each listed one, so it is asked first; when the chain cannot be read just
 * now the ones already known still stand.
 */
export async function stockSymbols(db: Db, x: EvmContext): Promise<string[]> {
  await chainOptions(db, x).catch(() => null);
  const rows = await db
    .select({ symbol: evmQuoteAssets.symbol })
    .from(evmQuoteAssets)
    .where(and(eq(evmQuoteAssets.chain, x.config.chain), eq(evmQuoteAssets.category, "tokenized_stock")));
  return rows.flatMap((r) => (r.symbol ? [r.symbol] : []));
}
