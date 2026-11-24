import { Connection } from "@solana/web3.js";
import { eq, sql } from "drizzle-orm";
import type { ChainIndexer, ChainInfo } from "@launchpad/contract";
import { chainCursors, type Db } from "@launchpad/db";
import type { Bindings, Config } from "../env";
import { evmChains, withoutRpcUrl } from "./evm/config";
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

/** Every chain this API reads: Solana, and each EVM chain `EVM_DEPLOYMENTS` names. */
export function indexers(env: Bindings, cfg: Config): Indexer[] {
  return [
    solanaIndexer(cfg),
    ...evmChains(env).map((c): Indexer => ({
      info: { chain: c.chain, family: "evm", name: c.profile.name, chainId: c.profile.chainId, explorer: c.profile.explorer },
      run: (db) => indexEvmChain(db, c).catch((e: unknown) => Promise.reject(withoutRpcUrl(e, c))),
      async status(db) {
        // The head is read now, so an Indexer that has stopped running shows as falling behind.
        const head = await evmClient(c).getBlock({ blockTag: "latest" }).catch((e: unknown) => Promise.reject(withoutRpcUrl(e, c)));
        const headTime = new Date(Number(head.timestamp) * 1000);
        const [cursor] = await db.select().from(chainCursors).where(eq(chainCursors.chain, c.chain)).limit(1);
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
    })),
  ];
}

/** Runs every polled chain's Indexer once, each even if another fails; the failures are thrown together after. */
export async function runIndexers(env: Bindings, cfg: Config, db: Db) {
  const runs: EvmIndexRun[] = [];
  const failures: Error[] = [];
  for (const ix of indexers(env, cfg)) {
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
