// #279: an EVM chain's Indexer against a provider on a bad day. A stand-in RPC in front of the stack's fork
// (`startRpcStandIn` in @launchpad/stack) answers what a real provider answers: an internal error, a rate limit, a
// refused range, a node that is behind. Each API here reads the stack's own deployment and database through it, with a
// setting or two of its own. Every test needs the fork and skips by name without it.
import { afterAll, beforeAll, describe, expect, inject, test } from "vitest";
import { toFunctionSelector, type Hex } from "viem";
import { IndexerFailureList, IndexerReplay, LaunchSummary, TradeList } from "@launchpad/contract";
import { ROBINHOOD_CHAIN } from "@launchpad/evm";
import { freePort, startApi, startRpcStandIn, type RpcStandIn } from "@launchpad/stack";
import { env } from "./client";
import { clients, evmWallet, launchCoin, operatorAlerts, swapExactIn } from "./evm";

const hasEvm = inject("harness").evm !== null;
const operator = () => ({ authorization: `Bearer ${env().operatorToken}` });
const INTERNAL = { rpc: { code: -32603, message: "Internal error" } } as const;

type Run = {
  from: number | null; to: number | null; head: number; launched: number; traded: number; skipped: { hash: string; error: string }[];
  failed: { hash: string; attempts: number; error: string } | null; logBlockRange: number; leftForLater: boolean; rateLimited: boolean; requests: number;
};

