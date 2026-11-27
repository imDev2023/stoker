// #253: a coin on an EVM chain is quoted and traded through the API as a wallet would do it, on the test stack's fork of
// Robinhood Chain: each prepared transaction is sent and each permit signed exactly as answered, and every figure of a
// quote is compared with the chain (what reached the wallet, and the hook's own events). The fork needs
// ROBINHOOD_RPC_URL; without it the stack has no EVM side and these tests are skipped by name.
import { beforeAll, describe, expect, inject, test } from "vitest";
import { erc20Abi, maxUint256, parseAbi, toFunctionSelector, type Address } from "viem";
import { LaunchSummary, TradeList, type EvmTradeQuote } from "@launchpad/contract";
import { feeRatesAt, feesOnGross, feesTotal, mulDivUp, NATIVE, openingBpsAt, protocolFeeOn, ROBINHOOD_CHAIN, type SwapFees } from "@launchpad/evm";
import { env } from "./client";
import { balanceOf, clients, evmWallet, launchCoin, listQuote, runIndexer, type EvmLaunch } from "./evm";
import {
  afterOpeningFee, balancesOf, blockTimeOf, creditOf, feeEvents, fundFromPoolManager, listQuoteWithCap, prepareResponse, prepareTrade, quoteOf, quoteResponse,
  refusal, revertSelectorOf, send, setProtocolFee, setStockPaused, sign, termsOf, tradeThroughApi,
} from "./evm-trade-helpers";

const hasEvm = inject("harness").evm !== null;

/** CrowdStrike's Stock Token, which `evm-indexer.test.ts` lists too, at the same start price and Referrer Fee cap (1.00%). */
const CRWD: Address = "0xea72Ecca2d0f6bFA1394DBBCff85b52CD4233931";
/** Two Stock Tokens only this file lists, for a Referrer Fee cap of their own: the registry's most (5.00%), and none. */
const SGOV: Address = "0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5";
const AAPL: Address = "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9";
const STOCK_START_TICK = -244_200;
const { universalRouter: ROUTER, permit2: PERMIT2 } = ROBINHOOD_CHAIN.uniswap;
const permit2Abi = parseAbi(["function allowance(address user, address token, address spender) view returns (uint160 amount, uint48 expiration, uint48 nonce)"]);

/** A quote's four fee lines as amounts. */
const lines = (q: EvmTradeQuote): SwapFees => ({ platform: BigInt(q.fees.platform), tax: BigInt(q.fees.tax), opening: BigInt(q.fees.opening), referrer: BigInt(q.fees.referrer) });
const booked = (e: ReturnType<typeof feeEvents>): SwapFees => ({ platform: e.platform, tax: e.tax, opening: e.opening, referrer: e.referrer });
const seconds = (iso: string) => BigInt(Date.parse(iso) / 1000);
const iso = (s: bigint) => new Date(Number(s) * 1000).toISOString();

/**
 * A sell's fee lines against the hook's events: the hook takes them from the pool's output, of which a quote knows
 * only what is left, so where two outputs leave the same amount a line is the swap's own or one wei under it.
 */
function expectSellLines(q: EvmTradeQuote, events: ReturnType<typeof feeEvents>) {
  const quoted = lines(q);
  const real = booked(events);
  for (const line of ["platform", "tax", "opening", "referrer"] as const) {
    const under = real[line] - quoted[line];
    expect(under === 0n || under === 1n, `${line}: quoted ${quoted[line]}, booked ${real[line]}`).toBe(true);
  }
}

