// The Keeper (ADR 0025, ADR 0030, #254): our server wallet on each EVM chain, with no power of its own, making on a
// schedule the calls anyone may make. It applies each Destination's earnings, makes the Payout Calls that pay every
// Creator, referrer and the Admin their Credits, and makes the Tax Vault's calls that turn each coin's tax into Support
// Liquidity and its Reward Burn. It records nothing on the Ledger itself: the chain's Indexer reads its transactions'
// events as it reads anyone's. Every call is simulated first, and one the contract refuses is a reason in the summary.
import { encodeFunctionData, type Address, type Hex } from "viem";
import { and, desc, eq, gt, inArray, isNull, or, sql } from "drizzle-orm";
import { burnDestinationAbi, quoteRegistryAbi, stokerHookAbi, stokerKeysAbi, taxVaultAbi } from "@launchpad/evm";
import { launches, operatorAlerts, trades, type Db } from "@launchpad/db";
import type { Bindings } from "../../env";
import { JobFailure } from "../../jobs";
import { evmChains, ourAddresses, withoutRpcUrl, type EvmChainConfig } from "./config";
import { EvmSender, Refused, type Call } from "./sender";

/** Owners one Payout Call pays: each is a transfer, and a call stays far under a block's gas. */
const PAYOUT_BATCH = 50;
/** The owners whose Credits one run reads, per asset: the rest wait for the next run. */
const MAX_OWNERS_READ = 400;
/** Coins whose Tax Vault books one run reads: the latest to trade first. */
const MAX_VAULT_COINS = 100;
/** A coin's first day, in which its Opening Fees (ADR 0026) wait for the Tax Vault whatever its type. */
const OPENING_DAY_MS = 86_400_000;
/** The Keeper's least native balance unless the deployment sets one: 0.01 of the native asset. */
export const keeperMinBalanceOf = (c: EvmChainConfig) => c.keeperMinBalance ?? 10n ** BigInt(c.profile.native.decimals - 2);

export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

export type KeeperRun = {
  chain: string;
  /** Why nothing was done on the chain, when nothing could be. */
  skipped: string | null;
  keeper: Address | null;
  balance: string | null;
  /** Transactions left by earlier runs, settled at the start of this one. */
  settled: { hash: Hex; purpose: string; status: string }[];
  applied: { coin: string; hash: Hex }[];
  paid: { asset: string; owners: number; hash: Hex }[];
  support: { coin: string; hash: Hex }[];
  burned: { coin: string; hash: Hex }[];
  /** Calls the contracts refused when simulated, with the error each named: nothing was sent for them. */
  refused: { call: string; subject: string; reason: string }[];
  /** Calls not made because one before them has not settled yet. */
  waiting: { call: string; subject: string }[];
};

/** The pool key of one of our coins: its currencies in order, no LP fee, the registry's spacing and our hook (ADR 0025). */
export const poolKeyOf = (c: EvmChainConfig, l: { mint: string; quoteMint: string }, tickSpacing: number): PoolKey => {
  const quoteFirst = BigInt(l.quoteMint) < BigInt(l.mint);
  return {
    currency0: (quoteFirst ? l.quoteMint : l.mint) as Address, currency1: (quoteFirst ? l.mint : l.quoteMint) as Address, fee: 0, tickSpacing, hooks: c.hook,
  };
};

/** The EVM chains this API reads, or none and the reason, so one bad setting never stops Solana's jobs. */
export function readableChains(env: Bindings): { chains: EvmChainConfig[]; problem: string | null } {
  try {
    return { chains: evmChains(env), problem: null };
  } catch (e) {
    return { chains: [], problem: (e as Error).message };
  }
}

/**
 * Runs a job's work on every EVM chain, each even if another fails, and throws the failures together after with what
 * every chain did, as the Indexer's runs are made (`runIndexers`).
 */
export async function perChain<T>(env: Bindings, work: (c: EvmChainConfig) => Promise<T>): Promise<{ chains: T[] }> {
  const { chains, problem } = readableChains(env);
  const done: T[] = [];
  const failures: string[] = problem ? [problem] : [];
  for (const c of chains) {
    try {
      done.push(await work(c));
    } catch (e) {
      failures.push(`${c.chain}: ${withoutRpcUrl(e, c).message.split("\n")[0]}`);
    }
  }
  if (failures.length) throw new JobFailure(failures.join("; "), { chains: done });
  return { chains: done };
}

/** One run of the Keeper on every EVM chain (job `keeper`). */
export const runKeeper = (env: Bindings, db: Db) => perChain(env, (c) => keepChain(db, c));

