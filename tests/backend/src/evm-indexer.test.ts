// #252: a coin launched on the test stack's fork of Robinhood Chain is read back over HTTP with its trades and candles,
// beside the Solana coins, each naming its chain. The fork needs ROBINHOOD_RPC_URL (an archive endpoint); without it
// the stack has no EVM side and the tests that need one are skipped by name, as CI's contracts job skips its fork tests.
import { describe, expect, inject, test } from "vitest";
import { erc20Abi, parseAbi, type Address } from "viem";
import { CandleList, ChainList, LaunchList, LaunchSummary, TradeList } from "@launchpad/contract";
import { NATIVE } from "@launchpad/evm";
import { env, launchedCoin } from "./client";
import { balanceOf, buyExactOut, clients, evmWallet, launchCoin, listQuote, runIndexer, swapExactIn } from "./evm";

const hasEvm = inject("harness").evm !== null;

/** CrowdStrike's Stock Token on Robinhood Chain, whose ERC-8056 multiplier was 4 at the fork's block (the knowledge base's `16-token-contracts.md`). */
const CRWD: Address = "0xea72Ecca2d0f6bFA1394DBBCff85b52CD4233931";
/** About $5,000 for the whole supply at the start price: a Stock Token near $450 (contracts' fork tests use the same scale). */
const STOCK_START_TICK = -244_200;

