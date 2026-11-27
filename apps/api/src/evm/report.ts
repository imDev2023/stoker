import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import { and, eq, gt, sql } from "drizzle-orm";
import { TransactionReceiptNotFoundError, type Hex } from "viem";
import type { EvmTransactionReport } from "@launchpad/contract";
import { chainCursors, jobLocks } from "@launchpad/db";
import { indexers } from "../chains/indexers";
import type { AppEnv } from "../env";
import { runJob } from "../jobs";
import { evmContext, reading } from "./context";

/**
 * POST /v1/transactions/:hash?chain=<an EVM chain> (#253): the site reports a transaction it sent, so the coin or the
 * trade shows without waiting for the Indexer's next scheduled run, as Solana's fast path does for a signature.
 * `launched` is how many Launches the report's own run wrote, for the caller to start their metadata's upload.
 *
 * Anyone may call it, as often as they like, so its work is bounded:
 * - A hash with no receipt costs one read of the chain and answers 404; a transaction not yet final costs two.
 * - The Indexer runs only for a transaction that is on the chain, final, logged an event of our contracts (so it cost
 *   its sender gas on them) and sits in a block the Indexer has not passed. A run reads on to the chain's head, so
 *   every earlier transaction is then answered from the cursor alone, with no run.
 * - A run is the Indexer's own through its one interface, under the Indexer's lease: never two at once, never beside
 *   the cron's, and no more than its own budget of ranges and seconds. It does only work the next scheduled run would.
 */
export async function reportEvmTransaction(c: Context<AppEnv>, hash: Hex, chain: string): Promise<{ report: EvmTransactionReport; launched: number }> {
  const x = evmContext(c, chain);
  const { config, client } = x;
  const db = c.get("db");
  const answer = (status: EvmTransactionReport["status"], block: number | null, launched = 0) => ({ report: { chain: config.chain, status, block }, launched });

  const found = await reading(x, async () => {
    const receipt = await client.getTransactionReceipt({ hash }).catch((e: unknown) => (e instanceof TransactionReceiptNotFoundError ? null : Promise.reject(e)));
    return receipt && { receipt, head: Number(await client.getBlockNumber()) };
  });
  if (!found) throw new HTTPException(404, { message: "transaction not found, or not in a block yet" });
  const block = Number(found.receipt.blockNumber);
  if (found.head - block < config.profile.finalityDepth) return answer("pending", block);
  // Nothing of ours in it (a transfer, a reverted transaction): there is nothing to write, and nothing to run.
  const ours = [config.factory, config.hook, config.taxVault].map((a) => a.toLowerCase());
  if (!found.receipt.logs.some((log) => ours.includes(log.address.toLowerCase()))) return answer("indexed", block);

  const passed = async () => {
    const [cursor] = await db.select({ block: chainCursors.indexedBlock }).from(chainCursors).where(and(eq(chainCursors.chain, config.chain), eq(chainCursors.factory, config.factory))).limit(1);
    return cursor !== undefined && cursor.block >= block;
  };
  if (await passed()) return answer("indexed", block);
  // A run under way will write it, or the next report will: no second run, and no skipped run on the operator's list.
  const [busy] = await db.select({ job: jobLocks.job }).from(jobLocks).where(and(eq(jobLocks.job, "indexer"), gt(jobLocks.expiresAt, sql`now()`))).limit(1);
  if (busy) return answer("pending", block);
  const indexer = indexers(c.env, c.get("cfg")).indexers.find((i) => i.info.chain === config.chain);
  if (!indexer?.run) return answer("pending", block);
  const run = indexer.run;
  let launched = 0;
  await runJob(db, "indexer", async () => {
    const written = await run(db);
    launched = written.launched;
    return { chains: [written] };
  }, { exclusive: true }).catch((e: unknown) => {
    // The run's failure is on the operator's list (`runJob`); the site is told to ask again.
    console.error(`indexing ${config.chain} for a reported transaction failed: ${(e as Error).message}`);
    throw new HTTPException(503, { message: `${config.profile.name} could not be read just now. Try again.` });
  });
  return answer((await passed()) ? "indexed" : "pending", block, launched);
}