async function keepChain(db: Db, c: EvmChainConfig): Promise<KeeperRun> {
  const run: KeeperRun = { chain: c.chain, skipped: null, keeper: null, balance: null, settled: [], applied: [], paid: [], support: [], burned: [], refused: [], waiting: [] };
  if (!c.keeperKey) return { ...run, skipped: `no Keeper key: the secret ${c.chain.toUpperCase()}_KEEPER_KEY is not set` };
  const sender = new EvmSender(db, c, c.keeperKey, "keeper");
  const client = sender.client;
  run.keeper = sender.address;
  run.settled = (await sender.settle()).map((t) => ({ hash: t.hash, purpose: t.purpose, status: t.status }));
  const balance = await client.getBalance({ address: sender.address });
  run.balance = balance.toString();
  await syncKeeperLow(db, c, sender.address, balance);
  // What a job pays is decided on the chain's `safe` block where its profile says so (#254).
  const blockTag = c.profile.paysAtSafe ? "safe" : "latest";
  const tickSpacing = await client.readContract({ address: c.registry, abi: quoteRegistryAbi, functionName: "tickSpacing" });

  /** Simulates and sends one call, recording what became of it under `list`. */
  const make = async (purpose: string, subject: string, call: Call, abi: Parameters<EvmSender["simulate"]>[1], done: (hash: Hex) => void) => {
    if (await sender.waiting(purpose, subject)) return void run.waiting.push({ call: purpose, subject });
    try {
      const gas = await sender.simulate(call, abi);
      const receipt = await sender.send(purpose, subject, call, gas);
      if (receipt?.status === "success") done(receipt.transactionHash);
      else if (receipt) run.refused.push({ call: purpose, subject, reason: `reverted on-chain in ${receipt.transactionHash}` });
      else run.waiting.push({ call: purpose, subject });
    } catch (e) {
      if (e instanceof Refused) return void run.refused.push({ call: purpose, subject, reason: e.reason });
      throw e;
    }
  };

  // 1. Each Destination's earnings, applied to its own coin (#248): this also pays the Destination its own Credits.
  const withRule = await db
    .select()
    .from(launches)
    .where(and(eq(launches.chain, c.chain), eq(launches.factory, c.factory), inArray(launches.earningsDestination, ["holders", "burn", "liquidity"])));
  for (const l of withRule) {
    const key = poolKeyOf(c, l, tickSpacing);
    const destination = l.creatorDestination as Address;
    const waiting = await client.readContract({ address: destination, abi: burnDestinationAbi, functionName: "waitingOf", args: [key], blockTag });
    if (waiting === 0n) continue;
    await make("apply", l.mint, { to: destination, data: encodeFunctionData({ abi: burnDestinationAbi, functionName: "applyEarnings", args: [key] }) }, burnDestinationAbi, (hash) =>
      run.applied.push({ coin: l.mint, hash }));
  }

  // 2. The Payout Calls (ADR 0025): every owner a trade has credited, per asset, the Admin among them.
  const admin = await client.readContract({ address: c.keys, abi: stokerKeysAbi, functionName: "admin", blockTag });
  const ours = new Set(ourAddresses(c));
  const assets = await db.selectDistinct({ quote: launches.quoteMint }).from(launches).where(and(eq(launches.chain, c.chain), eq(launches.factory, c.factory)));
  for (const { quote } of assets) {
    const owners = await creditedOwners(db, c, quote, admin, ours);
    const owed: Address[] = [];
    for (const owner of owners.slice(0, MAX_OWNERS_READ)) {
      const credit = await client.readContract({ address: c.hook, abi: stokerHookAbi, functionName: "creditOf", args: [owner, quote as Address], blockTag });
      if (credit > 0n) owed.push(owner);
    }
    for (let i = 0; i < owed.length; i += PAYOUT_BATCH) {
      const batch = owed.slice(i, i + PAYOUT_BATCH);
      const call = { to: c.hook, data: encodeFunctionData({ abi: stokerHookAbi, functionName: "payout", args: [quote as Address, batch] }) };
      await make("payout", `${quote}:${i / PAYOUT_BATCH}`, call, stokerHookAbi, (hash) => run.paid.push({ asset: quote, owners: batch.length, hash }));
    }
  }

  // 3. The Tax Vault's calls (ADR 0025, #271): a piece of Support Liquidity and a piece of the burn per coin and run.
  for (const l of await vaultCoins(db, c)) {
    const key = poolKeyOf(c, l, tickSpacing);
    const [[burnPart, supportPart], [burnFunded, supportFunded]] = await Promise.all([
      client.readContract({ address: c.taxVault, abi: taxVaultAbi, functionName: "waiting", args: [key], blockTag }),
      client.readContract({ address: c.taxVault, abi: taxVaultAbi, functionName: "fundedWaiting", args: [key], blockTag }),
    ]);
    if (supportPart + supportFunded > 0n) {
      await make("support", l.mint, { to: c.taxVault, data: encodeFunctionData({ abi: taxVaultAbi, functionName: "addSupport", args: [key] }) }, taxVaultAbi, (hash) =>
        run.support.push({ coin: l.mint, hash }));
    }
    if (burnPart + burnFunded > 0n) {
      await make("burn", l.mint, { to: c.taxVault, data: encodeFunctionData({ abi: taxVaultAbi, functionName: "burn", args: [key] }) }, taxVaultAbi, (hash) =>
        run.burned.push({ coin: l.mint, hash }));
    }
  }
  return run;
}

