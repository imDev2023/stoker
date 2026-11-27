import { Connection } from "@solana/web3.js";
import { and, eq, sql } from "drizzle-orm";
import type { ChainIndexer, ChainInfo } from "@launchpad/contract";
import { chainCursors, type Db } from "@launchpad/db";
import type { Bindings, Config } from "../env";
import { evmChains, withoutRpcUrl, type EvmChainConfig } from "./evm/config";
import { evmClient, indexEvmChain, type EvmIndexRun } from "./evm/indexer";

/**
 * The Indexer behind one interface, one per chain (#252). An EVM chain's polls the chain on the Indexer's cron and on
 * the operator's run; Solana's is pushed every transaction by Helius's webhook and the site's fast path
 * (`indexTransactions` in ../indexer.ts), with the graduation watch as its backfill, so it has nothing to poll. Either
 * says how far behind its chain's head it is.
 */
export type Indexer = {
  info: Omit<ChainInfo, "indexer">;
  /** One run; null for a chain whose events are pushed. */
  run: ((db: Db) => Promise<EvmIndexRun>) | null;
  status: (db: Db) => Promise<ChainIndexer>;
};

const iso = (d: Date | null | undefined) => d?.toISOString() ?? null;
const secondsBetween = (later: Date | null | undefined, earlier: Date | null | undefined) =>
  later && earlier ? Math.max(0, (later.getTime() - earlier.getTime()) / 1000) : null;

/** Solana's Indexer: the head from the RPC at `confirmed`, the newest slot of ours it has written from the database. */
function solanaIndexer(cfg: Config): Indexer {
  return {
    info: { chain: "solana", family: "solana", name: "Solana", chainId: null, explorer: cfg.cluster === "mainnet" ? "https://solscan.io" : `https://solscan.io/?cluster=${cfg.cluster}` },
    run: null,
    async status(db) {
      const connection = new Connection(cfg.rpcUrl, "confirmed");
      const headSlot = await connection.getSlot("confirmed");
      const [headTime, newest] = await Promise.all([
        connection.getBlockTime(headSlot).catch(() => null),
        db.execute<{ slot: string | null; time: Date | string | null }>(sql`
          select slot::text, time from (
            select max(slot) as slot, max(block_time) as time from trades where chain = 'solana'
            union all
            select max(created_slot), max(created_at) from launches where chain = 'solana'
          ) s where slot is not null order by slot desc limit 1`),
      ]);
      const row = newest[0];
      const indexedTime = row?.time ? new Date(row.time) : null;
      const head = { block: headSlot, time: headTime === null ? null : new Date(headTime * 1000) };
      return {
        mode: "push",
        head: { block: head.block, time: iso(head.time) },
        indexed: row?.slot ? { block: Number(row.slot), time: iso(indexedTime) } : null,
        blocksBehind: row?.slot ? Math.max(0, head.block - Number(row.slot)) : null,
        secondsBehind: secondsBetween(head.time, indexedTime),
        finalityDepth: 0,
        checkedAt: new Date().toISOString(),
      };
    },
  };
}

/**
 * The EVM chains' Indexers, or none and the reason when `EVM_DEPLOYMENTS` cannot be read (a malformed list, a missing
 * RPC secret), so a bad EVM setting never takes Solana's answer down with it.
 */
function evmIndexers(env: Bindings, cfg: Config): { indexers: Indexer[]; problem: string | null } {
  let chains;
  try {
    chains = evmChains(env);
  } catch (e) {
    return { indexers: [], problem: (e as Error).message };
  }
  // Each with the platform's settings, which a launch prepared through the API is written with (#253).
  return { indexers: chains.map((c) => evmIndexer({ ...c, platform: cfg })), problem: null };
}

/** Every chain this API reads: Solana, and each EVM chain `EVM_DEPLOYMENTS` names that can be read. */
export function indexers(env: Bindings, cfg: Config): { indexers: Indexer[]; problem: string | null } {
  const evm = evmIndexers(env, cfg);
  return { indexers: [solanaIndexer(cfg), ...evm.indexers], problem: evm.problem };
}

function evmIndexer(c: EvmChainConfig): Indexer {
  return {
      info: { chain: c.chain, family: "evm", name: c.profile.name, chainId: c.profile.chainId, explorer: c.profile.explorer },
      run: (db) => indexEvmChain(db, c).catch((e: unknown) => Promise.reject(withoutRpcUrl(e, c))),
      async status(db) {
        // The head is read now, so an Indexer that has stopped running shows as falling behind.
        const head = await evmClient(c).getBlock({ blockTag: "latest" }).catch((e: unknown) => Promise.reject(withoutRpcUrl(e, c)));
        const headTime = new Date(Number(head.timestamp) * 1000);
        const [cursor] = await db.select().from(chainCursors).where(and(eq(chainCursors.chain, c.chain), eq(chainCursors.factory, c.factory))).limit(1);
        return {
          mode: "poll",
          head: { block: Number(head.number), time: headTime.toISOString() },
          indexed: cursor ? { block: cursor.indexedBlock, time: iso(cursor.indexedBlockTime) } : null,
          blocksBehind: cursor ? Math.max(0, Number(head.number) - cursor.indexedBlock) : null,
          secondsBehind: cursor ? secondsBetween(headTime, cursor.indexedBlockTime) : null,
          finalityDepth: c.profile.finalityDepth,
          checkedAt: new Date().toISOString(),
        };
      },
  };
}

/** Runs every polled chain's Indexer once, each even if another fails; the failures are thrown together after. */
export async function runIndexers(env: Bindings, cfg: Config, db: Db) {
  const runs: EvmIndexRun[] = [];
  const failures: Error[] = [];
  const { indexers: all, problem } = indexers(env, cfg);
  if (problem) failures.push(new Error(problem));
  for (const ix of all) {
    if (!ix.run) continue;
    try {
      runs.push(await ix.run(db));
    } catch (e) {
      failures.push(new Error(`${ix.info.chain}: ${(e as Error).message}`));
    }
  }
  if (failures.length) throw new AggregateError(failures, failures.map((f) => f.message).join("; "));
  return { chains: runs };
}