describe.skipIf(!hasEvm)("EVM chain: a coin on the Robinhood Chain fork is quoted and traded through the API", () => {
  // Launched once and traded after their Opening Fees have run out: a standard coin and a Reward Launch paired with the
  // native asset, a coin paired with a Stock Token, one whose pool takes Uniswap's protocol fee, and one whose Listing
  // lets a trade name no referrer.
  let standard: EvmLaunch;
  let reward: EvmLaunch;
  let stock: EvmLaunch;
  let protocolFeeCoin: EvmLaunch;
  let noReferrer: EvmLaunch;

  beforeAll(async () => {
    await listQuote(CRWD, STOCK_START_TICK);
    await listQuoteWithCap(SGOV, STOCK_START_TICK, 500);
    await listQuoteWithCap(AAPL, STOCK_START_TICK, 0);
    const creator = await evmWallet();
    standard = await launchCoin(creator);
    reward = await launchCoin(creator, { reward: { taxBps: 300, burnShareBps: 1000, liquidityShareBps: 0 } });
    stock = await launchCoin(creator, { quote: CRWD });
    protocolFeeCoin = await launchCoin(creator);
    noReferrer = await launchCoin(creator, { quote: AAPL });
    await runIndexer();
    await afterOpeningFee([standard, reward, stock, protocolFeeCoin, noReferrer]);
  });

  test("a buy with the native asset is one transaction and delivers the quote's amount to the wei, its fee lines the hook's own", async () => {
    const trader = await evmWallet();
    const spend = 2n * 10n ** 16n;
    const res = await quoteResponse(standard.coin, { side: "buy", amount: spend });
    expect(res.headers.get("cache-control")).toBe("no-store");
    const asked = await quoteOf(standard.coin, { side: "buy", amount: spend });
    expect(asked).toMatchObject({
      chain: "robinhood", coin: standard.coin, pool: standard.poolId, side: "buy", amountIn: spend.toString(), slippageBps: 100, tax: null, opening: null, referral: null,
      feeBps: { platform: 100, tax: 0, opening: 0, referrer: 0 }, protocolFee: { amount: "0", asset: "quote", pips: 0 },
      quote: { chain: "robinhood", mint: NATIVE, symbol: "ETH", decimals: 18, multiplier: null },
    });
    expect(BigInt(asked.minAmountOut)).toBe((BigInt(asked.amountOut) * 9_900n) / 10_000n);
    // The price before is the pool's own, which for a coin nobody has traded is the price the Indexer opened its market at.
    const summary = LaunchSummary.parse(await (await fetch(`${env().apiUrl}/v1/launches/${standard.coin}`)).json());
    expect(asked.priceBefore / summary.market.price!).toBeCloseTo(1, 6);
    expect(asked.averagePrice / (Number(spend) / Number(BigInt(asked.amountOut)))).toBeCloseTo(1, 9);
    // A buy pays above the price it started from: the fee and its own move of the price.
    expect(asked.averagePrice).toBeGreaterThan(asked.priceBefore);
    const head = await clients().public.getBlock({ blockTag: "latest" });
    expect(asked.block).toBe(Number(head.number));
    expect(asked.at).toBe(iso(head.timestamp));

    const ethBefore = await balanceOf(NATIVE, trader.address);
    const buy = await tradeThroughApi(trader, standard.coin, { side: "buy", amount: spend });
    expect(buy.steps).toEqual(["trade"]);
    expect(buy.prepared).toMatchObject({ chain: "robinhood", permit: null, permitDetails: null, transaction: { chainId: 4663, to: ROUTER, value: spend.toString() } });
    expect(buy.receipt.status).toBe("success");
    // Nothing traded between the quote and the trade, so the trade's own quote is the same figure.
    expect(buy.quote.amountOut).toBe(asked.amountOut);
    const coins = await balanceOf(standard.coin, trader.address);
    expect(coins).toBe(BigInt(buy.quote.amountOut));
    expect(ethBefore - (await balanceOf(NATIVE, trader.address)) - buy.gas).toBe(spend);
    expect(booked(feeEvents(buy.receipt, standard.poolId))).toEqual(lines(buy.quote));
    expect(lines(buy.quote)).toEqual({ platform: mulDivUp(spend, 100n, 10_000n), tax: 0n, opening: 0n, referrer: 0n });
  });

  test("a sell goes through Permit2 in three steps (approve, permit, trade), delivers the quote to the wei, and a second needs no approval", async () => {
    const trader = await evmWallet();
    await tradeThroughApi(trader, standard.coin, { side: "buy", amount: 2n * 10n ** 16n });
    const coins = await balanceOf(standard.coin, trader.address);
    const sell = { side: "sell" as const, amount: coins / 2n };

    const first = await prepareTrade(trader.address, standard.coin, sell);
    expect(first).toMatchObject({ step: "approve", permit: null, permitDetails: null, transaction: { to: standard.coin, value: "0" } });
    expect((await send(trader, first.transaction!)).status).toBe("success");
    // The approval is of Permit2 and of nothing else: Permit2 then moves the coin only by the trader's signature.
    expect(await clients().public.readContract({ address: standard.coin, abi: erc20Abi, functionName: "allowance", args: [trader.address, PERMIT2] })).toBe(maxUint256);
    expect(await clients().public.readContract({ address: standard.coin, abi: erc20Abi, functionName: "allowance", args: [trader.address, ROUTER] })).toBe(0n);

    const second = await prepareTrade(trader.address, standard.coin, sell);
    const until = (seconds(second.quote.at) + 1_800n).toString();
    expect(second).toMatchObject({
      step: "permit", transaction: null, permitDetails: { amount: sell.amount.toString(), nonce: "0", expiration: until, sigDeadline: until },
      permit: {
        primaryType: "PermitSingle", domain: { name: "Permit2", chainId: 4663, verifyingContract: PERMIT2 },
        message: { spender: ROUTER, sigDeadline: until, details: { token: standard.coin, amount: sell.amount.toString(), nonce: "0", expiration: until } },
      },
    });
    const permit = { ...second.permitDetails!, signature: await sign(trader, second.permit!) };

    const third = await prepareTrade(trader.address, standard.coin, sell, permit);
    expect(third).toMatchObject({ step: "trade", permit: null, permitDetails: null, transaction: { to: ROUTER, value: "0" }, quote: { side: "sell", protocolFee: { asset: "coin" } } });
    const ethBefore = await balanceOf(NATIVE, trader.address);
    const receipt = await send(trader, third.transaction!);
    expect(receipt.status).toBe("success");
    const received = (await balanceOf(NATIVE, trader.address)) - ethBefore + receipt.gasUsed * receipt.effectiveGasPrice;
    expect(received).toBe(BigInt(third.quote.amountOut));
    expect(await balanceOf(standard.coin, trader.address)).toBe(coins - sell.amount);
    expectSellLines(third.quote, feeEvents(receipt, standard.poolId));
    expect(third.quote.averagePrice / (Number(received) / Number(sell.amount))).toBeCloseTo(1, 9);
    // The permit was for this trade's amount alone: the router can move nothing more, and the nonce has moved on.
    const [left, , nonce] = await clients().public.readContract({ address: PERMIT2, abi: permit2Abi, functionName: "allowance", args: [trader.address, standard.coin, ROUTER] });
    expect([left, nonce]).toEqual([0n, 1]);
    // So the same permit is refused for another trade, in words.
    expect(await refusal(await prepareResponse(trader.address, standard.coin, sell, permit))).toMatchObject({ status: 400, error: "This permit has been used or replaced. Sign a new one." });

    let before = 0n;
    const again = await tradeThroughApi(trader, standard.coin, { side: "sell", amount: coins / 4n }, async () => void (before = await balanceOf(NATIVE, trader.address)));
    expect(again.steps).toEqual(["permit", "trade"]);
    expect(again.receipt.status).toBe("success");
    expect((await balanceOf(NATIVE, trader.address)) - before + again.gas).toBe(BigInt(again.quote.amountOut));
    expectSellLines(again.quote, feeEvents(again.receipt, standard.poolId));
  });

  test("a buy and a sell paired with a Stock Token deliver the quote to the wei, raw amounts with the multiplier in force beside them", async () => {
    const trader = await evmWallet();
    await fundFromPoolManager(CRWD, trader.address, 10n ** 17n);
    const spend = 5n * 10n ** 16n;

    const buy = await tradeThroughApi(trader, stock.coin, { side: "buy", amount: spend });
    expect(buy.steps).toEqual(["approve", "permit", "trade"]);
    expect(buy.receipt.status).toBe("success");
    const multiplier = await clients().public.readContract({ address: CRWD, abi: parseAbi(["function uiMultiplier() view returns (uint256)"]), functionName: "uiMultiplier" });
    expect(buy.quote).toMatchObject({ protocolFee: { asset: "quote" }, quote: { chain: "robinhood", mint: CRWD, decimals: 18, category: "tokenized_stock", multiplier: multiplier.toString() } });
    const coins = await balanceOf(stock.coin, trader.address);
    expect(coins).toBe(BigInt(buy.quote.amountOut));
    expect(await balanceOf(CRWD, trader.address)).toBe(10n ** 17n - spend);
    expect(booked(feeEvents(buy.receipt, stock.poolId))).toEqual(lines(buy.quote));
    expect(buy.prepared.transaction!.value).toBe("0");

    const crwdBefore = await balanceOf(CRWD, trader.address);
    const sell = await tradeThroughApi(trader, stock.coin, { side: "sell", amount: coins / 3n });
    // The coin needs its own approval of Permit2; the Stock Token has had its.
    expect(sell.steps).toEqual(["approve", "permit", "trade"]);
    expect(sell.receipt.status).toBe("success");
    expect((await balanceOf(CRWD, trader.address)) - crwdBefore).toBe(BigInt(sell.quote.amountOut));
    expectSellLines(sell.quote, feeEvents(sell.receipt, stock.poolId));

    const more = await tradeThroughApi(trader, stock.coin, { side: "buy", amount: 10n ** 16n });
    expect(more.steps).toEqual(["permit", "trade"]);
    expect((await balanceOf(stock.coin, trader.address)) - (coins - coins / 3n)).toBe(BigInt(more.quote.amountOut));
  });

  test("a trader who already lets the router move an asset through Permit2 trades in one step, and that allowance is left as it was", async () => {
    const trader = await evmWallet();
    await fundFromPoolManager(CRWD, trader.address, 10n ** 16n);
    const { public: pub } = clients();
    const wallet = clients().wallet(trader.key);
    // What Uniswap's own interface leaves a wallet with: the asset approved to Permit2, and Permit2 letting the router move it.
    await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: CRWD, abi: erc20Abi, functionName: "approve", args: [PERMIT2, maxUint256] }) });
    const standing = 2n ** 160n - 1n;
    await pub.waitForTransactionReceipt({
      hash: await wallet.writeContract({ address: PERMIT2, abi: parseAbi(["function approve(address token, address spender, uint160 amount, uint48 expiration)"]), functionName: "approve", args: [CRWD, ROUTER, standing, 2 ** 47] }),
    });
    const buy = await tradeThroughApi(trader, stock.coin, { side: "buy", amount: 10n ** 16n });
    expect(buy.steps).toEqual(["trade"]);
    expect(buy.receipt.status).toBe("success");
    expect(await balanceOf(stock.coin, trader.address)).toBe(BigInt(buy.quote.amountOut));
    const [amount, , nonce] = await pub.readContract({ address: PERMIT2, abi: permit2Abi, functionName: "allowance", args: [trader.address, CRWD, ROUTER] });
    expect([amount, nonce]).toEqual([standing, 0]);
  });

  test("a Reward Launch's tax and a referrer's fee are quoted as the hook books them, the referrer credited in the swap", async () => {
    const trader = await evmWallet();
    const referrer = await evmWallet(0n);
    const spend = 10n ** 16n;

    // No rate named: the API's own referral setting (0.50% on this stack), under the Listing's cap of 1.00%.
    const buy = await tradeThroughApi(trader, reward.coin, { side: "buy", amount: spend, referrer: referrer.address });
    expect(buy.receipt.status).toBe("success");
    expect(buy.quote).toMatchObject({ tax: "reward", opening: null, feeBps: { platform: 100, tax: 300, opening: 0, referrer: 50 }, referral: { referrer: referrer.address, namedBps: 50, fee: buy.quote.fees.referrer } });
    const bought = feeEvents(buy.receipt, reward.poolId);
    expect(booked(bought)).toEqual(lines(buy.quote));
    expect(lines(buy.quote)).toEqual({ platform: mulDivUp(spend, 100n, 10_000n), tax: mulDivUp(spend, 300n, 10_000n), opening: 0n, referrer: mulDivUp(spend, 50n, 10_000n) });
    expect(bought.referrerAddress).toBe(referrer.address);
    expect(await creditOf(referrer.address, NATIVE)).toBe(bought.referrer);
    const coins = await balanceOf(reward.coin, trader.address);
    expect(coins).toBe(BigInt(buy.quote.amountOut));

    // A rate named at the cap, on a sell.
    let before = 0n;
    const sell = await tradeThroughApi(trader, reward.coin, { side: "sell", amount: coins, referrer: referrer.address, referrerFeeBps: 100 }, async () => void (before = await balanceOf(NATIVE, trader.address)));
    expect(sell.receipt.status).toBe("success");
    expect(sell.quote).toMatchObject({ tax: "reward", feeBps: { platform: 100, tax: 300, opening: 0, referrer: 100 }, referral: { referrer: referrer.address, namedBps: 100 } });
    expect((await balanceOf(NATIVE, trader.address)) - before + sell.gas).toBe(BigInt(sell.quote.amountOut));
    const sold = feeEvents(sell.receipt, reward.poolId);
    expectSellLines(sell.quote, sold);
    expect(await creditOf(referrer.address, NATIVE)).toBe(bought.referrer + sold.referrer);

    // A trade without a referrer names nobody and pays no Referrer Fee.
    const plain = await quoteOf(reward.coin, { side: "buy", amount: spend });
    expect(plain).toMatchObject({ referral: null, fees: { referrer: "0" }, feeBps: { referrer: 0 } });
  });

  test("a Listing whose Referrer Fee cap is nothing names nobody, and the API's own rate never passes a cap", async () => {
    const referrer = await evmWallet(0n);
    expect((await termsOf(noReferrer.poolId)).referrerFeeCapBps).toBe(0);
    const spend = 10n ** 15n;
    const named = await quoteOf(noReferrer.coin, { side: "buy", amount: spend, referrer: referrer.address });
    expect(named).toMatchObject({ referral: null, fees: { referrer: "0" }, feeBps: { referrer: 0 } });
    // The same figure as a trade that names nobody, and again once the cap has been read once.
    expect(named.amountOut).toBe((await quoteOf(noReferrer.coin, { side: "buy", amount: spend })).amountOut);
    expect((await quoteOf(noReferrer.coin, { side: "buy", amount: spend, referrer: referrer.address })).amountOut).toBe(named.amountOut);
    expect(await refusal(await quoteResponse(noReferrer.coin, { side: "buy", amount: spend, referrer: referrer.address, referrerFeeBps: 1 }))).toMatchObject({
      status: 400, error: "The Referrer Fee this trade names is above this coin's cap of 0 basis points.",
    });
  });

  test("the slippage limit is the chain's: a trade whose price another trade moved past it reverts in the router, and one with room lands", async () => {
    const trader = await evmWallet();
    const other = await evmWallet();
    const amount = 10n ** 16n;
    const tight = await prepareTrade(trader.address, standard.coin, { side: "buy", amount, slippageBps: 10 });
    const loose = await prepareTrade(trader.address, standard.coin, { side: "buy", amount, slippageBps: 5_000 });
    expect(BigInt(tight.quote.minAmountOut)).toBe((BigInt(tight.quote.amountOut) * 9_990n) / 10_000n);
    expect(BigInt(loose.quote.minAmountOut)).toBe(BigInt(loose.quote.amountOut) / 2n);

    // Another wallet buys first and moves the price against both.
    expect((await tradeThroughApi(other, standard.coin, { side: "buy", amount: 10n ** 17n })).receipt.status).toBe("success");

    const refused = await send(trader, tight.transaction!);
    expect(refused.status).toBe("reverted");
    expect(await revertSelectorOf(refused.transactionHash)).toBe(toFunctionSelector("V4TooLittleReceived(uint256,uint256)"));
    expect(await balanceOf(standard.coin, trader.address)).toBe(0n);

    const landed = await send(trader, loose.transaction!);
    expect(landed.status).toBe("success");
    const coins = await balanceOf(standard.coin, trader.address);
    expect(coins).toBeLessThan(BigInt(loose.quote.amountOut));
    expect(coins >= BigInt(loose.quote.minAmountOut)).toBe(true);
  });

  test("a trade prepared and sent some seconds later lands with the gas it was given, on a taxed pool whose Reference Price that second writes", async () => {
    const trader = await evmWallet();
    const later = () => new Promise<void>((r) => setTimeout(r, 3_000));
    const buy = await tradeThroughApi(trader, reward.coin, { side: "buy", amount: 10n ** 16n }, later);
    expect(buy.receipt.status).toBe("success");
    expect(buy.receipt.gasUsed).toBeLessThan(BigInt(buy.prepared.transaction!.gas));
    const coins = await balanceOf(reward.coin, trader.address);
    // Outside the Opening Fee's window time changes no fee, and nobody else traded: still the quote's figure.
    expect(coins).toBe(BigInt(buy.quote.amountOut));

    const sell = await tradeThroughApi(trader, reward.coin, { side: "sell", amount: coins }, later);
    expect(sell.steps).toEqual(["approve", "permit", "trade"]);
    expect(sell.receipt.status).toBe("success");
    expect(sell.receipt.gasUsed).toBeLessThan(BigInt(sell.prepared.transaction!.gas));
    // The margin is a margin: the limit is not several times what the trade used.
    expect(BigInt(sell.prepared.transaction!.gas)).toBeLessThan(sell.receipt.gasUsed * 3n);
  });

  test("Uniswap's protocol fee, once its controller switches one on for a pool, is in the quote by direction and in what the trade delivers", async () => {
    // The native asset is currency zero of its pools, so a buy is zero-for-one: 0.05% on buys, 0.03% on sells.
    await setProtocolFee(protocolFeeCoin.key, 500, 300);
    const trader = await evmWallet();
    const spend = 10n ** 16n;

    const buy = await tradeThroughApi(trader, protocolFeeCoin.coin, { side: "buy", amount: spend });
    expect(buy.receipt.status).toBe("success");
    // Taken by the pool of what enters it: the Quote Asset less our own fees.
    expect(buy.quote.protocolFee).toEqual({ pips: 500, asset: "quote", amount: protocolFeeOn(spend - feesTotal(lines(buy.quote)), 500).toString() });
    const coins = await balanceOf(protocolFeeCoin.coin, trader.address);
    expect(coins).toBe(BigInt(buy.quote.amountOut));
    // Our fee is unchanged by Uniswap's.
    expect(booked(feeEvents(buy.receipt, protocolFeeCoin.poolId))).toEqual(lines(buy.quote));
    expect(buy.quote.fees.platform).toBe(mulDivUp(spend, 100n, 10_000n).toString());

    let before = 0n;
    const sell = await tradeThroughApi(trader, protocolFeeCoin.coin, { side: "sell", amount: coins / 2n }, async () => void (before = await balanceOf(NATIVE, trader.address)));
    expect(sell.receipt.status).toBe("success");
    expect(sell.quote.protocolFee).toEqual({ pips: 300, asset: "coin", amount: protocolFeeOn(coins / 2n, 300).toString() });
    expect((await balanceOf(NATIVE, trader.address)) - before + sell.gas).toBe(BigInt(sell.quote.amountOut));
    expectSellLines(sell.quote, feeEvents(sell.receipt, protocolFeeCoin.poolId));

    // The Indexer writes each trade with the same figure.
    await runIndexer();
    const { trades } = TradeList.parse(await (await fetch(`${env().apiUrl}/v1/launches/${protocolFeeCoin.coin}/trades`)).json());
    expect(trades.map((t) => [t.side, t.fees.raydium])).toEqual([["sell", sell.quote.protocolFee.amount], ["buy", buy.quote.protocolFee.amount]]);
  });

  /** Launches a coin and runs `work` at once; `work` answers false when the fork's clock had left the part of the Opening Fee's window it needs. */
  async function insideWindow(opts: Parameters<typeof launchCoin>[1], work: (l: EvmLaunch) => Promise<boolean>) {
    for (let attempt = 0; attempt < 4; attempt++) {
      const l = await launchCoin(await evmWallet(), opts);
      await runIndexer();
      if (await work(l)) return;
    }
    throw new Error("four Launches in a row were past the seconds of their Opening Fee this test trades in: the machine is too slow for it right now");
  }

  test("inside the Opening Fee's window a buy is quoted with that second's fee, delivers at least the quote, and pays what the hook's schedule says at its own second", async () => {
    const trader = await evmWallet();
    const spend = 10n ** 16n;
    await insideWindow({ firstBuy: 10n ** 15n }, async (l) => {
      const terms = await termsOf(l.poolId);
      const endsAt = terms.launchedAt + BigInt(terms.openingFeeDuration);
      const quoted = await quoteOf(l.coin, { side: "buy", amount: spend });
      const at = seconds(quoted.at);
      if (at >= endsAt) return false;
      expect(quoted.opening).toEqual({ endsAt: iso(endsAt) });
      expect(quoted.feeBps).toEqual({ platform: 100, tax: 0, opening: openingBpsAt(terms, at), referrer: 0 });
      expect(quoted.feeBps.opening).toBeGreaterThan(0);
      expect(lines(quoted)).toEqual(feesOnGross(spend, feeRatesAt(terms, at, "buy")));
      expect(BigInt(quoted.fees.opening)).toBeGreaterThan(0n);
      // A sell pays none, though the window runs.
      const sell = await quoteOf(l.coin, { side: "sell", amount: 10n ** 25n });
      expect(sell).toMatchObject({ opening: { endsAt: iso(endsAt) }, fees: { opening: "0" }, feeBps: { platform: 100, tax: 0, opening: 0, referrer: 0 } });

      const before = await balanceOf(l.coin, trader.address);
      const buy = await tradeThroughApi(trader, l.coin, { side: "buy", amount: spend });
      const landedAt = await blockTimeOf(buy.receipt);
      if (landedAt >= endsAt) return false;
      expect(buy.receipt.status).toBe("success");
      expect(buy.receipt.gasUsed).toBeLessThan(BigInt(buy.prepared.transaction!.gas));
      // The fee only falls, so the trade delivers the quote it was prepared with at least, and never less.
      const received = (await balanceOf(l.coin, trader.address)) - before;
      expect(received >= BigInt(buy.quote.amountOut), `received ${received}, quoted ${buy.quote.amountOut}`).toBe(true);
      if (landedAt === seconds(buy.quote.at)) expect(received).toBe(BigInt(buy.quote.amountOut));
      // What the hook booked is the schedule's figure at the second the trade landed in, to the wei.
      const events = feeEvents(buy.receipt, l.poolId);
      expect(booked(events)).toEqual(feesOnGross(spend, feeRatesAt(terms, landedAt, "buy")));
      expect(events.opening).toBeGreaterThan(0n);
      return true;
    });
  });

  test("a Referrer Fee named inside the window is quoted as the hook takes it: less than named at first, and never part of the Opening Fee", async () => {
    const trader = await evmWallet();
    const referrer = await evmWallet(0n);
    const spend = 10n ** 15n;
    await fundFromPoolManager(SGOV, trader.address, 10n * spend);
    // The approval of Permit2 is the asset's own, made before any Launch, so the window is spent on the trade alone.
    await clients().public.waitForTransactionReceipt({ hash: await clients().wallet(trader.key).writeContract({ address: SGOV, abi: erc20Abi, functionName: "approve", args: [PERMIT2, maxUint256] }) });
    await insideWindow({ quote: SGOV }, async (l) => {
      const terms = await termsOf(l.poolId);
      const endsAt = terms.launchedAt + BigInt(terms.openingFeeDuration);
      const named = terms.referrerFeeCapBps;
      expect(named).toBe(500);
      const trade = { side: "buy" as const, amount: spend, referrer: referrer.address, referrerFeeBps: named };
      const quoted = await quoteOf(l.coin, trade);
      const second = seconds(quoted.at) - terms.launchedAt;
      // The room under the start figure holds a 5.00% fee whole from the launch's third second on.
      if (second > 1n) return false;
      const rates = feeRatesAt(terms, seconds(quoted.at), "buy", named);
      expect(quoted.feeBps).toEqual(rates);
      expect(quoted.feeBps.referrer).toBe(second === 0n ? 0 : 490);
      expect(quoted.feeBps.platform + quoted.feeBps.tax + quoted.feeBps.opening + quoted.feeBps.referrer).toBe(9_900);
      expect(lines(quoted)).toEqual(feesOnGross(spend, rates));
      expect(quoted.referral).toEqual({ referrer: referrer.address, namedBps: named, fee: quoted.fees.referrer });
      // Naming the referrer took nothing from the Opening Fee: the same line as a buy that names nobody.
      expect(quoted.fees.opening).toBe((await quoteOf(l.coin, { side: "buy", amount: spend })).fees.opening);

      const before = await balanceOf(l.coin, trader.address);
      const buy = await tradeThroughApi(trader, l.coin, trade);
      expect(buy.steps).toEqual(["permit", "trade"]);
      const landedAt = await blockTimeOf(buy.receipt);
      if (landedAt >= endsAt) return false;
      expect(buy.receipt.status).toBe("success");
      const received = (await balanceOf(l.coin, trader.address)) - before;
      expect(received >= BigInt(buy.quote.amountOut), `received ${received}, quoted ${buy.quote.amountOut}`).toBe(true);
      const events = feeEvents(buy.receipt, l.poolId);
      expect(booked(events)).toEqual(feesOnGross(spend, feeRatesAt(terms, landedAt, "buy", named)));
      expect(await creditOf(referrer.address, SGOV)).toBeGreaterThanOrEqual(events.referrer);
      return true;
    });
  });

  test("a trade that cannot be made is refused in a sentence", async () => {
    const trader = await evmWallet(1n);
    const stranger = "0x00000000000000000000000000000000000dEaD1";
    const buy = { side: "buy" as const, amount: 10n ** 16n };
    const refused = async (res: Promise<Response>) => refusal(await res);

    // A coin the Indexer has never read.
    expect(await refused(quoteResponse(stranger, buy))).toEqual({ status: 404, error: "launch not found", details: [] });
    expect(await refused(prepareResponse(trader.address, stranger, buy))).toMatchObject({ status: 404, error: "launch not found" });
    // A request that is not one.
    expect(await refused(quoteResponse(standard.coin, { side: "buy", amount: 0n }))).toMatchObject({ status: 400, error: "invalid quote request" });
    expect(await refused(fetch(`${env().apiUrl}/v1/launches/${standard.coin}/quote?side=buy&amount=100&slippageBps=5001`))).toMatchObject({ status: 400, error: "invalid quote request" });
    // An amount too small to trade: a buy the fee would take whole, and a sell whose coins are worth less than a wei.
    expect(await refused(quoteResponse(standard.coin, { side: "buy", amount: 1n }))).toMatchObject({ status: 400, error: "amount is too small to trade" });
    expect(await refused(quoteResponse(standard.coin, { side: "sell", amount: 1n }))).toMatchObject({ status: 400, error: "amount is too small to trade" });
    // More coins than the pool holds Quote Asset to pay for, and an amount no pool could take.
    expect(await refused(quoteResponse(standard.coin, { side: "sell", amount: 10n ** 30n }))).toMatchObject({
      status: 400, error: "The coin's pool can't fill a trade this large. Try a smaller amount.",
    });
    expect(await refused(quoteResponse(standard.coin, { side: "buy", amount: 2n ** 128n }))).toMatchObject({ status: 400, error: "amount is too large to trade" });

    // A balance too small: for the amount, and for the amount with its network fee.
    expect(await refused(prepareResponse(trader.address, standard.coin, { side: "buy", amount: 2n * 10n ** 18n }))).toMatchObject({ status: 400, error: "This wallet holds less ETH than this buy spends." });
    const noFee = { status: 400, error: "This wallet's ETH doesn't cover this buy and its network fee. Buy with a little less." };
    expect(await refused(prepareResponse(trader.address, standard.coin, { side: "buy", amount: 10n ** 18n }))).toMatchObject(noFee);
    expect(await refused(prepareResponse(trader.address, standard.coin, { side: "buy", amount: 10n ** 18n - 1_000n }))).toMatchObject(noFee);
    expect(await refused(prepareResponse(trader.address, standard.coin, { side: "sell", amount: 10n ** 24n }))).toMatchObject({ status: 400, error: "This wallet holds fewer of this coin than the trade sells." });

    // A referrer the trade may not name, or name at that rate.
    const referrer = (await evmWallet(0n)).address;
    expect(await refused(quoteResponse(standard.coin, { ...buy, referrer, referrerFeeBps: 101 }))).toMatchObject({
      status: 400, error: "The Referrer Fee this trade names is above this coin's cap of 100 basis points.",
    });
    expect(await refused(quoteResponse(standard.coin, { ...buy, referrerFeeBps: 50 }))).toMatchObject({ status: 400, error: "referrerFeeBps names a Referrer Fee, so the trade must name its referrer too." });
    expect(await refused(quoteResponse(standard.coin, { ...buy, referrer: inject("harness").evm!.hook }))).toMatchObject({ status: 400, error: "That address can't be named as a trade's referrer." });
    expect(await refused(prepareResponse(trader.address, standard.coin, { ...buy, referrer: trader.address }))).toEqual({ status: 400, error: "invalid trade request", details: ["a trader can't refer themselves"] });
    // In whatever case the wallet's address came.
    expect(await refused(prepareResponse(trader.address, standard.coin, { ...buy, referrer: trader.address.toLowerCase() as Address }))).toMatchObject({ status: 400, error: "invalid trade request" });
  });

  test("a permit is good for the trade it was signed for and no other", async () => {
    const trader = await evmWallet();
    await tradeThroughApi(trader, standard.coin, { side: "buy", amount: 10n ** 16n });
    const coins = await balanceOf(standard.coin, trader.address);
    const small = { side: "sell" as const, amount: coins / 10n };
    const larger = { side: "sell" as const, amount: coins / 2n };
    const approval = await prepareTrade(trader.address, standard.coin, small);
    expect(approval.step).toBe("approve");
    await send(trader, approval.transaction!);
    const asked = await prepareTrade(trader.address, standard.coin, small);
    expect(asked.step).toBe("permit");
    const permit = { ...asked.permitDetails!, signature: await sign(trader, asked.permit!) };

    // Signed for less than the trade it is sent with.
    expect(await refusal(await prepareResponse(trader.address, standard.coin, larger, permit))).toMatchObject({
      status: 400, error: "This permit is for less than the trade spends. Sign a new one for this amount.",
    });
    // Its figures changed after it was signed: Permit2 itself refuses the signature, and the API says so before anything is sent.
    expect(await refusal(await prepareResponse(trader.address, standard.coin, larger, { ...permit, amount: larger.amount.toString() }))).toMatchObject({
      status: 400, error: "The signature doesn't match the permit this trade was prepared with. Sign it again.",
    });
    // Out of time.
    expect(await refusal(await prepareResponse(trader.address, standard.coin, small, { ...permit, sigDeadline: "1" }))).toMatchObject({ status: 400, error: "This permit has expired. Sign a new one." });
    // As signed, for its own trade, it is taken.
    const trade = await prepareTrade(trader.address, standard.coin, small, permit);
    expect(trade.step).toBe("trade");
    expect((await send(trader, trade.transaction!)).status).toBe("success");
    expect(await balanceOf(standard.coin, trader.address)).toBe(coins - small.amount);
  });

  test("a Quote Asset its issuer has paused is refused by name, and trades again once the pause is lifted", async () => {
    const trader = await evmWallet();
    const buy = { side: "buy" as const, amount: 10n ** 15n };
    await setStockPaused(CRWD, true);
    try {
      const sentence = "CRWD is paused by its issuer, so nothing paired with it can trade until the issuer lifts the pause.";
      expect(await refusal(await quoteResponse(stock.coin, buy))).toEqual({ status: 409, error: sentence, details: [] });
      expect(await refusal(await quoteResponse(stock.coin, { side: "sell", amount: 10n ** 24n }))).toMatchObject({ status: 409, error: sentence });
      expect(await refusal(await prepareResponse(trader.address, stock.coin, buy))).toMatchObject({ status: 409, error: sentence });
      // A coin paired with another asset is untouched.
      expect((await quoteOf(standard.coin, buy)).side).toBe("buy");
    } finally {
      await setStockPaused(CRWD, false);
    }
    expect((await quoteOf(stock.coin, buy)).quote.mint).toBe(CRWD);
  });

  test("a wallet's balances are the chain's, at a block a client can wait for", async () => {
    const trader = await evmWallet(3n);
    const buy = await tradeThroughApi(trader, standard.coin, { side: "buy", amount: 10n ** 16n });
    const native = (await balanceOf(NATIVE, trader.address)).toString();
    const coins = (await balanceOf(standard.coin, trader.address)).toString();
    expect(coins).toBe(buy.quote.amountOut);

    const read = await balancesOf(trader.address, [standard.coin, CRWD, NATIVE]);
    expect(read).toEqual({
      chain: "robinhood", wallet: trader.address, block: expect.any(Number), native,
      assets: [{ address: standard.coin, balance: coins }, { address: CRWD, balance: "0" }, { address: NATIVE, balance: native }],
    });
    // The trade is in what was read: the block is its own or a later one, and never one the chain has not made.
    expect(read.block).toBeGreaterThanOrEqual(Number(buy.receipt.blockNumber));
    expect(read.block).toBeLessThanOrEqual(Number(await clients().public.getBlockNumber()));
    // Whatever case the addresses came in, and with no asset named.
    expect(await balancesOf(trader.address.toLowerCase() as Address, [standard.coin.toLowerCase() as Address])).toMatchObject({ wallet: trader.address, assets: [{ address: standard.coin, balance: coins }] });
    expect(await balancesOf(trader.address, [])).toMatchObject({ native, assets: [] });
    const res = await fetch(`${env().apiUrl}/v1/chains/robinhood/wallets/${trader.address}`);
    expect(res.headers.get("cache-control")).toBe("no-store");

    const get = async (path: string) => refusal(await fetch(`${env().apiUrl}/v1/chains/${path}`));
    const nine = Array.from({ length: 9 }, (_, i) => `0x${(i + 1).toString(16).padStart(40, "0")}`).join(",");
    expect(await get(`robinhood/wallets/${trader.address}?assets=${nine}`)).toMatchObject({ status: 400, error: "at most 8 assets can be read at once" });
    expect(await get(`robinhood/wallets/${trader.address}?assets=0x1234`)).toMatchObject({ status: 400, error: '"0x1234" isn\'t an asset\'s address' });
    expect(await get("robinhood/wallets/0x1234")).toMatchObject({ status: 400, error: "invalid wallet address" });
    // An address that is no asset's contract.
    expect(await get(`robinhood/wallets/${trader.address}?assets=${trader.address}`)).toMatchObject({ status: 400, error: `${trader.address} isn't an asset whose balance can be read on Robinhood Chain` });
    expect((await get(`solana/wallets/${trader.address}`)).status).toBe(404);
    expect((await get(`nowhere/wallets/${trader.address}`)).status).toBe(400);
  });
});
