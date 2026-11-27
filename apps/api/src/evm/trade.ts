import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import { and, eq } from "drizzle-orm";
import {
  bytesToHex, encodeAbiParameters, encodeFunctionData, erc20Abi, keccak256, maxUint160, maxUint256, numberToHex, parseAbi, parseAbiParameters, type Address, type Hex,
} from "viem";
import {
  EvmAddress, EvmTradeQuoteQuery, PrepareEvmTradeRequest, type EvmChain, type EvmTradePermit, type EvmTradeQuote, type EvmTransaction, type EvmTypedData,
  type PreparedEvmTrade,
} from "@launchpad/contract";
import { checksum, feeRatesAt, feesOnGross, feesTotal, grossLeaving, NATIVE, priceFromSqrtX96, protocolFeeOn, stokerFactoryAbi } from "@launchpad/evm";
import { evmQuoteAssets, launches } from "@launchpad/db";
import { canonicalAddress } from "../chains/address";
import { evmQuoteRef } from "../chains/evm/quotes";
import type { AppEnv, Config } from "../env";
import { evmContext, reading, type EvmContext } from "./context";
import {
  allowanceRead, balanceRead, baseFeeRead, blockTimeRead, nativeBalanceRead, pausedRead, permit2AllowanceRead, readTogether, slot0Read, swapOutRead, termsRead, type PoolKey,
} from "./tradeReads";
import { paused, refusalOf, revertFrom, revertOf, tooSmall, type TradeNames } from "./tradeRefusals";

/**
 * Trading a coin on an EVM chain (#253): its quote and its trade's prepare, behind the same two paths Solana's coins
 * use (`src/routes/trades.ts` hands a `0x` coin here). A coin trades in its own Uniswap v4 pool for life (ADR 0024), so
 * the quote is Uniswap's own Quoter run with our hook in it, and the trade goes through the Universal Router the
 * chain's traffic uses, with the slippage limit in the transaction itself (ADR 0003: the wallet only signs).
 */

export const isEvmAddress = (value: unknown): value is string => EvmAddress.safeParse(value).success;

/** The Universal Router's commands and its v4 router's actions (Commands.sol, Actions.sol; contracts/test/fork/RouterLib.sol). */
const PERMIT2_PERMIT = 0x0a;
const V4_SWAP = 0x10;
const SWAP_EXACT_IN_SINGLE = 0x06;
const SETTLE_ALL = 0x0c;
const TAKE_ALL = 0x0f;

const routerAbi = parseAbi(["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"]);
const poolKeyParams = parseAbiParameters("address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks");
/** The six-field `ExactInputSingleParams` the chain's Universal Router reads, with the per-hop price limit (contracts/README.md, "Chain facts"). */
const exactInSingle = parseAbiParameters(
  "((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, uint256 minHopPriceX36, bytes hookData)",
);
const currencyAndAmount = parseAbiParameters("address, uint256");
const actionsAndParams = parseAbiParameters("bytes, bytes[]");
const referrerAndFee = parseAbiParameters("address, uint256");
/** What PERMIT2_PERMIT takes: Permit2's `PermitSingle` and the owner's signature of it. */
const permitAndSignature = parseAbiParameters("((address token, uint160 amount, uint48 expiration, uint48 nonce) details, address spender, uint256 sigDeadline), bytes");

/** `StokerHook.LaunchType` in its declared order: a standard coin, a Reward Launch, a Stoke Launch (`liquidity` in code, #215). */
const TAX_OF_LAUNCH_TYPE = [null, "reward", "liquidity"] as const;
/** Commands and actions are one byte each, packed. */
const packed = (bytes: number[]) => bytesToHex(Uint8Array.from(bytes));

