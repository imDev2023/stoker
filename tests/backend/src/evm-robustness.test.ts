// #252, the main session's review of 2026-11-24: what keeps an EVM chain's Indexer fit to run against a real chain, and
// Solana's jobs whole beside it. Every test here needs the stack's fork of Robinhood Chain and skips by name without it.
import { afterAll, beforeAll, describe, expect, inject, test } from "vitest";
import { erc20Abi, parseAbi, type Address } from "viem";
import { ChainList, LaunchSummary, TradeList } from "@launchpad/contract";
import { NATIVE, ROBINHOOD_CHAIN, taxVaultAbi } from "@launchpad/evm";
import { spawn, type ChildProcess } from "node:child_process";
import postgres from "postgres";
import { deployStoker, deploymentOf, forkArgs, freePort, GRADUATION_WATCH_CRON, runMigrations, startApi, type EvmStackEnv } from "@launchpad/stack";
import { env } from "./client";
import { balanceOf, clients, onFork, SWAP_GAS, whyReverted, evmWallet, launchCoin, listQuote, operatorAlerts, runIndexer, strictRpc, swapExactIn } from "./evm";

const hasEvm = inject("harness").evm !== null;
const operator = () => ({ authorization: `Bearer ${env().operatorToken}` });

async function api(path: string, base = env().apiUrl): Promise<unknown> {
  const res = await fetch(`${base}${path}`);
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

/** Apple's Stock Token, multiplier 1.000566 at the fork's block (the knowledge base's `16-token-contracts.md`). */
const AAPL: Address = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
const STOCK_START_TICK = -244_200;

describe.skipIf(!hasEvm)("EVM chain: the Indexer stays up", () => {
  test("a coin whose name holds a NUL, and a transaction that can never be written, are set aside and the next launch is indexed", async () => {
    // A Quote Asset whose every call reverts: it can be listed and launched against without a First Buy, and the Indexer
    // can never read its decimals.
    const broken: Address = "0x000000000000000000000000000000000000b0b0";
    await clients().test.setCode({ address: broken, bytecode: "0x5f5ffd" });
    await listQuote(broken, STOCK_START_TICK);
    const unwritable = await launchCoin(await evmWallet(), { quote: broken });
    const nul = await launchCoin(await evmWallet(), { name: "Nul\u0000Coin\u0007", symbol: "N\u0000L" });
    const after = await launchCoin(await evmWallet());

    const run = await runIndexer();
    expect(run.status).toBe("succeeded");
    const skipped = (run.summary as { chains: { skipped: { hash: string }[] }[] }).chains[0]!.skipped;
    expect(skipped.map((s) => s.hash)).toEqual([unwritable.receipt.transactionHash]);
    expect((await operatorAlerts()).find((a) => a.subject === unwritable.receipt.transactionHash)).toMatchObject({ kind: "indexer_skipped" });

    expect(LaunchSummary.parse(await api(`/v1/launches/${nul.coin}`))).toMatchObject({ name: "NulCoin", symbol: "NL" });
    expect(LaunchSummary.parse(await api(`/v1/launches/${after.coin}`)).chain).toBe("robinhood");
    expect((await fetch(`${env().apiUrl}/v1/launches/${unwritable.coin}`)).status).toBe(404);
    // And the next run goes on from there rather than meeting it again.
    expect((await runIndexer()).status).toBe("succeeded");
  });

  test("an address in any case finds the coin, its trades and its Creator's coins", async () => {
    const creator = await evmWallet();
    const l = await launchCoin(creator, { firstBuy: 10n ** 15n });
    await runIndexer();
    for (const form of [l.coin.toLowerCase(), `0x${l.coin.slice(2).toUpperCase()}`]) {
      expect(LaunchSummary.parse(await api(`/v1/launches/${form}`)).mint).toBe(l.coin);
      expect(TradeList.parse(await api(`/v1/launches/${form}/trades`)).trades.length).toBe(1);
      expect(((await api(`/v1/launches/${form}/candles?interval=1d`)) as { candles: unknown[] }).candles.length).toBe(1);
    }
    const byCreator = (await api(`/v1/launches?creator=${creator.address.toLowerCase()}`)) as { launches: { mint: string }[] };
    expect(byCreator.launches.map((x) => x.mint)).toEqual([l.coin]);
    const byQuote = (await api(`/v1/launches?chain=robinhood&quote=${NATIVE}&limit=100`)) as { launches: { mint: string }[] };
    expect(byQuote.launches.map((x) => x.mint)).toContain(l.coin);
  });

  test("two trades in one block are ordered by the log, in the list and in the candle", async () => {
    const a = await evmWallet();
    const b = await evmWallet();
    const l = await launchCoin(await evmWallet());
    const t = clients().test;
    let receipts;
    await t.setAutomine(false);
    try {
      const sent = [swapExactIn(a, l, "buy", 10n ** 16n), swapExactIn(b, l, "buy", 2n * 10n ** 16n)];
      // Both waiting in the pool, then one block for the two.
      for (let i = 0; i < 100 && (await t.getTxpoolStatus()).pending < 2; i++) await new Promise((r) => setTimeout(r, 100));
      await t.mine({ blocks: 1 });
      receipts = (await Promise.all(sent)).map((x) => x.receipt);
    } finally {
      await t.setAutomine(true);
    }
    expect(receipts[0]!.blockNumber).toBe(receipts[1]!.blockNumber);
    await runIndexer();
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    // Newest first, by the order the two ran in the block (their logs'), whatever their hashes.
    const ran = [...receipts].sort((x, y) => x.transactionIndex - y.transactionIndex).map((r) => r.from.toLowerCase());
    expect(trades.map((x) => x.trader.toLowerCase())).toEqual([...ran].reverse());
    const { candles } = (await api(`/v1/launches/${l.coin}/candles?interval=1d`)) as { candles: { close: number }[] };
    expect(candles.at(-1)!.close).toBe(trades[0]!.price);
  });

  test("the Tax Vault's buy is its own, never the caller's, and its burn lowers the coin's supply", async () => {
    const trader = await evmWallet();
    const stranger = await evmWallet();
    const l = await launchCoin(await evmWallet(), { reward: { taxBps: 500, burnShareBps: 5000, liquidityShareBps: 0 } });
    await swapExactIn(trader, l, "buy", 5n * 10n ** 16n);
    // A burn waits while the price stands above the Reference Price (#271) by more than the stack's band: the trader sells
    // it all back, which returns the pool to its opening price, where the reference stands. Both trades paid the tax.
    // The fork's clock is never moved here: every later coin would be dated in the future and top the board.
    await swapExactIn(trader, l, "sell", await balanceOf(l.coin, trader.address));
    const vault = inject("harness").evm!.taxVault;
    const hash = await clients().wallet(stranger.key).writeContract({ address: vault, abi: taxVaultAbi, functionName: "burn", args: [l.key], gas: SWAP_GAS });
    const burnt = await clients().public.waitForTransactionReceipt({ hash });
    expect(burnt.status, burnt.status === "success" ? "" : await whyReverted(hash)).toBe("success");
    const supply = await clients().public.readContract({ address: l.coin, abi: erc20Abi, functionName: "totalSupply" });

    const run = await runIndexer();
    expect((run.summary as { chains: { burned: number }[] }).chains[0]!.burned).toBe(1);
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    const burnBuy = trades.find((x) => x.signature === hash)!;
    expect(burnBuy).toMatchObject({ side: "buy", trader: vault });
    expect(trades.map((x) => x.trader)).not.toContain(stranger.address);
    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.supply).toBe(supply.toString());
    expect(BigInt(coin.supply)).toBeLessThan(10n ** 30n - BigInt(burnBuy.baseAmount) + 1n);
    // The vault is never a holder, and the trader sold out: nobody holds the coin by its trades.
    expect(coin.market.holders).toBe(0);
  });

  test("every Solana job succeeds with EVM coins on the board, whatever the order of the files", async () => {
    const trader = await evmWallet();
    const reward = await launchCoin(await evmWallet(), { reward: { taxBps: 300, burnShareBps: 0, liquidityShareBps: 0 }, firstBuy: 10n ** 15n });
    await launchCoin(await evmWallet(), { firstBuy: 10n ** 15n });
    await swapExactIn(trader, reward, "buy", 10n ** 16n);
    await runIndexer();
    for (const job of ["quote-registry", "fee-collector", "creator-forward", "rebates", "reward-rounds", "burn", "metadata-upload", "mentions"]) {
      const res = await fetch(`${env().apiUrl}/v1/operator/jobs/${job}`, { method: "POST", headers: operator() });
      expect(res.status, `${job}: ${await res.clone().text()}`).toBe(200);
      expect(((await res.json()) as { status: string }).status, job).toMatch(/succeeded|skipped/);
    }
    // The every-minute tick: the graduation watch, the tax lock, the metadata upload, then the Indexer.
    const tick = await fetch(`${env().apiUrl}/__scheduled?cron=${encodeURIComponent(GRADUATION_WATCH_CRON)}`);
    expect(tick.status).toBe(200);
    for (const job of ["graduation-watch", "reward-tax-lock", "metadata-upload", "indexer"]) {
      const res = await fetch(`${env().apiUrl}/v1/operator/jobs?job=${job}`, { headers: operator() });
      const { runs } = (await res.json()) as { runs: { status: string }[] };
      expect(runs[0]?.status, job).toMatch(/succeeded|skipped/);
    }
  });
});

