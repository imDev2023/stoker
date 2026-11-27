// #254 on a stack of its own: Volume Rebates with trades on both chain families, each trader paid on the chain of their
// trades, which needs a Budget Table that gives the `rebates` row a share; and the ladder key's tier raise, which needs
// a coin held at its Graduation Target for an hour of its chain's time and fifteen Active Days after, so the fork's
// clock moves. Neither may touch the suite's shared stack, so this file starts its own chain, fork, database and API.
import { afterAll, beforeAll, describe, expect, inject, test } from "vitest";
import { parseEventLogs } from "viem";
import { LaunchSummary, type BudgetShares } from "@launchpad/contract";
import { NATIVE, stokerHookAbi } from "@launchpad/evm";
import { startStack, type StackEnv } from "@launchpad/stack";
import { connection, deliverWebhook, fundedWallet, launchedCoin, onStack, SOL, trade } from "./client";
import { balanceOf, clients, evm, evmWallet, launchCoin, ledgerOf, runApiJob, runIndexer, runKeeper, swapExactIn } from "./evm";

const hasFork = inject("harness").evm !== null && !!process.env.ROBINHOOD_RPC_URL;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/** A fifth of the Platform Net to the rebates, taken from the treasury, as `rebates.test.ts` announces it. */
const WITH_REBATES: BudgetShares = { burn: 6000, flywheel: 500, rebates: 2000, referrals: 0, integrators: 0, treasury: 1500 };
/** 1970-01-05, the epoch's first Monday, which every Rebate Week is counted from. */
const ANCHOR = 4 * 86_400_000;