const MAX_UINT128 = 2n ** 128n - 1n;
const MAX_UINT48 = 2n ** 48n - 1n;
/** A trade must land within 20 minutes of the block it was prepared at; a permit is good for 30, the trade it was signed for and no other. */
const DEADLINE_SECONDS = 20n * 60n;
const PERMIT_SECONDS = 30n * 60n;
/** A permit with less than this left is asked for again rather than raced against its own end. */
const PERMIT_MIN_SECONDS_LEFT = 60n;

type Coin = {
  chain: EvmChain;
  coin: Address;
  pool: Hex;
  symbol: string;
  decimals: number;
  quote: typeof evmQuoteAssets.$inferSelect;
  x: EvmContext;
};

/** The coin as the Indexer wrote it, with its Quote Asset and its chain: 404 as Solana's quote answers for a coin it has not indexed. */
async function coinOf(c: Context<AppEnv>, address: string): Promise<Coin> {
  const [row] = await c
    .get("db")
    .select({ chain: launches.chain, coin: launches.mint, pool: launches.pool, symbol: launches.symbol, decimals: launches.decimals, quote: evmQuoteAssets })
    .from(launches)
    .innerJoin(evmQuoteAssets, and(eq(evmQuoteAssets.chain, launches.chain), eq(evmQuoteAssets.address, launches.quoteMint)))
    .where(eq(launches.mint, canonicalAddress(address)))
    .limit(1);
  if (!row) throw new HTTPException(404, { message: "launch not found" });
  const x = evmContext(c, row.chain);
  return { ...row, chain: x.config.chain, coin: row.coin as Address, pool: row.pool as Hex, x };
}

/** A factory's tick spacing is an immutable of its deployment, so it is read from the chain once and kept for the isolate's life. */
const tickSpacings = new Map<string, number>();
async function tickSpacingOf(x: EvmContext) {
  const key = `${x.config.chain}:${x.config.factory}`;
  let spacing = tickSpacings.get(key);
  if (spacing === undefined) {
    spacing = await reading(x, () => x.client.readContract({ address: x.config.factory, abi: stokerFactoryAbi, functionName: "tickSpacing" }));
    tickSpacings.set(key, spacing);
  }
  return spacing;
}

/**
 * The coin's pool key, built from the deployment: the two currencies in address order, no LP fee, the factory's tick
 * spacing and our hook. It must hash to the pool id the Indexer read from the chain: a coin of another deployment
 * (an earlier factory, another hook) is refused here, never quoted against a pool that is not its own.
 */
async function poolKeyOf(coin: Coin): Promise<PoolKey> {
  const { x } = coin;
  const quote = coin.quote.address as Address;
  const quoteFirst = BigInt(quote) < BigInt(coin.coin);
  const key: PoolKey = { currency0: quoteFirst ? quote : coin.coin, currency1: quoteFirst ? coin.coin : quote, fee: 0, tickSpacing: await tickSpacingOf(x), hooks: x.config.hook };
  const id = keccak256(encodeAbiParameters(poolKeyParams, [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks]));
  if (id.toLowerCase() !== coin.pool.toLowerCase()) throw new HTTPException(409, { message: "This coin's pool isn't one this deployment's contracts trade." });
  return key;
}

/**
 * A Launch's Referrer Fee cap is a term fixed at launch (the hook never rewrites it), so once read it is kept for the
 * isolate's life: the first quote that names a referrer on a coin whose cap is under the API's own rate asks the chain
 * twice, and every later one once. Nothing that moves with time is ever kept.
 */
const referrerCaps = new Map<string, number>();
function rememberCap(key: string, cap: number) {
  if (!referrerCaps.has(key) && referrerCaps.size >= 5_000) referrerCaps.delete(referrerCaps.keys().next().value!);
  referrerCaps.set(key, cap);
}