async function api(path: string, base = env().apiUrl): Promise<unknown> {
  const res = await fetch(`${base}${path}`);
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

/** One run of the Indexer through `base`, whatever its end: the job's status and the chain's run. */
async function indexerRun(base: string) {
  await clients().test.mine({ blocks: ROBINHOOD_CHAIN.finalityDepth });
  const res = await fetch(`${base}/v1/operator/jobs/indexer`, { method: "POST", headers: operator() });
  const job = (await res.json()) as { status: string; error: string | null; summary: { chains: Run[] } | null };
  return { http: res.status, status: job.status, error: job.error, run: job.summary?.chains[0] ?? null };
}

/** Runs the Indexer through `base` until nothing is left for later, and says how many runs that took. */
async function caughtUp(base: string, most = 40) {
  for (let runs = 1; runs <= most; runs++) {
    const { status, run, error } = await indexerRun(base);
    if (status !== "succeeded") throw new Error(`the Indexer failed while catching up: ${error}`);
    if (!run!.leftForLater) return runs;
  }
  throw new Error(`the Indexer was still behind after ${most} runs`);
}

const failures = async (base = env().apiUrl) => IndexerFailureList.parse(await (await fetch(`${base}/v1/operator/indexer/failures?chain=robinhood`, { headers: operator() })).json()).failures;
const tradesOf = async (coin: string) => TradeList.parse(await api(`/v1/launches/${coin}/trades`)).trades;

describe.skipIf(!hasEvm)("EVM chain: the Indexer and its provider", () => {
  let rpc: RpcStandIn;
  /** Through the stand-in with a range of 40 blocks, and a failure that may be the provider's set aside on its fourth run. */
  let wide: Awaited<ReturnType<typeof startApi>>;
  /** Through the stand-in with the free tier's range of 10 blocks. */
  let free: Awaited<ReturnType<typeof startApi>>;
  /** Through the stand-in with a budget of 12 requests a run. */
  let tiny: Awaited<ReturnType<typeof startApi>>;

  beforeAll(async () => {
    const e = inject("harness");
    rpc = await startRpcStandIn(e.evm!.rpcUrl, await freePort());
    const [deployment] = JSON.parse(e.apiVars.EVM_DEPLOYMENTS!) as Record<string, unknown>[];
    const start = async (settings: Record<string, number>) => {
      const port = await freePort();
      return startApi({
        port, databaseUrl: e.databaseUrl,
        vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${port}`, ROBINHOOD_RPC_URL: rpc.url, EVM_DEPLOYMENTS: JSON.stringify([{ ...deployment, ...settings }]) },
      });
    };
    [wide, free, tiny] = await Promise.all([start({ logBlockRange: 40, retryRunsUnclear: 4 }), start({ logBlockRange: 10 }), start({ maxRequestsPerRun: 12 })]);
  }, 300_000);

  afterAll(async () => {
    await Promise.all([wide?.stop(), free?.stop(), tiny?.stop(), rpc?.stop()]);
  });

  test("a provider answering -32603 to one eth_call for three runs, then recovering: the launch and every trade after it are indexed, and nothing was set aside", async () => {
    await caughtUp(wide.url);
    const trader = await evmWallet();
    // The Indexer reads a new coin's name with an `eth_call`; the provider answers every one "Internal error".
    const outage = rpc.fail({ method: "eth_call", data: toFunctionSelector("name()"), fault: INTERNAL });
    const l = await launchCoin(await evmWallet(), { firstBuy: 10n ** 15n });
    const sent: Hex[] = [l.receipt.transactionHash];
    for (let attempt = 1; attempt <= 3; attempt++) {
      const { http, status, run } = await indexerRun(wide.url);
      expect([http, status]).toEqual([500, "failed"]);
      // The run stopped on the launch to read it again, and set nothing aside.
      expect(run!.failed).toMatchObject({ hash: l.receipt.transactionHash, attempts: attempt });
      expect(run!.skipped).toEqual([]);
      expect((await fetch(`${env().apiUrl}/v1/launches/${l.coin}`)).status).toBe(404);
      // The coin trades on while the provider is down.
      sent.push((await swapExactIn(trader, l, "buy", 10n ** 15n)).receipt.transactionHash);
    }
    expect(outage.answered()).toBeGreaterThan(0);

    outage.stop();
    const recovered = await indexerRun(wide.url);
    expect(recovered.status).toBe("succeeded");
    expect(recovered.run).toMatchObject({ failed: null, skipped: [], launched: 1, traded: 4 });
    expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).chain).toBe("robinhood");
    expect((await tradesOf(l.coin)).map((t) => t.signature).reverse()).toEqual(sent);
    expect((await failures()).map((f) => f.transaction)).not.toContain(l.receipt.transactionHash);
  });

  test("a failure that lasts is set aside after its runs under one alert for the chain, and a replay writes the launch and its later trades and resolves it", async () => {
    await caughtUp(wide.url);
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet());
    // This coin's ticker cannot be read, run after run: the provider's fault or the coin's, the Indexer cannot tell.
    const fault = rpc.fail({ method: "eth_call", to: l.coin, data: toFunctionSelector("symbol()"), fault: INTERNAL });
    for (let attempt = 1; attempt <= 3; attempt++) expect((await indexerRun(wide.url)).run!.failed).toMatchObject({ hash: l.receipt.transactionHash, attempts: attempt });
    const fourth = await indexerRun(wide.url);
    expect(fourth.status).toBe("succeeded");
    expect(fourth.run!.skipped.map((s) => s.hash)).toEqual([l.receipt.transactionHash]);
    // The chain went on: a trade in the coin the Indexer does not know is passed over, and a later run does not meet the launch again.
    const { receipt: later } = await swapExactIn(trader, l, "buy", 10n ** 15n);
    expect(await caughtUp(wide.url)).toBe(1);

    const open = await failures();
    const mine = open.find((f) => f.transaction === l.receipt.transactionHash)!;
    expect(mine).toMatchObject({ chain: "robinhood", block: Number(l.receipt.blockNumber), attempts: 4, error: expect.stringContaining("Internal error") });
    expect(mine.setAsideAt).not.toBeNull();
    // One alert for the chain, saying how many, never one for each transaction.
    const alerts = (await operatorAlerts()).filter((a) => a.kind === "indexer_skipped");
    expect(alerts).toEqual([expect.objectContaining({ subject: "robinhood", resolvedAt: null, message: expect.stringContaining(`set aside ${open.length} transaction`) })]);

    fault.stop();
    const res = await fetch(`${env().apiUrl}/v1/operator/indexer/replay`, {
      method: "POST", headers: { ...operator(), "content-type": "application/json" }, body: JSON.stringify({ chain: "robinhood", transaction: l.receipt.transactionHash }),
    });
    expect(res.status).toBe(200);
    const replay = IndexerReplay.parse(await res.json());
    // The launch, and since it launched a coin, everything after it up to where the Indexer has read.
    expect(replay).toMatchObject({ chain: "robinhood", from: Number(l.receipt.blockNumber), next: null, launched: 1, traded: 1, resolved: 1, failed: [] });
    expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).chain).toBe("robinhood");
    expect((await tradesOf(l.coin)).map((t) => t.signature)).toEqual([later.transactionHash]);
    const left = await failures();
    expect(left.map((f) => f.transaction)).not.toContain(l.receipt.transactionHash);
    const after = (await operatorAlerts()).find((a) => a.kind === "indexer_skipped" && a.subject === "robinhood")!;
    if (left.length === 0) expect(after.resolvedAt).not.toBeNull();
    else expect(after.message).toContain(`set aside ${left.length} transaction`);
  });

  test("a rate limit ends the run and leaves the log range alone; a refused range halves it, and it grows back to the deployment's setting", async () => {
    await caughtUp(wide.url);
    await clients().test.mine({ blocks: 200 });
    rpc.logRanges.length = 0;
    // Four throttled answers: the first read's three tries, and the next run's first try.
    rpc.fail({ method: "eth_getLogs", times: 4, fault: { http: 429 } });
    const throttled = await indexerRun(wide.url);
    expect(throttled.status).toBe("succeeded");
    expect(throttled.run).toMatchObject({ rateLimited: true, leftForLater: true, logBlockRange: 40 });
    const next = await indexerRun(wide.url);
    expect(next.run).toMatchObject({ rateLimited: false, leftForLater: false, logBlockRange: 40 });
    // Never narrower than the setting but for a run's last, shorter range.
    expect(rpc.logRanges.filter((w) => w === 40).length).toBeGreaterThanOrEqual(5);
    expect(rpc.logRanges.filter((w) => w < 40).length).toBeLessThanOrEqual(2);

    // A provider that takes 10 blocks a call: the range halves until one is taken.
    rpc.behaviour.maxLogRange = 10;
    await clients().test.mine({ blocks: 100 });
    const refused = await indexerRun(wide.url);
    expect(refused.run).toMatchObject({ leftForLater: false, logBlockRange: 10 });
    // The provider takes any range again: after clean ranges it grows back, to its setting and no further.
    rpc.behaviour.maxLogRange = null;
    await clients().test.mine({ blocks: 900 });
    rpc.logRanges.length = 0;
    const grown = await indexerRun(wide.url);
    expect(grown.run).toMatchObject({ leftForLater: false, logBlockRange: 40 });
    expect(Math.max(...rpc.logRanges)).toBe(40);
  });

  test("a changed log range in the deployment's setting takes effect on the next run, whatever was remembered", async () => {
    await caughtUp(wide.url);
    await clients().test.mine({ blocks: 60 });
    rpc.logRanges.length = 0;
    // The cursor remembers 40 from the API above; this one is set to 10.
    const narrow = await indexerRun(free.url);
    expect(narrow.run).toMatchObject({ leftForLater: false, logBlockRange: 10 });
    expect(Math.max(...rpc.logRanges)).toBe(10);
    await clients().test.mine({ blocks: 60 });
    rpc.logRanges.length = 0;
    expect((await indexerRun(wide.url)).run!.logBlockRange).toBe(40);
    expect(Math.max(...rpc.logRanges)).toBe(40);
  });

  test("an hour's backlog at the free tier's range of 10 blocks is caught up in two runs", async () => {
    await caughtUp(free.url);
    rpc.behaviour.maxLogRange = 10;
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet());
    await caughtUp(free.url);
    // An hour of Robinhood Chain: 9.5 blocks a second (600,000 blocks in 63,054 s, measured for #252's review).
    await clients().test.mine({ blocks: 34_200 });
    const { receipt } = await swapExactIn(trader, l, "buy", 10n ** 15n);
    const started = Date.now();
    const runs = await caughtUp(free.url, 6);
    expect(runs).toBeLessThanOrEqual(2);
    // Each run inside its own budget of seconds, with room: the fork answers a range in a few milliseconds.
    expect(Date.now() - started).toBeLessThan(80_000);
    expect((await tradesOf(l.coin)).map((t) => t.signature)).toEqual([receipt.transactionHash]);
    rpc.behaviour.maxLogRange = null;
  }, 240_000);

  test("a run whose budget is spent inside a range saves how far it got, and the next goes on from there", async () => {
    await caughtUp(tiny.url);
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet());
    // Eight trades in eight blocks, all inside one range of the stack's 2,000 blocks.
    const sent: Hex[] = [];
    for (let i = 0; i < 8; i++) sent.push((await swapExactIn(trader, l, "buy", 10n ** 15n)).receipt.transactionHash);
    const first = await indexerRun(tiny.url);
    expect(first.status).toBe("succeeded");
    expect(first.run!.leftForLater).toBe(true);
    expect(first.run!.requests).toBeLessThan(12 + 12);
    // It stopped between two of the blocks, with what it had read written.
    const written = (await tradesOf(l.coin)).length;
    expect(written).toBeGreaterThan(0);
    expect(written).toBeLessThan(8);
    expect(first.run!.to).toBeLessThan(first.run!.head - ROBINHOOD_CHAIN.finalityDepth);
    const runs = await caughtUp(tiny.url);
    expect(runs).toBeGreaterThanOrEqual(1);
    expect((await tradesOf(l.coin)).map((t) => t.signature).reverse()).toEqual(sent);
  });

  test("a node behind the head that answers a short range without an error loses nothing: the next run reads those blocks again", async () => {
    await caughtUp(wide.url);
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet());
    await caughtUp(wide.url);
    const { receipt } = await swapExactIn(trader, l, "buy", 10n ** 15n);
    // This node is 40 blocks behind the one that gives the head, and answers the range with what it has.
    rpc.behaviour.lagBlocks = ROBINHOOD_CHAIN.finalityDepth + 15;
    const short = await indexerRun(wide.url);
    expect(short.status).toBe("succeeded");
    expect(short.run!.to).toBeGreaterThanOrEqual(Number(receipt.blockNumber));
    expect(await tradesOf(l.coin)).toEqual([]);
    rpc.behaviour.lagBlocks = 0;
    expect((await indexerRun(wide.url)).run!.traded).toBe(1);
    expect((await tradesOf(l.coin)).map((t) => t.signature)).toEqual([receipt.transactionHash]);
  });
});