describe.skipIf(!hasFork)("EVM chain: Volume Rebates and the Creator Ladder, on a stack of its own", () => {
  let own: { env: StackEnv; stop: () => Promise<void> };
  const operator = () => ({ authorization: `Bearer ${own.env.operatorToken}`, "content-type": "application/json" });
  const weekMs = () => own.env.rebateWeekSeconds * 1000;
  const weekOf = (ms: number) => Math.floor((ms - ANCHOR) / weekMs());
  const solanaTime = async () => ((await connection().getBlockTime(await connection().getSlot("confirmed"))) ?? Math.floor(Date.now() / 1000)) * 1000;
  // The fork's clock moves only when it mines a block, as a real chain makes one ten times a second.
  const evmTime = async () => {
    await clients().test.mine({ blocks: 1 });
    return Number((await clients().public.getBlock({ blockTag: "latest" })).timestamp) * 1000;
  };
  const clock = async () => Math.max(Date.now(), await solanaTime(), await evmTime());

  beforeAll(async () => {
    own = await startStack({ activeDaySeconds: 10, rebateWeekSeconds: 30 });
  }, 600_000);

  afterAll(async () => {
    await own?.stop();
  });

  test("a Rebate Week with trades on both families pays each trader on the chain of their trades", async () => {
    await onStack(own.env, async () => {
      const coins = [await launchedCoin(), await launchedCoin(), await launchedCoin()];
      const evmCoin = await launchCoin(await evmWallet());
      const from = new Date((await clock()) + own.env.feeChangeLeadSeconds * 1000 + 2_000);
      const announced = await fetch(`${own.env.apiUrl}/v1/operator/budget-table`, { method: "POST", headers: operator(), body: JSON.stringify({ shares: WITH_REBATES, effectiveAt: from.toISOString() }) });
      expect(announced.status).toBe(201);
      while ((await clock()) < from.getTime() + 1_000 || Math.min(Date.now(), await solanaTime(), await evmTime()) < from.getTime() + 1_000) await sleep(500);
      // A week only just begun on every clock, so both trades fall inside it.
      for (;;) {
        const now = await clock();
        if (now - (ANCHOR + weekOf(now) * weekMs()) < weekMs() / 4) break;
        await sleep(500);
      }
      const week = weekOf(await clock());

      // One trader on Solana, on three coins so each stays on its curve; another on the EVM chain.
      const solanaTrader = await fundedWallet(5);
      for (const c of coins) await deliverWebhook([(await trade(solanaTrader, c.mint, "buy", SOL(0.8))).signature]);
      const evmTrader = await evmWallet(10n);
      await swapExactIn(evmTrader, evmCoin, "buy", 2n * 10n ** 18n);
      expect(weekOf(await clock())).toBe(week);

      // Each chain collects: Solana's Fee Collector, and on the EVM chain the Keeper's Payout Call to the Admin.
      for (const job of ["fee-collector", "evm-quotes"]) expect((await runApiJob(job)).status, job).toBe("succeeded");
      await runIndexer();
      await runKeeper();

      // The week ends on every clock, the EVM chain's `safe` block included.
      while (Math.min(Date.now(), await solanaTime(), await evmTime()) < ANCHOR + (week + 1) * weekMs() + 1_000) await sleep(500);
      await clients().test.mine({ blocks: 40 });
      const evmBefore = await balanceOf(NATIVE, evmTrader.address);
      expect((await runApiJob("rebates")).status).toBe("succeeded");
      const evmRun = await runApiJob("evm-rebates");
      expect(evmRun.status, evmRun.error ?? "").toBe("succeeded");

      const rebates = await ledgerOf("kind=rebate");
      const solanaPaid = rebates.filter((r) => r.destination === solanaTrader.publicKey.toBase58());
      const evmPaid = rebates.filter((r) => r.destination === evmTrader.address);
      expect(solanaPaid.map((r) => r.chain)).toEqual(["solana"]);
      expect(evmPaid).toHaveLength(1);
      expect(evmPaid[0]).toMatchObject({ chain: "robinhood", asset: { mint: NATIVE, decimals: 18 }, source: evm()!.serverKeys.keeper.address });
      // Paid on its own chain, in its native asset, by the Keeper: exactly what the Ledger says.
      expect(await balanceOf(NATIVE, evmTrader.address)).toBe(evmBefore + BigInt(evmPaid[0]!.amount));
      expect(BigInt(evmPaid[0]!.amount)).toBeGreaterThan(0n);
      // The rebate is the row's spending on that chain, out of that chain's net.
      const rows = (await (await fetch(`${own.env.apiUrl}/v1/budgets?chain=robinhood`)).json()) as { rows: { row: string; spentLamports: string | null }[] };
      expect(BigInt(rows.rows.find((r) => r.row === "rebates")!.spentLamports!)).toBeGreaterThan(0n);
      // A second run settles nothing again and pays nobody twice.
      const again = await runApiJob("evm-rebates");
      expect(again.summary.chains[0]).toMatchObject({ settled: [], paid: [] });
    });
  }, 300_000);

  test("a coin that reaches 15 Active Days is raised to the second tier once, and the next trade credits the higher share", async () => {
    await onStack(own.env, async () => {
      const creator = await evmWallet();
      const trader = await evmWallet(1_000n);
      const l = await launchCoin(creator);
      // Past the Opening Fee, then held above twenty times the start price for the Graduation Hold.
      await clients().test.increaseTime({ seconds: 21 });
      await clients().test.mine({ blocks: 1 });
      await swapExactIn(trader, l, "buy", 50n * 10n ** 18n);
      await clients().test.increaseTime({ seconds: 3_601 });
      await clients().test.mine({ blocks: 1 });
      await swapExactIn(trader, l, "buy", 10n ** 15n);
      await runIndexer();
      expect(LaunchSummary.parse(await (await fetch(`${own.env.apiUrl}/v1/launches/${l.coin}`)).json()).graduation?.creatorTier).toMatchObject({ tier: 1, activeDays: 0 });

      // Sixteen Active Days of ten seconds each on the chain's own clock, each with a day's worth of trading.
      for (let day = 0; day < 16; day++) {
        await clients().test.increaseTime({ seconds: own.env.activeDaySeconds });
        await clients().test.mine({ blocks: 1 });
        await swapExactIn(trader, l, "buy", 10n ** 18n);
      }
      await runIndexer();
      const climbed = await runApiJob("evm-ladder");
      expect(climbed.status, climbed.error ?? "").toBe("succeeded");
      const ladder = climbed.summary.chains[0] as { raised: { coin: string; tier: number; hash: string }[] };
      expect(ladder.raised).toEqual([expect.objectContaining({ coin: l.coin, tier: 2 })]);
      await runIndexer();

      // The coin's page shows the tier the chain gave it, from the hook's own event, with the days that earned it.
      const coin = LaunchSummary.parse(await (await fetch(`${own.env.apiUrl}/v1/launches/${l.coin}`)).json());
      expect(coin.graduation?.creatorTier).toMatchObject({ tier: 2, next: { tier: 3 } });
      expect(coin.graduation!.creatorTier!.activeDays).toBeGreaterThanOrEqual(15);
      const onChain = await clients().public.readContract({ address: evm()!.hook, abi: stokerHookAbi, functionName: "creatorTierOf", args: [l.poolId] });
      expect(onChain).toBe(2);
      // Once: the next run raises nothing.
      expect(((await runApiJob("evm-ladder")).summary.chains[0] as { raised: unknown[] }).raised).toEqual([]);

      // The next trade credits the Creator the second tier's share of its Platform Fee, 60% on this stack.
      const { receipt } = await swapExactIn(trader, l, "buy", 10n ** 17n);
      const [fee] = parseEventLogs({ abi: stokerHookAbi, logs: receipt.logs, eventName: "FeeCredited" });
      expect(fee!.args.creatorCredit).toBe((fee!.args.fee * 6_000n) / 10_000n);
      // And the Ledger shows the Creator paid it with the rest, on the chain, from the Keeper's Payout Call.
      await runIndexer();
      await runKeeper();
      const paid = (await ledgerOf("chain=robinhood&kind=creator_credit")).filter((e) => e.launch?.mint === l.coin);
      expect(paid.length).toBeGreaterThan(0);
      expect(paid.every((e) => e.destination === creator.address)).toBe(true);
    });
  }, 300_000);
});