/** The referrer a request names, or a refusal: the hook reverts the addresses it could never pay (README, "The Referrer Fee"). */
function referrerOf(x: EvmContext, r: EvmTradeQuoteQuery): Address | null {
  if (r.referrer === undefined) {
    if (r.referrerFeeBps !== undefined) throw new HTTPException(400, { message: "referrerFeeBps names a Referrer Fee, so the trade must name its referrer too." });
    return null;
  }
  const referrer = checksum(r.referrer.toLowerCase());
  const refused: Address[] = [NATIVE, x.config.hook, x.config.factory, x.config.profile.uniswap.poolManager];
  if (refused.includes(referrer)) throw new HTTPException(400, { message: "That address can't be named as a trade's referrer." });
  return referrer;
}

/** What a trader's wallet holds and has allowed, read with the quote at its block. */
type Wallet = {
  native: bigint;
  baseFee: bigint;
  /** Of an ERC-20 the trade pays with: the balance, what Permit2 may move of it, and what Permit2 lets the router move. Null when the trade pays with the native asset. */
  asset: { balance: bigint; approved: bigint; permit2: { amount: bigint; expiration: bigint; nonce: bigint } } | null;
};

type TradeRead = {
  quote: EvmTradeQuote;
  key: PoolKey;
  zeroForOne: boolean;
  hookData: Hex;
  pays: Address;
  receives: Address;
  /** The block's time in seconds. */
  time: bigint;
  names: TradeNames;
  wallet: Wallet | null;
};

/**
 * Prices an exact-in trade at the chain's latest block, and with a `trader` reads their wallet at the same block: one
 * `eth_call` through Multicall3 (the terms, the pool's price and Uniswap's protocol fee, the Quoter's run of the swap,
 * the block's time) beside one `eth_blockNumber`, since the opcode's block number is the parent chain's on this chain.
 * Nothing is cached between requests but two immutables (the tick spacing, a Launch's Referrer Fee cap), so a quote
 * inside the Opening Fee's window is always that block's.
 */
