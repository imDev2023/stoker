import { Hono } from "hono";
import type { ChainInfo, ChainList } from "@launchpad/contract";
import type { AppEnv } from "../env";
import { indexers } from "../chains/indexers";

/** The chains this API reads, each with how far its Indexer is behind the chain's head (#252, story 50). */
export const chainRoutes = new Hono<AppEnv>();

/**
 * The answer is kept for a few seconds in the Worker's memory: each one reads every chain's head and the newest indexed
 * block, and the page is public.
 */
const CACHE_MS = 3_000;
let cached: { at: number; body: ChainList } | null = null;

chainRoutes.get("/chains", async (c) => {
  if (cached && Date.now() - cached.at < CACHE_MS) return c.json(cached.body);
  const db = c.get("db");
  const { indexers: all, problem } = indexers(c.env, c.get("cfg"));
  if (problem) console.error(`EVM_DEPLOYMENTS cannot be read, so only Solana is answered: ${problem}`);
  const chains = await Promise.all(
    all.map(async (ix): Promise<ChainInfo> => {
      const indexer = await ix.status(db).catch((e: unknown) => {
        // A chain whose RPC does not answer is shown with what is known, never as an error for every chain.
        console.error(`reading ${ix.info.chain}'s head failed: ${(e as Error).message}`);
        return { mode: ix.run ? "poll" : "push", head: null, indexed: null, blocksBehind: null, secondsBehind: null, finalityDepth: 0, checkedAt: null } as const;
      });
      return { ...ix.info, indexer };
    }),
  );
  const body: ChainList = { chains };
  cached = { at: Date.now(), body };
  return c.json(body);
});