/** A GET of the API that must answer 200, as its JSON. */
async function api(path: string): Promise<unknown> {
  const res = await fetch(`${env().apiUrl}${path}`);
  if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${await res.text()}`);
  return res.json();
}

async function launchesOf(query: string) {
  return LaunchList.parse(await api(`/v1/launches?limit=100${query}`)).launches;
}

describe("Solana coins name their chain", () => {
  test("every existing coin is on Solana, listed under its chain's filter and under no other", async () => {
    const { mint } = await launchedCoin();
    const all = await launchesOf("");
    const mine = all.find((l) => l.mint === mint);
    expect(mine?.chain).toBe("solana");
    expect(mine?.quote.chain).toBe("solana");
    expect(mine?.quote.multiplier).toBeNull();
    expect((await launchesOf("&chain=solana")).some((l) => l.mint === mint)).toBe(true);
    expect((await launchesOf("&chain=robinhood")).some((l) => l.mint === mint)).toBe(false);
    const one = LaunchSummary.parse(await api(`/v1/launches/${mint}`));
    expect(one.chain).toBe("solana");
    const res = await fetch(`${inject("harness").apiUrl}/v1/launches?chain=nowhere`);
    expect(res.status).toBe(400);
  });

  test("every list endpoint takes a chain filter, and refuses a chain it does not know", async () => {
    const ledger = (await api("/v1/ledger?chain=solana")) as { entries: { chain: string }[] };
    expect(ledger.entries.every((e) => e.chain === "solana")).toBe(true);
    expect(((await api("/v1/ledger?chain=robinhood")) as { entries: unknown[] }).entries).toEqual([]);
    const quotes = (await api("/v1/quotes?chain=solana")) as { quotes: { chain: string; multiplier: unknown }[] };
    expect(quotes.quotes.length).toBeGreaterThan(0);
    expect(quotes.quotes.every((q) => q.chain === "solana" && q.multiplier === null)).toBe(true);
    expect(((await api("/v1/quotes?chain=robinhood")) as { quotes: unknown[] }).quotes).toEqual([]);
    expect(((await api("/v1/launches/quotes?chain=solana")) as { quotes: { chain: string }[] }).quotes.every((q) => q.chain === "solana")).toBe(true);
    expect(((await api("/v1/burns?chain=robinhood")) as { burned: unknown[]; liquidity: unknown }).burned).toBeDefined();
    expect(((await api("/v1/rebates?chain=robinhood")) as { weeks: unknown[] }).weeks).toEqual([]);
    for (const path of ["/v1/ledger", "/v1/quotes", "/v1/launches/quotes", "/v1/burns", "/v1/rebates"]) {
      expect((await fetch(`${env().apiUrl}${path}?chain=nowhere`)).status, path).toBe(400);
    }
  });

  test("the chains endpoint reports Solana's Indexer with how far its newest indexed slot is behind the head", async () => {
    const { chains } = ChainList.parse(await api("/v1/chains"));
    const solana = chains.find((c) => c.chain === "solana")!;
    expect(solana).toMatchObject({ family: "solana", chainId: null, indexer: { mode: "push" } });
    expect(solana.indexer.head!.block).toBeGreaterThan(0);
    expect(solana.indexer.indexed!.block).toBeLessThanOrEqual(solana.indexer.head!.block);
    expect(solana.indexer.blocksBehind).toBe(solana.indexer.head!.block - solana.indexer.indexed!.block);
  });
});

describe.skipIf(!hasEvm)("EVM chain: a coin on the Robinhood Chain fork", () => {
  test("a launched coin appears with its chain, under its chain's filter and not under Solana's", async () => {
    const creator = await evmWallet();
    const l = await launchCoin(creator, { firstBuy: 10n ** 16n });
    await runIndexer();

    const all = await launchesOf("");
    const coin = all.find((x) => x.mint === l.coin);
    expect(coin).toMatchObject({ chain: "robinhood", pool: l.poolId, creator: creator.address, createdSignature: l.receipt.transactionHash });
    expect(coin!.quote).toMatchObject({ chain: "robinhood", mint: NATIVE, symbol: "ETH", decimals: 18, multiplier: null });
    expect((await launchesOf("&chain=robinhood")).map((x) => x.mint)).toContain(l.coin);
    expect((await launchesOf("&chain=solana")).map((x) => x.mint)).not.toContain(l.coin);
    expect(LaunchSummary.parse(await api(`/v1/launches/${l.coin}`)).chain).toBe("robinhood");
    // Its whole supply less the seed's rounding dust, which the factory burns.
    const supply = await clients().public.readContract({ address: l.coin, abi: erc20Abi, functionName: "totalSupply" });
    expect(coin!.supply).toBe(supply.toString());
    expect(coin!.market.price).toBeGreaterThan(0);
  });

  test("a buy and a sell through the Universal Router appear as trades with the amounts the wallet received, and as candles", async () => {
    const creator = await evmWallet();
    const trader = await evmWallet();
    const l = await launchCoin(creator, { firstBuy: 10n ** 15n });

    const buyIn = 2n * 10n ** 16n;
    const ethBefore = await balanceOf(NATIVE, trader.address);
    const { receipt: buy, gas: buyGas } = await swapExactIn(trader, l, "buy", buyIn);
    const coinsBought = await balanceOf(l.coin, trader.address);
    expect(ethBefore - (await balanceOf(NATIVE, trader.address)) - buyGas).toBe(buyIn);

    const sellIn = coinsBought / 2n;
    const ethBeforeSell = await balanceOf(NATIVE, trader.address);
    const { receipt: sell, gas: sellGas } = await swapExactIn(trader, l, "sell", sellIn);
    const ethReceived = (await balanceOf(NATIVE, trader.address)) - ethBeforeSell + sellGas;

    const run = await runIndexer();
    expect(run.status).toBe("succeeded");
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades.map((t) => [t.side, t.signature])).toEqual([
      ["sell", sell.transactionHash],
      ["buy", buy.transactionHash],
      ["buy", l.receipt.transactionHash],
    ]);
    const [s, b, first] = trades;
    expect(b).toMatchObject({ chain: "robinhood", venue: "pool", trader: trader.address, baseAmount: coinsBought.toString(), quoteAmount: buyIn.toString() });
    expect(s).toMatchObject({ chain: "robinhood", trader: trader.address, baseAmount: sellIn.toString(), quoteAmount: ethReceived.toString() });
    expect(first).toMatchObject({ trader: creator.address, quoteAmount: (10n ** 15n).toString() });
    // The Platform Fee the hook booked: 1.00% of the Quote Asset's side, rounded up.
    expect(BigInt(b!.fees.platform)).toBe((buyIn * 100n + 9_999n) / 10_000n);
    expect(b!.referral).toBeNull();
    expect(s!.price).toBeLessThan(b!.price);

    const { candles } = CandleList.parse(await api(`/v1/launches/${l.coin}/candles?interval=1d`));
    const volume = candles.reduce((sum, c) => sum + BigInt(c.volume), 0n);
    expect(volume).toBe(10n ** 15n + buyIn + ethReceived);
    expect(candles.at(-1)!.close).toBe(s!.price);

    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.market.price).toBe(s!.price);
    expect(coin.market.volume24h.raw).toBe(volume.toString());
  });

  test("an exact-out buy naming a referrer appears with what the wallet paid and the Referrer Fee credited", async () => {
    const trader = await evmWallet();
    const referrer = await evmWallet(0n);
    const l = await launchCoin(await evmWallet());
    const coins = 10n ** 27n;
    const before = await balanceOf(NATIVE, trader.address);
    const { receipt, amountIn } = await buyExactOut(trader, l, coins, { referrer: referrer.address, bps: 50 });
    expect(before - (await balanceOf(NATIVE, trader.address)) - receipt.gasUsed * receipt.effectiveGasPrice).toBe(amountIn);
    expect(await balanceOf(l.coin, trader.address)).toBe(coins);

    await runIndexer();
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades[0]).toMatchObject({ side: "buy", trader: trader.address, baseAmount: coins.toString(), quoteAmount: amountIn.toString() });
    expect(trades[0]!.referral?.referrer).toBe(referrer.address);
    // The two fees on top of what the pool took: 1.00% and 0.50% of the whole the trader paid, each rounded up.
    const fee = BigInt(trades[0]!.fees.platform);
    const referrerFee = BigInt(trades[0]!.referral!.fee);
    expect(Number(fee) / Number(amountIn)).toBeCloseTo(0.01, 6);
    expect(Number(referrerFee) / Number(amountIn)).toBeCloseTo(0.005, 6);
  });

  test("a coin paired with a Stock Token returns raw amounts with the multiplier in force beside them", async () => {
    await listQuote(CRWD, STOCK_START_TICK);
    const multiplier = await clients().public.readContract({ address: CRWD, abi: parseAbi(["function uiMultiplier() view returns (uint256)"]), functionName: "uiMultiplier" });
    expect(multiplier).not.toBe(10n ** 18n);

    // The trader's Stock Tokens come from the PoolManager's own balance, which only a fork lets anyone move.
    const trader = await evmWallet();
    const { test: anvil } = clients();
    const pm = inject("harness").evm!.poolManager;
    await anvil.impersonateAccount({ address: pm });
    await anvil.setBalance({ address: pm, value: 10n ** 18n });
    await anvil.waitForTransactionReceipt({ hash: await anvil.writeContract({ account: pm, chain: anvil.chain, address: CRWD, abi: erc20Abi, functionName: "transfer", args: [trader.address, 10n ** 17n] }) });
    await anvil.stopImpersonatingAccount({ address: pm });

    const l = await launchCoin(await evmWallet(), { quote: CRWD });
    const spend = 5n * 10n ** 16n;
    await swapExactIn(trader, l, "buy", spend);
    await runIndexer();

    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.quote).toMatchObject({ chain: "robinhood", mint: CRWD, decimals: 18, multiplier: multiplier.toString(), category: "tokenized_stock" });
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades[0]).toMatchObject({ side: "buy", quoteAmount: spend.toString() });
  });

  test("an EVM coin's Quote Asset is listed under its chain, and a page that reads Solana alone says so by name", async () => {
    const l = await launchCoin(await evmWallet());
    await runIndexer();
    const { quotes } = (await api("/v1/launches/quotes?chain=robinhood")) as { quotes: { chain: string; mint: string; launches: number }[] };
    expect(quotes.find((q) => q.mint === NATIVE)).toMatchObject({ chain: "robinhood" });
    expect(((await api("/v1/launches/quotes?chain=solana")) as { quotes: { mint: string }[] }).quotes.map((q) => q.mint)).not.toContain(NATIVE);
    const holders = await fetch(`${env().apiUrl}/v1/launches/${l.coin}/holders`);
    expect(holders.status).toBe(404);
    expect(((await holders.json()) as { error: string }).error).toBe("holders is not available for coins on EVM chains yet");
  });

  test("the Indexer reports how far behind the fork's head it is, and catches up on its next run", async () => {
    await runIndexer();
    const before = ChainList.parse(await api("/v1/chains")).chains.find((c) => c.chain === "robinhood")!;
    expect(before).toMatchObject({ family: "evm", chainId: 4663, indexer: { mode: "poll", finalityDepth: 0, blocksBehind: 0 } });

    await clients().test.mine({ blocks: 7 });
    // The head is read on every request, so the gap shows before the next run.
    const behind = ChainList.parse(await api("/v1/chains")).chains.find((c) => c.chain === "robinhood")!;
    expect(behind.indexer.blocksBehind).toBe(7);
    expect(behind.indexer.head!.block).toBe(before.indexer.head!.block + 7);

    await runIndexer();
    const after = ChainList.parse(await api("/v1/chains")).chains.find((c) => c.chain === "robinhood")!;
    expect(after.indexer.blocksBehind).toBe(0);
    expect(after.indexer.secondsBehind).toBe(0);
  });
});