async function readTrade(cfg: Config, coin: Coin, r: EvmTradeQuoteQuery, trader: Address | null): Promise<TradeRead> {
  const { x } = coin;
  const amountIn = BigInt(r.amount);
  if (amountIn > MAX_UINT128) throw new HTTPException(400, { message: "amount is too large to trade" });
  const referrer = referrerOf(x, r);
  const key = await poolKeyOf(coin);
  const quote = coin.quote.address as Address;
  const buy = r.side === "buy";
  const quoteIsCurrency0 = key.currency0 === quote;
  const zeroForOne = buy === quoteIsCurrency0;
  const pays = buy ? quote : coin.coin;
  const receives = buy ? coin.coin : quote;
  const quoteSymbol = coin.quote.symbol ?? "The coin's Quote Asset";
  const names: TradeNames = { quoteSymbol, paySymbol: buy ? quoteSymbol : coin.symbol, trader };
  const router = x.config.profile.uniswap.universalRouter;
  const capKey = `${coin.chain}:${coin.pool}`;

  // The rate the trade names: its own, or the API's referral setting (Solana's `referralShare` reads the same one),
  // never above the Launch's cap, which is read below with everything else and corrects a first guess once.
  let namedBps = referrer ? (r.referrerFeeBps ?? Math.min(cfg.referralShareBps, referrerCaps.get(capKey) ?? cfg.referralShareBps)) : 0;
  for (let attempt = 0; ; attempt++) {
    const hookData = referrer && namedBps > 0 ? encodeAbiParameters(referrerAndFee, [referrer, BigInt(namedBps)]) : "0x";
    const [block, read] = await reading(x, () =>
      Promise.all([
        // viem keeps a block number for seconds unless told not to.
        x.client.getBlockNumber({ cacheTime: 0 }),
        readTogether(x, {
          terms: termsRead(x.config.hook, coin.pool),
          slot0: slot0Read(x, coin.pool),
          out: swapOutRead(x, key, zeroForOne, amountIn, hookData),
          time: blockTimeRead(x),
          // No transfer happens in the Quoter's run, so an issuer's pause is asked of the asset itself.
          paused: quote === NATIVE ? null : pausedRead(quote),
          native: trader ? nativeBalanceRead(x, trader) : null,
          baseFee: trader ? baseFeeRead(x) : null,
          balance: trader && pays !== NATIVE ? balanceRead(pays, trader) : null,
          approved: trader && pays !== NATIVE ? allowanceRead(pays, trader, x.config.profile.uniswap.permit2) : null,
          permit2: trader && pays !== NATIVE ? permit2AllowanceRead(x, trader, pays, router) : null,
        }),
      ]),
    );
    if (!read.terms.ok) throw refusalOf(revertOf(read.terms.data), names);
    if (!read.slot0.ok || !read.time.ok) throw new Error(`${coin.chain}: the pool's price or the block's time could not be read for ${coin.coin}`);
    const terms = read.terms.value;
    const time = read.time.value;

    rememberCap(capKey, terms.referrerFeeCapBps);
    if (referrer) {
      if (r.referrerFeeBps !== undefined && r.referrerFeeBps > terms.referrerFeeCapBps)
        throw new HTTPException(400, { message: `The Referrer Fee this trade names is above this coin's cap of ${terms.referrerFeeCapBps} basis points.` });
      const wanted = r.referrerFeeBps ?? Math.min(cfg.referralShareBps, terms.referrerFeeCapBps);
      if (wanted !== namedBps) {
        if (attempt > 0) throw new Error(`${coin.chain}: the Referrer Fee cap of ${coin.coin} read twice differently`);
        namedBps = wanted;
        continue;
      }
    }
    if (read.paused?.ok && read.paused.value) throw paused(quoteSymbol);
    if (!read.out.ok) {
      const revert = revertOf(read.out.data);
      if (!revert) console.error(`${coin.chain}: the Quoter refused a ${r.side} of ${coin.coin} with ${read.out.data.slice(0, 266)}`);
      throw refusalOf(revert, names);
    }
    const amountOut = read.out.value;
    if (amountOut === 0n) throw tooSmall();

    // The fees as the hook takes them at this block's second. A buy's are taken of what the trader pays. A sell's are
    // taken of what the pool pays out, of which the Quoter answers only what is left: the gross is the smallest one
    // whose fees leave exactly that (`grossLeaving` says how two can fit), so a sell's fee lines can be a wei under the
    // swap's own. `amountOut` is the Quoter's figure and never differs.
    const rates = feeRatesAt(terms, time, r.side, namedBps);
    const gross = buy ? amountIn : grossLeaving(amountOut, rates);
    if (gross === null) throw new Error(`${coin.chain}: no pool output leaves ${amountOut} after the fees of ${coin.coin}`);
    const fees = feesOnGross(gross, rates);
    // Uniswap's protocol fee is taken by the pool of what enters it: the Quote Asset less our fees on a buy, the coins on
    // a sell. `getSlot0` packs both directions, twelve bits each, zero-for-one in the low half.
    const pips = zeroForOne ? read.slot0.value.protocolFee & 0xfff : read.slot0.value.protocolFee >> 12;
    const entersPool = buy ? amountIn - feesTotal(fees) : amountIn;
    const minAmountOut = (amountOut * BigInt(10_000 - r.slippageBps)) / 10_000n;
    const endsAt = terms.launchedAt + BigInt(terms.openingFeeDuration);
    const opens = terms.openingFeeStartBps > terms.platformFeeBps + terms.taxBps && time < endsAt;
    const scale = 10 ** (coin.decimals - coin.quote.decimals);
    const iso = (seconds: bigint) => new Date(Number(seconds) * 1000).toISOString();

    const priced: EvmTradeQuote = {
      chain: coin.chain,
      coin: coin.coin,
      pool: coin.pool,
      side: r.side,
      amountIn: amountIn.toString(),
      amountOut: amountOut.toString(),
      minAmountOut: minAmountOut.toString(),
      slippageBps: r.slippageBps,
      quote: evmQuoteRef(coin.quote),
      fees: { platform: fees.platform.toString(), tax: fees.tax.toString(), opening: fees.opening.toString(), referrer: fees.referrer.toString() },
      feeBps: rates,
      protocolFee: { amount: protocolFeeOn(entersPool, pips).toString(), asset: buy ? "quote" : "coin", pips },
      tax: TAX_OF_LAUNCH_TYPE[terms.launchType] ?? null,
      opening: opens ? { endsAt: iso(endsAt) } : null,
      referral: referrer && namedBps > 0 ? { referrer, namedBps, fee: fees.referrer.toString() } : null,
      priceBefore: priceFromSqrtX96(read.slot0.value.sqrtPriceX96, quoteIsCurrency0, coin.decimals, coin.quote.decimals),
      averagePrice: (Number(buy ? amountIn : amountOut) / Number(buy ? amountOut : amountIn)) * scale,
      block: Number(block),
      at: iso(time),
    };

    let wallet: Wallet | null = null;
    if (trader) {
      if (!read.native?.ok || !read.baseFee?.ok) throw new Error(`${coin.chain}: the wallet's native balance could not be read`);
      let asset: Wallet["asset"] = null;
      if (pays !== NATIVE) {
        if (!read.balance?.ok || !read.approved?.ok || !read.permit2?.ok) throw new Error(`${coin.chain}: the wallet's ${names.paySymbol} could not be read`);
        asset = { balance: read.balance.value, approved: read.approved.value, permit2: read.permit2.value };
      }
      wallet = { native: read.native.value, baseFee: read.baseFee.value, asset };
    }
    return { quote: priced, key, zeroForOne, hookData, pays, receives, time, names, wallet };
  }
}

