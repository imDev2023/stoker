// Vitest global setup: start the whole backend once for every test file (see @launchpad/stack).
import type { TestProject } from "vitest/node";
import { startStack, type StackEnv } from "@launchpad/stack";
import { writeUnitsReport } from "./units";

declare module "vitest" {
  export interface ProvidedContext {
    harness: StackEnv;
  }
}

export default async function setup(project: TestProject) {
  // The chain takes free ports by itself; TEST_RPC_PORT pins it when a fixed address helps debugging.
  // An Active Day of the Creator Ladder (ADR 0020) lasts ten seconds here, so `creator-ladder.test.ts` sees a coin climb;
  // the first ladder's fifteen days are still far more pool trading than any other file gives one coin.
  // A Rebate Week (ADR 0021) lasts thirty seconds, so `rebates.test.ts` sees one settled and paid; it gives nothing
  // unless a Budget Table gives the `rebates` row a share, which only that file and `budget-table.test.ts` announce.
  // A Holding Day (ADR 0022) lasts ten seconds too, so `holding-weight.test.ts` sees coins age and a step reached. Every
  // Reward Engine run therefore checks the coins that can have a round again, a bounded number a run; it changes no
  // payout unless a rules version with steps is in force, which only that file announces, and takes back before it ends.
  // The chain also quotes the unlucky Quote Asset (#282), whose account for the operations wallet has an address that
  // takes many tries to derive: `fee-collector.test.ts` claims its Platform Fee, and no other file launches against it.
  const { env, stop } = await startStack({
    activeDaySeconds: 10, holdingDaySeconds: 10, rebateWeekSeconds: 30, unluckyQuote: true,
    ...(process.env.TEST_RPC_PORT ? { rpcPort: Number(process.env.TEST_RPC_PORT) } : {}),
  });
  project.provide("harness", env);
  return async () => {
    // What every transaction of the run used of its compute-unit limit, on request (`./units`), while the chain is still up.
    if (process.env.UNITS_REPORT) await writeUnitsReport(env.rpcUrl, process.env.UNITS_REPORT).catch((e: unknown) => console.error("the units report failed:", e));
    await stop();
  };
}