/**
 * Everyone a trade in an asset may have credited (ADR 0025): the Admin, every coin's Creator Earnings Destination that
 * is a wallet (a Destination contract pulls its own when it applies its earnings), and every referrer a trade named.
 * Never one of our own contracts.
 */
async function creditedOwners(db: Db, c: EvmChainConfig, quote: string, admin: Address, ours: Set<string>): Promise<Address[]> {
  const [creators, referrers] = await Promise.all([
    db
      .selectDistinct({ owner: launches.creatorDestination })
      .from(launches)
      .where(and(eq(launches.chain, c.chain), eq(launches.factory, c.factory), eq(launches.quoteMint, quote), eq(launches.earningsDestination, "wallet"))),
    db
      .selectDistinct({ owner: trades.referrer })
      .from(trades)
      .innerJoin(launches, eq(launches.mint, trades.mint))
      .where(and(eq(trades.chain, c.chain), eq(launches.factory, c.factory), eq(launches.quoteMint, quote), sql`${trades.referrer} is not null`)),
  ]);
  const all = new Map<string, Address>([[admin.toLowerCase(), admin]]);
  for (const r of [...creators, ...referrers]) if (r.owner) all.set(r.owner.toLowerCase(), r.owner as Address);
  return [...all].filter(([k]) => !ours.has(k)).map(([, a]) => a);
}

/**
 * The coins whose Tax Vault books a run reads: every Reward Launch and Stoke Launch, every coin whose earnings fund its
 * burn or its Support Liquidity, and every coin in its first day, whose Opening Fees wait whatever its type; the latest
 * to trade first, so a busy coin is never left behind a quiet one.
 */
function vaultCoins(db: Db, c: EvmChainConfig) {
  return db
    .select({ mint: launches.mint, quoteMint: launches.quoteMint })
    .from(launches)
    .where(and(
      eq(launches.chain, c.chain), eq(launches.factory, c.factory),
      or(sql`${launches.taxKind} is not null`, inArray(launches.earningsDestination, ["burn", "liquidity"]), gt(launches.createdAt, new Date(Date.now() - OPENING_DAY_MS))),
    ))
    .orderBy(desc(sql`(select max(${trades.slot}) from ${trades} where ${trades.mint} = ${launches.mint})`))
    .limit(MAX_VAULT_COINS);
}

/**
 * The chain's one alert for a Keeper running low (#254): raised while its native balance is under the deployment's
 * least, which also stops the chain's Volume Rebates, and resolved once the owner has funded it again.
 */
async function syncKeeperLow(db: Db, c: EvmChainConfig, keeper: Address, balance: bigint) {
  const least = keeperMinBalanceOf(c);
  const alert = and(eq(operatorAlerts.kind, "keeper_low"), eq(operatorAlerts.subject, c.chain));
  if (balance >= least) return void (await db.update(operatorAlerts).set({ resolvedAt: sql`now()` }).where(and(alert, isNull(operatorAlerts.resolvedAt))));
  const message = `${c.profile.name}'s Keeper ${keeper} holds ${balance} raw units of ${c.profile.native.symbol}, under the ${least} it needs: it pays no Volume Rebate until it is funded, and its gas runs out after.`;
  await db
    .insert(operatorAlerts)
    .values({ kind: "keeper_low", subject: c.chain, message })
    .onConflictDoUpdate({
      target: [operatorAlerts.kind, operatorAlerts.subject],
      set: { message, raisedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.raisedAt} else now() end`, notifiedAt: sql`case when ${operatorAlerts.resolvedAt} is null then ${operatorAlerts.notifiedAt} else null end`, resolvedAt: null },
    });
}