/** GET /v1/launches/:coin/quote for a coin on an EVM chain: what a trade would pay and deliver at the chain's latest block. */
export async function quoteEvmTrade(c: Context<AppEnv>, coin: string): Promise<Response> {
  const query = EvmTradeQuoteQuery.safeParse(c.req.query());
  if (!query.success) return c.json({ error: "invalid quote request", details: query.error.issues }, 400);
  const { quote } = await readTrade(c.get("cfg"), await coinOf(c, coin), query.data, null);
  // A quote is its block's: an Opening Fee falls every second, so nothing between the chain and the trader may keep one.
  c.header("cache-control", "no-store");
  return c.json(quote);
}

/**
 * The gas limit a prepared transaction carries: the estimate of that very transaction, half again, and 60,000 on top.
 * An estimate is of one second and one state, and the trade lands in another: the hook writes a pool's Reference Price
 * on the first swap of a new second (6,571 to 7,550 gas, contracts/README.md), a Graduation Hold starts, clears or is
 * recorded (up to 12,213), a pool's first Opening Fee sets its mark (a new storage word, 22,100), and a price another
 * trade moved in between crosses other ticks, Support Liquidity's among them. A bare estimate ran out of gas on the
 * fork a second later (`SWAP_GAS` in tests/backend/src/evm.ts). The margin covers all of those at once several times
 * over on a swap of about 200,000 gas, grows with a longer path as the rule that a call keeps a 64th of its gas does,
 * and costs the trader nothing: a limit is not a charge, and the wallet sets the gas price.
 */
const withMargin = (estimate: bigint) => (estimate * 3n) / 2n + 60_000n;

/** The transaction as the wallet sends it, with its gas from the chain's own estimate; a revert there is refused in words. */
async function transactionOf(t: TradeRead, x: EvmContext, from: Address, to: Address, data: Hex, value: bigint): Promise<EvmTransaction> {
  const estimate = await reading(x, async () => {
    try {
      return BigInt(await x.client.request({ method: "eth_estimateGas", params: [{ from, to, data, value: numberToHex(value) }] }));
    } catch (e) {
      const { reverted, data: reason } = revertFrom(e);
      if (!reverted) throw e;
      const revert = revertOf(reason);
      if (!revert) console.error(`${x.config.chain}: the estimate of a transaction to ${to} reverted with ${reason?.slice(0, 266) ?? "no data"}`);
      throw refusalOf(revert, t.names);
    }
  });
  return { chainId: x.config.profile.chainId, to, data, value: value.toString(), gas: withMargin(estimate).toString() };
}

