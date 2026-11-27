// #252, the main session's review of 2026-11-24: what keeps an EVM chain's Indexer fit to run against a real chain, and
// Solana's jobs whole beside it. Every test here needs the stack's fork of Robinhood Chain and skips by name without it.
import { afterAll, beforeAll, describe, expect, inject, test } from "vitest";
import { erc20Abi, parseAbi, toFunctionSelector, type Address } from "viem";
import { ChainList, CopyCheck, IndexerFailureList, IndexerReplay, LaunchList, LaunchSummary, OperatorOverview, PlatformStats, TradeList } from "@launchpad/contract";
import { NATIVE, ROBINHOOD_CHAIN, taxVaultAbi } from "@launchpad/evm";
import { migrateCurve } from "@launchpad/localnet";
import {
  BURN_CRON, deployStoker, deploymentOf, FEE_COLLECTOR_CRON, freePort, GRADUATION_WATCH_CRON, QUOTE_REGISTRY_CRON, REWARD_ROUNDS_CRON, startApi, startRpcStandIn, startStack,
  type EvmStackEnv, type RpcStandIn, type StackEnv,
} from "@launchpad/stack";
import { connection, deliverWebhook, env, fundedWallet, launchedCoin, onStack, prepare, signAndSend, SOL, trade } from "./client";
import { balanceOf, buyBoth, clients, onFork, SWAP_GAS, whyReverted, evmWallet, launchCoin, listQuote, operatorAlerts, runIndexer, swapExactIn } from "./evm";

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
  test("a transaction that can never be written is tried on three runs, then set aside under the chain's one alert, and a replay writes it once it can be", async () => {
    await runIndexer();
    // A Quote Asset whose every call reverts: it can be listed and launched against without a First Buy, and the Indexer
    // can never read its decimals. The node says revert each time, which is a fact about the contract.
    const broken: Address = "0x000000000000000000000000000000000000b0b0";
    await clients().test.setCode({ address: broken, bytecode: "0x5f5ffd" });
    await listQuote(broken, STOCK_START_TICK);
    const unwritable = await launchCoin(await evmWallet(), { quote: broken });
    const after = await launchCoin(await evmWallet());

    const indexer = async () => {
      await clients().test.mine({ blocks: ROBINHOOD_CHAIN.finalityDepth });
      const res = await fetch(`${env().apiUrl}/v1/operator/jobs/indexer`, { method: "POST", headers: operator() });
      const job = (await res.json()) as { status: string; summary: { chains: { failed: { hash: string; attempts: number } | null; skipped: { hash: string }[] }[] } };
      return { status: job.status, run: job.summary.chains[0]! };
    };
    // Twice the run stops on it, to be read again a minute later: a node may be wrong once.
    for (const attempts of [1, 2]) expect(await indexer()).toMatchObject({ status: "failed", run: { failed: { hash: unwritable.receipt.transactionHash, attempts }, skipped: [] } });
    expect((await fetch(`${env().apiUrl}/v1/launches/${after.coin}`)).status).toBe(404);
    const third = await indexer();
    expect(third.status).toBe("succeeded");
    expect(third.run.skipped.map((x) => x.hash)).toEqual([unwritable.receipt.transactionHash]);
    expect(LaunchSummary.parse(await api(`/v1/launches/${after.coin}`)).chain).toBe("robinhood");
    expect((await fetch(`${env().apiUrl}/v1/launches/${unwritable.coin}`)).status).toBe(404);
    // And the next run goes on from there rather than meeting it again.
    expect(await indexer()).toMatchObject({ status: "succeeded", run: { failed: null, skipped: [] } });

    const failures = async () => IndexerFailureList.parse(await (await fetch(`${env().apiUrl}/v1/operator/indexer/failures?chain=robinhood`, { headers: operator() })).json()).failures;
    const open = await failures();
    expect(open.find((f) => f.transaction === unwritable.receipt.transactionHash)).toMatchObject({ attempts: 3, block: Number(unwritable.receipt.blockNumber), setAsideAt: expect.any(String) });
    const alerts = (await operatorAlerts()).filter((a) => a.kind === "indexer_skipped");
    expect(alerts).toEqual([expect.objectContaining({ subject: "robinhood", resolvedAt: null, message: expect.stringContaining(`set aside ${open.length} transaction`) })]);

    // The asset is mended (it answers 18 to every call, so it has decimals), and the operator replays the transaction.
    await clients().test.setCode({ address: broken, bytecode: "0x60125f5260205ff3" });
    const res = await fetch(`${env().apiUrl}/v1/operator/indexer/replay`, {
      method: "POST", headers: { ...operator(), "content-type": "application/json" }, body: JSON.stringify({ chain: "robinhood", transaction: unwritable.receipt.transactionHash }),
    });
    expect(IndexerReplay.parse(await res.json())).toMatchObject({ launched: 1, resolved: 1, failed: [], next: null });
    expect(LaunchSummary.parse(await api(`/v1/launches/${unwritable.coin}`)).quote).toMatchObject({ mint: broken, decimals: 18, symbol: null });
    const left = await failures();
    expect(left.map((f) => f.transaction)).not.toContain(unwritable.receipt.transactionHash);
    const alert = (await operatorAlerts()).find((a) => a.kind === "indexer_skipped" && a.subject === "robinhood")!;
    if (left.length === 0) expect(alert.resolvedAt).not.toBeNull();
    // A replay of what is already written writes nothing twice.
    const again = await fetch(`${env().apiUrl}/v1/operator/indexer/replay`, {
      method: "POST", headers: { ...operator(), "content-type": "application/json" }, body: JSON.stringify({ chain: "robinhood", fromBlock: Number(unwritable.receipt.blockNumber), toBlock: Number(after.receipt.blockNumber) }),
    });
    expect(IndexerReplay.parse(await again.json())).toMatchObject({ launched: 0, traded: 0, resolved: 0, failed: [], next: null });
    for (const bad of [{ chain: "robinhood" }, { chain: "solana", fromBlock: 1 }, { chain: "robinhood", transaction: "0x12" }]) {
      const refused = await fetch(`${env().apiUrl}/v1/operator/indexer/replay`, { method: "POST", headers: { ...operator(), "content-type": "application/json" }, body: JSON.stringify(bad) });
      expect(refused.status, JSON.stringify(bad)).toBe(400);
    }
    expect((await fetch(`${env().apiUrl}/v1/operator/indexer/replay`, { method: "POST", body: "{}" })).status).toBe(401);
  });

  test("a coin's name and ticker are stored without characters that hide or reorder text, and never empty", async () => {
    // A NUL and a bell (Postgres refuses the first), a right-to-left override, a zero-width space and joiner, a C1 control.
    const dressed = await launchCoin(await evmWallet(), { name: "Nul\u0000Coin\u0007 \u202Egnp.exe\u200B\u200D\u0085", symbol: "N\u0000\u202EL\u200B" });
    // Nothing a page can show: only invisible characters and letters that draw as nothing (a Hangul filler, the blank
    // Braille pattern), and only spaces.
    const unnamed = await launchCoin(await evmWallet(), { name: "\u200B\u202E\u2060\uFEFF\u3164\u2800", symbol: " \u115F\uFFA0 " });
    await runIndexer();
    expect(LaunchSummary.parse(await api(`/v1/launches/${dressed.coin}`))).toMatchObject({ name: "NulCoin gnp.exe", symbol: "NL" });
    // A coin with no name of its own goes by its address, as an explorer shows one.
    const short = `${unnamed.coin.slice(0, 6)}...${unnamed.coin.slice(-4)}`;
    expect(LaunchSummary.parse(await api(`/v1/launches/${unnamed.coin}`))).toMatchObject({ name: short, symbol: short });
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
    // The board's search too, by the whole address or its start, as a wallet or an explorer writes it.
    for (const q of [l.coin, l.coin.toLowerCase(), `0x${l.coin.slice(2).toUpperCase()}`, l.coin.toLowerCase().slice(0, 12)]) {
      expect(LaunchList.parse(await api(`/v1/launches?q=${q}`)).launches.map((x) => x.mint), q).toEqual([l.coin]);
    }
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
    // The vault buys nothing while the Launch's Opening Fee runs (#246): its 20 seconds pass in real time, since moving
    // the shared fork's clock would date every later coin in the future.
    await new Promise((r) => setTimeout(r, 21_000));
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

  test("a burn anyone funded lowers the coin's supply as the coin's own Reward Burn does", async () => {
    // A standard coin has no tax to burn: what burns is what a wallet gave its burn (#248), as a Creator Earnings
    // Destination of the burn does with its coin's earnings.
    const funder = await evmWallet();
    const l = await launchCoin(await evmWallet());
    await runIndexer();
    const launched = BigInt(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).supply);
    // The vault buys nothing while the Launch's Opening Fee runs (#246).
    await new Promise((r) => setTimeout(r, 21_000));
    const vault = inject("harness").evm!.taxVault;
    const wallet = clients().wallet(funder.key);
    const funded = await clients().public.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: vault, abi: taxVaultAbi, functionName: "fundBurn", args: [l.key, 10n ** 15n], value: 10n ** 15n, gas: SWAP_GAS }) });
    expect(funded.status).toBe("success");
    const hash = await wallet.writeContract({ address: vault, abi: taxVaultAbi, functionName: "burn", args: [l.key], gas: SWAP_GAS });
    const burnt = await clients().public.waitForTransactionReceipt({ hash });
    expect(burnt.status, burnt.status === "success" ? "" : await whyReverted(hash)).toBe("success");
    const supply = await clients().public.readContract({ address: l.coin, abi: erc20Abi, functionName: "totalSupply" });
    expect(supply).toBeLessThan(launched);

    const run = await runIndexer();
    expect((run.summary as { chains: { burned: number }[] }).chains[0]!.burned).toBe(1);
    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.supply).toBe(supply.toString());
    // The buy is the vault's own trade, never the funder's.
    expect(TradeList.parse(await api(`/v1/launches/${l.coin}/trades`)).trades.map((t) => [t.signature, t.trader])).toEqual([[hash, vault]]);
  });

  test("Copy Protection on Solana does not read an EVM coin: a name and a ticker one edit from one stay free there", async () => {
    // Launched straight on the factory, for the chain's gas: nothing of ours prepared it.
    const tag = Array.from(crypto.getRandomValues(new Uint8Array(5)), (b) => "ABCDEFGHJKLMNPQRSTUVWXYZ"[b % 24]).join("");
    await launchCoin(await evmWallet(), { name: `Doggo ${tag}x`, symbol: `DG${tag}X` });
    await runIndexer();
    const creator = await fundedWallet();
    for (const [name, symbol] of [[`Doggo ${tag}`, `DG${tag}`], [`Doggo ${tag}x`, `DG${tag}X`]]) {
      const form = new FormData();
      for (const [k, v] of Object.entries({ name: name!, symbol: symbol!, creator: creator.publicKey.toBase58() })) form.set(k, v);
      const check = CopyCheck.parse(await (await fetch(`${env().apiUrl}/v1/launches/check`, { method: "POST", body: form })).json());
      expect([check.name?.status, check.symbol?.status], symbol).toEqual(["free", "free"]);
    }
    // A Solana launch of the near name is prepared, launched and carries no label naming the EVM coin.
    const res = await prepare({ creator: creator.publicKey.toBase58(), name: `Doggo ${tag}`, symbol: `DG${tag}`, exact: true });
    expect(res.status, await res.clone().text()).toBe(200);
    const prepared = (await res.json()) as { mint: string; transaction: string; lastValidBlockHeight: number };
    const signature = await signAndSend(prepared, creator);
    expect((await deliverWebhook([signature])).status).toBe(200);
    expect(LaunchSummary.parse(await api(`/v1/launches/${prepared.mint}`)).copyOf).toBeNull();
  });

  test("the platform's figures and the operator's counts are one chain's: Solana's unless a chain is named", async () => {
    await launchCoin(await evmWallet(), { firstBuy: 10n ** 15n });
    await runIndexer();
    const stats = (q = "") => api(`/v1/stats${q}`).then((x) => PlatformStats.parse(x));
    const overview = async (q = "") => OperatorOverview.parse(await (await fetch(`${env().apiUrl}/v1/operator/overview${q}`, { headers: operator() })).json());
    const count = async (chain: string) => {
      let n = 0;
      for (let offset = 0; ; offset += 100) {
        const page = LaunchList.parse(await api(`/v1/launches?chain=${chain}&limit=100&offset=${offset}`)).launches;
        n += page.length;
        if (page.length < 100) return n;
      }
    };
    const [solana, robinhood] = [await count("solana"), await count("robinhood")];
    expect(robinhood).toBeGreaterThan(0);
    // With no chain named the figures are Solana's, as they were before any EVM chain: its volume is priced in SOL.
    expect(await stats()).toEqual(await stats("?chain=solana"));
    expect((await stats()).launches).toBe(solana);
    const evm = await stats("?chain=robinhood");
    expect(evm.launches).toBe(robinhood);
    // An EVM chain's Quote Assets have no price until its jobs (#254): a traded day is unknown, never zero.
    expect(evm.volume24h).toEqual({ sol: null, usd: null });
    expect((await overview()).launches).toEqual((await overview("?chain=solana")).launches);
    expect((await overview()).launches.total).toBe(solana);
    expect((await overview("?chain=robinhood")).launches).toMatchObject({ total: robinhood, byStatus: { graduating: 0 } });
    expect((await fetch(`${env().apiUrl}/v1/stats?chain=nowhere`)).status).toBe(400);
  });

  test("every Solana job succeeds with EVM coins on the board, whatever the order of the files", async () => {
    const trader = await evmWallet();
    const reward = await launchCoin(await evmWallet(), { reward: { taxBps: 300, burnShareBps: 0, liquidityShareBps: 0 }, firstBuy: 10n ** 15n });
    await launchCoin(await evmWallet(), { firstBuy: 10n ** 15n });
    await swapExactIn(trader, reward, "buy", 10n ** 16n);
    await runIndexer();
    // Every job other files run freely. The Burn and the rebates are not run here: a run spends the Burn's and the
    // Flywheel's budgets and settles Rebate Weeks, which `burn.test.ts` and `rebates.test.ts` assert from their own
    // first run (the first run of this test before them failed `burn.test.ts`). Their pages read through the same
    // scoped queries (the Flywheel's picks, the week being traded), and must answer with no EVM coin in them.
    const burns = (await api("/v1/burns")) as { nextFlywheel: { mint: string }[] };
    expect(burns.nextFlywheel.every((p) => !p.mint.startsWith("0x"))).toBe(true);
    expect((await fetch(`${env().apiUrl}/v1/rebates`)).status).toBe(200);
    for (const job of ["quote-registry", "fee-collector", "creator-forward", "reward-rounds", "metadata-upload", "mentions"]) {
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
  let strict: RpcStandIn;
  let strictApi: Awaited<ReturnType<typeof startApi>>;
  let brokenApi: Awaited<ReturnType<typeof startApi>>;

  beforeAll(async () => {
    const e = inject("harness");
    strict = await startRpcStandIn(e.evm!.rpcUrl, await freePort());
    strict.behaviour.maxLogRange = 10;
    const deployment = JSON.parse(e.apiVars.EVM_DEPLOYMENTS!) as Record<string, unknown>[];
    const [strictPort, brokenPort] = [await freePort(), await freePort()];
    [strictApi, brokenApi] = await Promise.all([
      // The same deployment and database behind a provider that refuses ranges past 10 blocks, with a run's budget of 8
      // ranges. Its range setting is its own, so what it learns of this provider is forgotten by the stack's own API.
      startApi({
        port: strictPort, databaseUrl: e.databaseUrl,
        vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${strictPort}`, ROBINHOOD_RPC_URL: strict.url, EVM_DEPLOYMENTS: JSON.stringify([{ ...deployment[0], logBlockRange: 1_999, maxRangesPerRun: 8 }]) },
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
    // A cursor at a range of thousands of blocks, and a hundred blocks to read.
    await runIndexer();
    await clients().test.mine({ blocks: 100 });
    const l = await launchCoin(await evmWallet());

    const first = (await runIndexer(strictApi.url)) as { status: string; summary: { chains: { from: number; to: number; logBlockRange: number; leftForLater: boolean }[] } };
    expect(first.status).toBe("succeeded");
    const run = first.summary.chains[0]!;
    expect(run.logBlockRange).toBeLessThanOrEqual(10);
    expect(run.leftForLater).toBe(true);
    expect(run.to - run.from + 1).toBeLessThanOrEqual(80);
    expect(strict.logRanges.some((r) => r > 10)).toBe(true);

    // Run after run, eight ranges each, it reaches the coin.
    for (let i = 0; i < 30; i++) {
      const next = (await runIndexer(strictApi.url)) as { summary: { chains: { leftForLater: boolean }[] } };
      if (!next.summary.chains[0]!.leftForLater) break;
    }
    expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).chain).toBe("robinhood");
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
    const outage = strict.fail({ method: "eth_call", data: toFunctionSelector("uiMultiplier()"), fault: { http: 503 } });
    const res = await fetch(`${strictApi.url}/v1/operator/jobs/indexer`, { method: "POST", headers: operator() });
    expect(res.status).toBe(500);
    expect((await fetch(`${env().apiUrl}/v1/launches/${l.coin}`)).status).toBe(404);

    outage.stop();
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
 * A factory deployed again on the same chain (#279): the API reads the new deployment, and the coins of the old one
 * stay in the database. A transaction that trades in a pool of each is read for the new deployment's pool alone.
 */
describe.skipIf(!hasEvm)("EVM chain: a factory deployed again", () => {
  let second: EvmStackEnv;
  let secondApi: Awaited<ReturnType<typeof startApi>>;

  beforeAll(async () => {
    const e = inject("harness");
    second = await deployStoker(e.evm!.rpcUrl, { setClock: false });
    const port = await freePort();
    secondApi = await startApi({
      port, databaseUrl: e.databaseUrl, vars: { ...e.apiVars, PUBLIC_API_URL: `http://127.0.0.1:${port}`, EVM_DEPLOYMENTS: JSON.stringify(deploymentOf(second)) },
    });
  }, 240_000);

  afterAll(async () => {
    await secondApi?.stop();
  });

  test("a transaction that trades in an old deployment's pool and a new one's is written for the new one, and nothing is set aside", async () => {
    const old = await launchCoin(await evmWallet());
    await runIndexer();
    const fresh = await onFork(second, async () => launchCoin(await evmWallet()));
    const trader = await evmWallet();
    const receipt = await buyBoth(trader, [old, fresh], 10n ** 15n);

    const run = (await runIndexer(secondApi.url)) as { status: string; summary: { chains: { launched: number; traded: number; skipped: unknown[]; failed: unknown }[] } };
    expect(run.status).toBe("succeeded");
    expect(run.summary.chains[0]).toMatchObject({ launched: 1, traded: 1, skipped: [], failed: null });
    const trades = (coin: string) => api(`/v1/launches/${coin}/trades`).then((x) => TradeList.parse(x).trades.map((t) => t.signature));
    expect(await trades(fresh.coin)).toEqual([receipt.transactionHash]);
    // The old deployment's Indexer reads the same transaction for its own pool, and it too sets nothing aside.
    const mine = (await runIndexer()) as { status: string; summary: { chains: { traded: number; skipped: unknown[] }[] } };
    expect(mine.summary.chains[0]).toMatchObject({ traded: 1, skipped: [] });
    expect(await trades(old.coin)).toEqual([receipt.transactionHash]);
  }, 180_000);
});

/**
 * A stack of its own (#279): Graduation (#244) needs the price held at the Graduation Target for an hour of the chain's
 * own time, and moving the suite's fork's clock would date every later coin in the future on the shared board; and
 * every Solana job is run here to its end, the Burn and the rebates too, which on the suite's stack would spend what
 * `burn.test.ts` and `rebates.test.ts` assert. So this has its own chain, fork, database and API, and nothing here
 * depends on the order of the files.
 */
describe.skipIf(!hasEvm || !process.env.ROBINHOOD_RPC_URL)("EVM chain: Graduation, and every Solana job beside it, on a stack of its own", () => {
  let own: { env: StackEnv; stop: () => Promise<void> };
  const get = (path: string) => api(path, own.env.apiUrl);
  const operatorGet = async (path: string) => (await fetch(`${own.env.apiUrl}${path}`, { headers: { authorization: `Bearer ${own.env.operatorToken}` } })).json();
  /** What a visitor to the Solana site reads: the board in each order, the Quote Assets in use, the Ledger, the figures. */
  const solanaPages = async (filter: string) => {
    const q = (path: string) => `${path}${path.includes("?") ? "&" : "?"}${filter}`.replace(/[?&]$/, "");
    const pages: Record<string, unknown> = {};
    for (const path of ["/v1/launches?limit=100", "/v1/launches?limit=100&sort=market_cap", "/v1/launches?limit=100&sort=trending", "/v1/launches?limit=100&sort=graduation", "/v1/launches/quotes", "/v1/ledger", "/v1/burns", "/v1/rebates"]) {
      pages[path] = await get(q(path));
    }
    return pages;
  };

  beforeAll(async () => {
    own = await startStack();
  }, 600_000);

  afterAll(async () => {
    await own?.stop();
  });

  test("a coin that holds its Graduation Target for the Graduation Hold is graduated, and Solana's pages and jobs are what they were without it", async () => {
    await onStack(own.env, async () => {
      // Solana first: a coin graduated into its pool, and a Reward Launch that has traded, each indexed.
      const sold = await launchedCoin();
      const buyer = await fundedWallet(10);
      const buyout = await trade(buyer, sold.mint, "buy", SOL(2));
      await deliverWebhook([buyout.signature]);
      const migration = await migrateCurve(connection(), sold.pool);
      await deliverWebhook([migration.signature]);
      const creator = await fundedWallet();
      const reward = (await (await prepare({ creator: creator.publicKey.toBase58(), rewardTax: "300" })).json()) as { mint: string; transaction: string; lastValidBlockHeight: number };
      await deliverWebhook([await signAndSend(reward, creator)]);
      const bought = await trade(buyer, reward.mint, "buy", SOL(0.2));
      await deliverWebhook([bought.signature]);
      const cron = async (expression: string) => expect((await fetch(`${own.env.apiUrl}/__scheduled?cron=${encodeURIComponent(expression)}`)).status, expression).toBe(200);
      for (const expression of [GRADUATION_WATCH_CRON, FEE_COLLECTOR_CRON]) await cron(expression);

      // Before any EVM coin exists: what each page answers, with no chain named and with Solana named.
      const before = await solanaPages("");
      expect(await solanaPages("chain=solana")).toEqual(before);
      const statsBefore = PlatformStats.parse(await get("/v1/stats"));
      const overviewBefore = OperatorOverview.parse(await operatorGet("/v1/operator/overview"));
      expect(statsBefore).toMatchObject({ launches: 2, graduated: 1 });

      // The EVM chain: a standard coin, a Reward Launch, and a coin that graduates.
      const trader = await evmWallet(1_000n);
      const standard = await launchCoin(await evmWallet(), { firstBuy: 10n ** 15n });
      const taxed = await launchCoin(await evmWallet(), { reward: { taxBps: 300, burnShareBps: 1000, liquidityShareBps: 1000 } });
      const l = await launchCoin(await evmWallet());
      // Past the Opening Fee's 20 seconds (#246) on this fork's own clock, then well past twenty times the start price:
      // the whole supply opens worth about 1.7 ETH.
      await clients().test.increaseTime({ seconds: 21 });
      await clients().test.mine({ blocks: 1 });
      await swapExactIn(trader, taxed, "buy", 10n ** 16n);
      await swapExactIn(trader, l, "buy", 50n * 10n ** 18n);
      await runIndexer();
      expect(LaunchSummary.parse(await get(`/v1/launches/${l.coin}`)).graduation).toBeNull();

      // An hour of the fork's time later, the next swap records Graduation, once.
      await clients().test.increaseTime({ seconds: 3_601 });
      await clients().test.mine({ blocks: 1 });
      const { receipt } = await swapExactIn(trader, l, "buy", 10n ** 15n);
      const run = (await runIndexer()) as { summary: { chains: { graduated: number }[] } };
      expect(run.summary.chains[0]!.graduated).toBe(1);
      const coin = LaunchSummary.parse(await get(`/v1/launches/${l.coin}`));
      expect(coin.graduation).toMatchObject({ pool: l.poolId, signature: receipt.transactionHash, fee: null, creatorTier: null });
      expect(coin.curve.status).toBe("graduated");

      // The board holds all five coins, and a list filtered to Solana is the list from before any EVM coin existed.
      const board = LaunchList.parse(await get("/v1/launches?limit=100")).launches;
      expect(board.map((x) => x.mint).sort()).toEqual([sold.mint, reward.mint, standard.coin, taxed.coin, l.coin].sort());
      expect(await solanaPages("chain=solana")).toEqual(before);
      expect(PlatformStats.parse(await get("/v1/stats"))).toEqual(statsBefore);
      expect(PlatformStats.parse(await get("/v1/stats?chain=robinhood"))).toMatchObject({ launches: 3, graduated: 1 });
      expect(OperatorOverview.parse(await operatorGet("/v1/operator/overview")).launches).toEqual(overviewBefore.launches);
      expect(OperatorOverview.parse(await operatorGet("/v1/operator/overview?chain=robinhood")).launches).toEqual({ total: 3, byStatus: { live: 2, graduating: 0, graduated: 1 }, reward: 1 });

      // Every Solana job, each to its end: the Cron Triggers as a deployment fires them, then each job by hand.
      for (const expression of [QUOTE_REGISTRY_CRON, GRADUATION_WATCH_CRON, FEE_COLLECTOR_CRON, REWARD_ROUNDS_CRON, BURN_CRON]) await cron(expression);
      for (const job of ["quote-registry", "fee-collector", "creator-forward", "rebates", "reward-rounds", "burn", "metadata-upload", "mentions", "indexer"]) {
        const res = await fetch(`${own.env.apiUrl}/v1/operator/jobs/${job}`, { method: "POST", headers: { authorization: `Bearer ${own.env.operatorToken}` } });
        expect(((await res.json()) as { status: string }).status, job).toBe("succeeded");
      }
      const latest = (await operatorGet("/v1/operator/overview")) as { jobs: { job: string; status: string; error: string | null }[] };
      expect(latest.jobs.map((j) => j.job).sort()).toEqual(
        ["burn", "creator-forward", "fee-collector", "graduation-watch", "indexer", "mentions", "metadata-upload", "quote-registry", "rebates", "reward-rounds", "reward-tax-lock"].sort(),
      );
      for (const j of latest.jobs) expect(j.status, `${j.job}: ${j.error}`).toBe("succeeded");
    });
  }, 600_000);
});
