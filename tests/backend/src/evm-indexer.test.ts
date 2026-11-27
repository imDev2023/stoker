// #252: a coin launched on the test stack's fork of Robinhood Chain is read back over HTTP with its trades and candles,
// beside the Solana coins, each naming its chain. The fork needs ROBINHOOD_RPC_URL (an archive endpoint); without it
// the stack has no EVM side and the tests that need one are skipped by name, as CI's contracts job skips its fork tests.
import { describe, expect, inject, test } from "vitest";
import { erc20Abi, parseAbi, type Address } from "viem";
import { CandleList, ChainList, LaunchList, LaunchSummary, TradeList } from "@launchpad/contract";
import { NATIVE, ROBINHOOD_CHAIN } from "@launchpad/evm";
import { deliverWebhook, env, fundedWallet, launchedCoin, SOL, trade } from "./client";
import { balanceOf, clients, evmWallet, launchCoin, listQuote, runIndexer, swapExactIn, swapExactOut } from "./evm";

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
    // An EVM chain's entries (#254) are that chain's alone.
    expect(((await api("/v1/ledger?chain=robinhood")) as { entries: { chain: string }[] }).entries.every((e) => e.chain === "robinhood")).toBe(true);
    const quotes = (await api("/v1/quotes?chain=solana")) as { quotes: { chain: string; multiplier: unknown }[] };
    expect(quotes.quotes.length).toBeGreaterThan(0);
    expect(quotes.quotes.every((q) => q.chain === "solana" && q.multiplier === null)).toBe(true);
    expect(((await api("/v1/quotes?chain=robinhood")) as { quotes: unknown[] }).quotes).toEqual([]);
    expect(((await api("/v1/launches/quotes?chain=solana")) as { quotes: { chain: string }[] }).quotes.every((q) => q.chain === "solana")).toBe(true);
    // The Burn and the rebates are Solana's: asked for an EVM chain, every list and every total is that chain's, none.
    expect(await api("/v1/burns?chain=robinhood")).toMatchObject({
      budgets: { revenueLamports: "0", burn: { spent: "0", available: "0" }, flywheel: { spent: "0", available: "0" } }, burned: [], nextFlywheel: [], events: [],
      liquidity: { lamports: "0", count: 0, additions: [] },
    });
    expect(await api("/v1/rebates?chain=robinhood")).toMatchObject({ program: { current: null, paidLamports: "0", waitingLamports: "0" }, weeks: [] });
    const solanaBurns = (await api("/v1/burns?chain=solana")) as { events: unknown[] };
    expect(solanaBurns.events).toEqual(((await api("/v1/burns")) as { events: unknown[] }).events);
    for (const path of ["/v1/ledger", "/v1/quotes", "/v1/launches/quotes", "/v1/burns", "/v1/rebates"]) {
      expect((await fetch(`${env().apiUrl}${path}?chain=nowhere`)).status, path).toBe(400);
    }
  });

  test("a list filtered to Solana is the same list with the EVM chains' items taken out", async () => {
    const all = await launchesOf("");
    const solana = await launchesOf("&chain=solana");
    const removed = all.filter((l) => l.chain === "solana");
    expect(solana.slice(0, removed.length)).toEqual(removed);
  });

  test("a wallet's and a Creator's lists take the chain filter, totals included", async () => {
    const { creator, mint } = await launchedCoin();
    const trader = await fundedWallet();
    const { signature } = await trade(trader, mint, "buy", SOL(0.2));
    expect((await deliverWebhook([signature])).status).toBe(200);
    for (const job of ["fee-collector", "creator-forward"]) {
      const res = await fetch(`${env().apiUrl}/v1/operator/jobs/${job}`, { method: "POST", headers: { authorization: `Bearer ${env().operatorToken}` } });
      expect(res.status, job).toBe(200);
    }
    const who = creator.publicKey.toBase58();
    const forwards = (path: string) => api(`/v1/creators/${who}/forwards${path}`) as Promise<{ forwards: { chain: string }[] }>;
    const mine = await forwards("");
    expect(mine.forwards.length).toBeGreaterThan(0);
    expect(await forwards("?chain=solana")).toEqual(mine);
    expect((await forwards("?chain=robinhood")).forwards).toEqual([]);
    for (const wallet of [who, trader.publicKey.toBase58()]) {
      expect(await api(`/v1/wallets/${wallet}/rebates?chain=robinhood`)).toMatchObject({ waitingLamports: "0", paidLamports: "0", current: null, rebates: [] });
      expect(await api(`/v1/wallets/${wallet}/rebates?chain=solana`)).toEqual(await api(`/v1/wallets/${wallet}/rebates`));
      expect(await api(`/v1/wallets/${wallet}/rewards?chain=robinhood`)).toMatchObject({ rewards: [] });
      expect(await api(`/v1/wallets/${wallet}/rewards?chain=solana`)).toEqual(await api(`/v1/wallets/${wallet}/rewards`));
    }
    for (const path of [`/v1/creators/${who}/forwards`, `/v1/wallets/${who}/rebates`, `/v1/wallets/${who}/rewards`]) {
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
    expect(coin!.quote).toMatchObject({ chain: "robinhood", mint: NATIVE, symbol: "ETH", decimals: 18, multiplier: null, category: "native" });
    expect((await launchesOf("&chain=robinhood&category=native")).map((x) => x.mint)).toContain(l.coin);
    expect((await launchesOf("&category=sol")).map((x) => x.mint)).not.toContain(l.coin);
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

  test("a Reward Launch's tax is in what its trades paid and received, and its terms are on the coin", async () => {
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet(), { reward: { taxBps: 300, burnShareBps: 1000, liquidityShareBps: 0 } });
    const buyIn = 10n ** 16n;
    await swapExactIn(trader, l, "buy", buyIn);
    const coins = await balanceOf(l.coin, trader.address);
    const before = await balanceOf(NATIVE, trader.address);
    const { gas } = await swapExactIn(trader, l, "sell", coins);
    const received = (await balanceOf(NATIVE, trader.address)) - before + gas;

    await runIndexer();
    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.rewardTax).toEqual({ bps: 300, payout: "quote", burnBps: 1000, liquidityBps: 0, locked: null });
    expect(coin.liquidityTax).toBeNull();
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades.map((t) => [t.side, t.baseAmount, t.quoteAmount])).toEqual([
      ["sell", coins.toString(), received.toString()],
      ["buy", coins.toString(), buyIn.toString()],
    ]);
  });

  test("an exact-out buy naming a referrer appears with what the wallet paid and the Referrer Fee credited", async () => {
    const trader = await evmWallet();
    const referrer = await evmWallet(0n);
    const l = await launchCoin(await evmWallet());
    // After the Opening Fee's 20 seconds (#246), inside which a Referrer Fee takes only the room under the start figure.
    await new Promise((r) => setTimeout(r, 21_000));
    const coins = 10n ** 27n;
    const before = await balanceOf(NATIVE, trader.address);
    const { amountIn, gas } = await swapExactOut(trader, l, "buy", coins, { referrer: referrer.address, bps: 50 });
    // What left the wallet: no more than the quote offered, the rest swept back (inside the Opening Fee's window it falls).
    const paid = before - (await balanceOf(NATIVE, trader.address)) - gas;
    expect(paid).toBeLessThanOrEqual(amountIn);
    expect(await balanceOf(l.coin, trader.address)).toBe(coins);

    await runIndexer();
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades[0]).toMatchObject({ side: "buy", trader: trader.address, baseAmount: coins.toString(), quoteAmount: paid.toString() });
    expect(trades[0]!.referral?.referrer).toBe(referrer.address);
    // The two fees on top of what the pool took: 1.00% and 0.50% of the whole the trader paid, each rounded up.
    const fee = BigInt(trades[0]!.fees.platform);
    const referrerFee = BigInt(trades[0]!.referral!.fee);
    expect(Number(fee) / Number(paid)).toBeCloseTo(0.01, 6);
    expect(Number(referrerFee) / Number(paid)).toBeCloseTo(0.005, 6);
  });

  test("an exact-out buy inside a Launch's first seconds pays the Opening Fee, and the trade is what left the wallet", async () => {
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet());
    const coins = 10n ** 27n;
    const before = await balanceOf(NATIVE, trader.address);
    const { amountIn, gas } = await swapExactOut(trader, l, "buy", coins);
    const paid = before - (await balanceOf(NATIVE, trader.address)) - gas;
    await runIndexer();
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    // The trade is what left the wallet, the Opening Fee in it: a decoder that missed `OpeningFeeBooked` reads less.
    expect(trades[0]).toMatchObject({ side: "buy", baseAmount: coins.toString(), quoteAmount: paid.toString() });
    expect(paid).toBeLessThanOrEqual(amountIn);
    // Every fee is a share of the whole the buy paid, the Opening Fee's too, so the Platform Fee stays 1.00% of it.
    expect(Number(BigInt(trades[0]!.fees.platform)) / Number(paid)).toBeCloseTo(0.01, 4);
  });

  test("a Creator Lock is on the coin as the factory held it out of the Seed Position", async () => {
    const week = 7 * 86_400;
    const l = await launchCoin(await evmWallet(), { lock: { bps: 1000, cliff: week, unlock: week } });
    await runIndexer();
    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.creatorLock).toEqual({ bps: 1000, amount: (10n ** 29n).toString(), cliffSeconds: week, unlockSeconds: week });
    expect(coin.graduation).toBeNull();
  });

  test("an exact-out sell appears with exactly what the wallet received and the coins it gave", async () => {
    const trader = await evmWallet();
    const l = await launchCoin(await evmWallet());
    await swapExactIn(trader, l, "buy", 2n * 10n ** 16n);
    const coinsBefore = await balanceOf(l.coin, trader.address);
    const ethBefore = await balanceOf(NATIVE, trader.address);
    // Little: inside the Opening Fee's window (#246) most of that buy went to Support Liquidity, not into the pool's price range.
    const wanted = 10n ** 13n;
    const { amountIn, gas } = await swapExactOut(trader, l, "sell", wanted);
    expect((await balanceOf(NATIVE, trader.address)) - ethBefore + gas).toBe(wanted);
    expect(coinsBefore - (await balanceOf(l.coin, trader.address))).toBe(amountIn);

    await runIndexer();
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades[0]).toMatchObject({ side: "sell", baseAmount: amountIn.toString(), quoteAmount: wanted.toString() });
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
    // A sell against the ERC-20, measured as the wallet's own balance of it.
    const coins = (await balanceOf(l.coin, trader.address)) / 3n;
    const crwdBefore = await balanceOf(CRWD, trader.address);
    await swapExactIn(trader, l, "sell", coins);
    const crwdReceived = (await balanceOf(CRWD, trader.address)) - crwdBefore;
    await runIndexer();

    const coin = LaunchSummary.parse(await api(`/v1/launches/${l.coin}`));
    expect(coin.quote).toMatchObject({ chain: "robinhood", mint: CRWD, decimals: 18, multiplier: multiplier.toString(), category: "tokenized_stock" });
    const { trades } = TradeList.parse(await api(`/v1/launches/${l.coin}/trades`));
    expect(trades.map((t) => [t.side, t.baseAmount, t.quoteAmount])).toEqual([["sell", coins.toString(), crwdReceived.toString()], expect.arrayContaining(["buy", spend.toString()])]);
    // The price is the pool's, read from the chain: Quote Asset per coin, both with 18 decimals.
    const [sqrtPriceX96] = await clients().public.readContract({
      address: ROBINHOOD_CHAIN.uniswap.stateView, abi: parseAbi(["function getSlot0(bytes32) view returns (uint160, int24, uint24, uint24)"]), functionName: "getSlot0", args: [l.poolId],
    });
    const raw = (Number(sqrtPriceX96) / 2 ** 96) ** 2;
    const expected = l.key.currency0 === CRWD ? 1 / raw : raw;
    expect(trades[0]!.price / expected).toBeCloseTo(1, 9);
    expect(coin.market.price! / expected).toBeCloseTo(1, 9);
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
    const depth = ROBINHOOD_CHAIN.finalityDepth;
    const chains = async () => {
      // The answer is kept for three seconds.
      await new Promise((r) => setTimeout(r, 3_100));
      return ChainList.parse(await api("/v1/chains")).chains.find((c) => c.chain === "robinhood")!;
    };
    await runIndexer();
    const before = await chains();
    // It stops on purpose its finality depth behind the head.
    expect(before).toMatchObject({ family: "evm", chainId: 4663, indexer: { mode: "poll", finalityDepth: depth, blocksBehind: depth } });

    await clients().test.mine({ blocks: 7 });
    // The head is read on each answer, so the gap shows before the next run.
    const behind = await chains();
    expect(behind.indexer.blocksBehind).toBe(depth + 7);
    expect(behind.indexer.head!.block).toBe(before.indexer.head!.block + 7);

    await runIndexer();
    const after = await chains();
    expect(after.indexer.blocksBehind).toBe(depth);
  });

});