/** The Universal Router's `V4_SWAP` input: the exact-in swap, the payment of what it owes and the taking of what it is owed, the limit in both. */
function swapInput(t: TradeRead): Hex {
  const amountIn = BigInt(t.quote.amountIn);
  const minAmountOut = BigInt(t.quote.minAmountOut);
  return encodeAbiParameters(actionsAndParams, [
    packed([SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]),
    [
      encodeAbiParameters(exactInSingle, [{ poolKey: t.key, zeroForOne: t.zeroForOne, amountIn, amountOutMinimum: minAmountOut, minHopPriceX36: 0n, hookData: t.hookData }]),
      encodeAbiParameters(currencyAndAmount, [t.pays, amountIn]),
      encodeAbiParameters(currencyAndAmount, [t.receives, minAmountOut]),
    ],
  ]);
}

/** Permit2's `PermitSingle` as EIP-712 typed data: the router may move this asset, this amount, until this time, by this signature alone. */
function permitTypedData(x: EvmContext, asset: Address, d: Omit<EvmTradePermit, "signature">): EvmTypedData {
  return {
    domain: { name: "Permit2", chainId: x.config.profile.chainId, verifyingContract: x.config.profile.uniswap.permit2 },
    types: {
      EIP712Domain: [{ name: "name", type: "string" }, { name: "chainId", type: "uint256" }, { name: "verifyingContract", type: "address" }],
      PermitSingle: [{ name: "details", type: "PermitDetails" }, { name: "spender", type: "address" }, { name: "sigDeadline", type: "uint256" }],
      PermitDetails: [{ name: "token", type: "address" }, { name: "amount", type: "uint160" }, { name: "expiration", type: "uint48" }, { name: "nonce", type: "uint48" }],
    },
    primaryType: "PermitSingle",
    message: {
      details: { token: asset, amount: d.amount, expiration: d.expiration, nonce: d.nonce },
      spender: x.config.profile.uniswap.universalRouter,
      sigDeadline: d.sigDeadline,
    },
  };
}

/**
 * POST /v1/trades/prepare for a coin on an EVM chain: the next thing the trader's wallet does, with the quote of the
 * same read. A buy with the chain's native asset is the trade at once. Paying with an ERC-20 (a buy with a Stock Token
 * or a stablecoin, every sell) goes through Permit2: one approval per asset, then a signature for this trade's amount
 * alone, then the trade carrying it, so nothing can move the asset but what the trader signed.
 */