describe.skipIf(!hasEvm)("EVM chain: a stricter RPC, a run's budget, and a deployment the API cannot read", () => {
  let strict: Awaited<ReturnType<typeof strictRpc>>;
  let strictApi: Awaited<ReturnType<typeof startApi>>;
  let brokenApi: Awaited<ReturnType<typeof startApi>>;

  beforeAll(async () => {
    const e = inject("harness");
    strict = await strictRpc(10);
    const deployment = JSON.parse(e.apiVars.EVM_DEPLOYMENTS!) as Record<string, unknown>[];
    const [strictPort, brokenPort] = [await freePort(), await freePort()];
    [strictApi, brokenApi] = await Promise.all([
      // The same deployment and database behind a provider that refuses ranges past 10 blocks, with a run's budget of 3 ranges.
      startApi({
        port: strictPort, databaseUrl: e.databaseUrl,
        vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${strictPort}`, ROBINHOOD_RPC_URL: strict.url, EVM_DEPLOYMENTS: JSON.stringify([{ ...deployment[0], maxRangesPerRun: 3 }]) },
      }),
      // A deployment named twice, which the API refuses.
      startApi({
        port: brokenPort, databaseUrl: e.databaseUrl,
        vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${brokenPort}`, EVM_DEPLOYMENTS: JSON.stringify([deployment[0], deployment[0]]) },
      }),
    ]);
  }, 240_000);

  afterAll(async () => {
    await Promise.all([strictApi?.stop(), brokenApi?.stop(), strict?.stop()]);
  });

  test("a provider that refuses a wide range has it halved, and a run stops at its budget and the next goes on", async () => {
    // A cursor at the stack's 2,000-block range, and a hundred blocks to read.
    await runIndexer();
    await clients().test.mine({ blocks: 100 });
    const l = await launchCoin(await evmWallet());

    const first = (await runIndexer(strictApi.url)) as { status: string; summary: { chains: { from: number; to: number; logBlockRange: number; leftForLater: boolean }[] } };
    expect(first.status).toBe("succeeded");
    const run = first.summary.chains[0]!;
    expect(run.logBlockRange).toBeLessThanOrEqual(10);
    expect(run.leftForLater).toBe(true);
    expect(run.to - run.from + 1).toBeLessThanOrEqual(30);
    expect(strict.state.getLogsRanges.some((r) => r > 10)).toBe(true);

    // Run after run, three ranges each, it reaches the coin.
    for (let i = 0; i < 20; i++) {
      const next = (await runIndexer(strictApi.url)) as { summary: { chains: { leftForLater: boolean }[] } };
      if (!next.summary.chains[0]!.leftForLater) break;
    }
    expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).chain).toBe("robinhood");
    // The size that worked is kept: no later range asked for more than 10.
    const sinceShrunk = strict.state.getLogsRanges.slice(strict.state.getLogsRanges.findIndex((r) => r <= 10));
    expect(sinceShrunk.every((r) => r <= 10)).toBe(true);
  });

  test("a failed read of a Stock Token's multiplier fails the run instead of losing the multiplier, and the next run has it", async () => {
    await listQuote(AAPL, STOCK_START_TICK);
    // Through the strict API alone, so the stack's own API does not read the asset first.
    let behind = true;
    for (let i = 0; i < 40 && behind; i++) {
      const caught = (await runIndexer(strictApi.url)) as { summary: { chains: { leftForLater: boolean }[] } };
      behind = caught.summary.chains[0]!.leftForLater;
    }
    expect(behind).toBe(false);
    const l = await launchCoin(await evmWallet(), { quote: AAPL });
    // Deep enough to be read, then read while every multiplier read fails.
    await clients().test.mine({ blocks: ROBINHOOD_CHAIN.finalityDepth });
    strict.state.failMultiplier = true;
    const res = await fetch(`${strictApi.url}/v1/operator/jobs/indexer`, { method: "POST", headers: operator() });
    expect(res.status).toBe(500);
    expect((await fetch(`${env().apiUrl}/v1/launches/${l.coin}`)).status).toBe(404);

    strict.state.failMultiplier = false;
    expect(((await runIndexer(strictApi.url)) as { status: string }).status).toBe("succeeded");
    const multiplier = await clients().public.readContract({ address: AAPL, abi: parseAbi(["function uiMultiplier() view returns (uint256)"]), functionName: "uiMultiplier" });
    expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).quote).toMatchObject({ multiplier: multiplier.toString(), category: "tokenized_stock" });
  });

  test("a deployment the API cannot read leaves Solana's answers whole, and the Indexer's run names why", async () => {
    const { chains } = ChainList.parse(await api("/v1/chains", brokenApi.url));
    expect(chains.map((c) => c.chain)).toEqual(["solana"]);
    const res = await fetch(`${brokenApi.url}/v1/operator/jobs/indexer`, { method: "POST", headers: operator() });
    expect(res.status).toBe(500);
    expect(((await res.json()) as { error: string }).error).toContain("names robinhood twice");
    // Solana's board answers the same through it as through the stack's own API.
    // (each API names its own URL in a coin's image, so the coins are compared by address)
    const mints = async (base: string) => ((await api("/v1/launches?chain=solana&limit=20", base)) as { launches: { mint: string }[] }).launches.map((x) => x.mint);
    expect(await mints(brokenApi.url)).toEqual(await mints(env().apiUrl));
  });
});

