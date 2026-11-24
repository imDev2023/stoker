import { Hono } from "hono";
import type { ChainInfo, ChainList } from "@launchpad/contract";
import type { AppEnv } from "../env";
import { indexers } from "../chains/indexers";

/** The chains this API reads, each with how far its Indexer is behind the chain's head (#252, story 50). */
export const chainRoutes = new Hono<AppEnv>();

chainRoutes.get("/chains", async (c) => {
  const db = c.get("db");
  const chains = await Promise.all(
    indexers(c.env, c.get("cfg")).map(async (ix): Promise<ChainInfo> => {
      const indexer = await ix.status(db).catch((e: unknown) => {
        // A chain whose RPC does not answer is shown with what is known, never as an error for every chain.
        console.error(`reading ${ix.info.chain}'s head failed: ${(e as Error).message}`);
        return { mode: ix.run ? "poll" : "push", head: null, indexed: null, blocksBehind: null, secondsBehind: null, finalityDepth: 0, checkedAt: null } as const;
      });
      return { ...ix.info, indexer };
    }),
  );
  const body: ChainList = { chains };
  return c.json(body);
});