export async function prepareEvmTrade(c: Context<AppEnv>, sent: unknown): Promise<Response> {
  const body = PrepareEvmTradeRequest.safeParse(sent);
  if (!body.success) return c.json({ error: "invalid trade request", details: body.error.issues }, 400);
  const r = body.data;
  const coin = await coinOf(c, r.mint);
  const { x } = coin;
  const trader = checksum(r.trader.toLowerCase());
  const t = await readTrade(c.get("cfg"), coin, r, trader);
  const wallet = t.wallet!;
  const amountIn = BigInt(t.quote.amountIn);
  const { universalRouter: router, permit2 } = x.config.profile.uniswap;
  const answer = (step: PreparedEvmTrade["step"], transaction: EvmTransaction | null, details: Omit<EvmTradePermit, "signature"> | null = null) => {
    const res: PreparedEvmTrade = { chain: coin.chain, step, transaction, permit: details ? permitTypedData(x, t.pays, details) : null, permitDetails: details, quote: t.quote };
    c.header("cache-control", "no-store");
    return c.json(res);
  };
  const execute = (commands: number[], inputs: Hex[], deadline: bigint) =>
    encodeFunctionData({ abi: routerAbi, functionName: "execute", args: [packed(commands), inputs, deadline] });
  const refuse = (message: string) => new HTTPException(400, { message });

  if (!wallet.asset) {
    const symbol = x.config.profile.native.symbol;
    if (wallet.native < amountIn) throw refuse(`This wallet holds less ${symbol} than this buy spends.`);
    const transaction = await transactionOf(t, x, trader, router, execute([V4_SWAP], [swapInput(t)], t.time + DEADLINE_SECONDS), amountIn);
    // The same balance pays for the gas: at the block's base fee the limit above costs this much at least.
    if (wallet.native < amountIn + BigInt(transaction.gas) * wallet.baseFee)
      throw refuse(`This wallet's ${symbol} doesn't cover this buy and its network fee. Buy with a little less.`);
    return answer("trade", transaction);
  }

  const { balance, approved, permit2: allowed } = wallet.asset;
  if (balance < amountIn) throw refuse(r.side === "sell" ? "This wallet holds fewer of this coin than the trade sells." : `This wallet holds less ${t.names.paySymbol} than this buy spends.`);
  // Once per asset: Permit2 may move it from then on, and moves it only by the trader's own signature.
  if (approved < amountIn) {
    const data = encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [permit2, maxUint256] });
    return answer("approve", await transactionOf(t, x, trader, t.pays, data, 0n));
  }

  if (!r.permit) {
    const deadline = t.time + DEADLINE_SECONDS;
    // A trader who already lets this router move the asset through Permit2 (Uniswap's own interface signs such a
    // permit) trades at once: a permit signed here would replace that standing allowance with this trade's amount.
    if (allowed.amount >= amountIn && allowed.expiration >= deadline) return answer("trade", await transactionOf(t, x, trader, router, execute([V4_SWAP], [swapInput(t)], deadline), 0n));
    const until = (t.time + PERMIT_SECONDS).toString();
    return answer("permit", null, { amount: amountIn.toString(), expiration: until, nonce: allowed.nonce.toString(), sigDeadline: until });
  }

  // What the wallet signed must be this trade's: enough for it, with the nonce Permit2 expects now, and time left.
  const permit = { amount: BigInt(r.permit.amount), expiration: BigInt(r.permit.expiration), nonce: BigInt(r.permit.nonce), sigDeadline: BigInt(r.permit.sigDeadline) };
  if (permit.amount > maxUint160 || permit.expiration > MAX_UINT48 || permit.nonce > MAX_UINT48) throw refuse("This permit isn't one Permit2 can read. Sign a new one.");
  if (permit.amount < amountIn) throw refuse("This permit is for less than the trade spends. Sign a new one for this amount.");
  if (permit.nonce !== allowed.nonce) throw refuse("This permit has been used or replaced. Sign a new one.");
  const permitEnds = permit.expiration < permit.sigDeadline ? permit.expiration : permit.sigDeadline;
  if (permitEnds < t.time + PERMIT_MIN_SECONDS_LEFT) throw refuse("This permit has expired. Sign a new one.");
  // The trade never outlives its permit.
  const deadline = permitEnds < t.time + DEADLINE_SECONDS ? permitEnds : t.time + DEADLINE_SECONDS;
  const permitInput = encodeAbiParameters(permitAndSignature, [
    { details: { token: t.pays, amount: permit.amount, expiration: Number(permit.expiration), nonce: Number(permit.nonce) }, spender: router, sigDeadline: permit.sigDeadline },
    r.permit.signature as Hex,
  ]);
  return answer("trade", await transactionOf(t, x, trader, router, execute([PERMIT2_PERMIT, V4_SWAP], [permitInput, swapInput(t)], deadline), 0n));
}