/**
 * Graduation (#244) needs the price held at the Graduation Target for an hour of the chain's own time, and moving the
 * stack's fork's clock would date every later coin in the future on the shared board; so this runs on a fork, a
 * database and an API of its own.
 */
describe.skipIf(!hasEvm || !process.env.ROBINHOOD_RPC_URL)("EVM chain: Graduation, on a fork of its own", () => {
  let anvil: ChildProcess;
  let fork: EvmStackEnv;
  let api3: Awaited<ReturnType<typeof startApi>>;
  const database = `launchpad_graduation_${process.pid}`;

  beforeAll(async () => {
    const e = inject("harness");
    const port = await freePort();
    anvil = spawn("anvil", forkArgs(process.env.ROBINHOOD_RPC_URL!, port), { stdio: "ignore" });
    const rpcUrl = `http://127.0.0.1:${port}`;
    for (let i = 0; i < 400; i++) {
      const up = await fetch(rpcUrl, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_chainId", params: [] }) })
        .then((r) => r.ok)
        .catch(() => false);
      if (up) break;
      await new Promise((r) => setTimeout(r, 300));
    }
    fork = await deployStoker(rpcUrl);
    const admin = postgres(e.databaseAdminUrl, { max: 1, onnotice: () => {} });
    await admin.unsafe(`create database "${database}" owner launchpad_stack`);
    await admin.end();
    const url = new URL(e.databaseUrl);
    url.pathname = `/${database}`;
    await runMigrations(url.toString());
    const apiPort = await freePort();
    api3 = await startApi({
      port: apiPort, databaseUrl: url.toString(),
      vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${apiPort}`, ROBINHOOD_RPC_URL: rpcUrl, EVM_DEPLOYMENTS: JSON.stringify(deploymentOf(fork)) },
    });
  }, 300_000);

  afterAll(async () => {
    await api3?.stop();
    anvil?.kill("SIGTERM");
    const admin = postgres(inject("harness").databaseAdminUrl, { max: 1, onnotice: () => {} });
    await admin.unsafe(`drop database if exists "${database}" with (force)`).catch(() => undefined);
    await admin.end();
  });

  test("a coin that holds its Graduation Target for the Graduation Hold is graduated, with the transaction that recorded it", async () => {
    await onFork(fork, async () => {
      const trader = await evmWallet(1_000n);
      const l = await launchCoin(await evmWallet());
      // Well past twenty times the start price: the whole supply opens worth about 1.7 ETH.
      await swapExactIn(trader, l, "buy", 50n * 10n ** 18n);
      await runIndexer(api3.url);
      expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`, api3.url)).graduation).toBeNull();

      // An hour of the fork's time later, the next swap records Graduation, once.
      await clients().test.increaseTime({ seconds: 3_601 });
      await clients().test.mine({ blocks: 1 });
      const { receipt } = await swapExactIn(trader, l, "buy", 10n ** 15n);
      const run = (await runIndexer(api3.url)) as { summary: { chains: { graduated: number }[] } };
      expect(run.summary.chains[0]!.graduated).toBe(1);
      const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`, api3.url));
      expect(coin.graduation).toMatchObject({ pool: l.poolId, signature: receipt.transactionHash, fee: null, creatorTier: null });
      expect(coin.curve.status).toBe("graduated");
    });
  });
});
