// What a trader's wallet does with the API on an EVM chain (#253): ask for a quote, prepare a trade, and send or sign
// exactly what the API answered, on the test stack's fork of Robinhood Chain. Nothing here reaches into the API's
// internals; what a test compares the answers with is read from the chain.
import { erc20Abi, parseAbi, parseEventLogs, type Address, type Hex, type TransactionReceipt } from "viem";
import { EvmTradeQuote, EvmWalletBalances, PreparedEvmTrade, type EvmTransaction, type EvmTypedData } from "@launchpad/contract";
import { iPoolManagerAbi, quoteRegistryAbi, ROBINHOOD_CHAIN, stokerHookAbi } from "@launchpad/evm";
import { env } from "./client";
import { clients, evm, gasCost, type EvmLaunch, type PoolKey } from "./evm";

export type Trader = { key: Hex; address: Address };
export type TradeParams = { side: "buy" | "sell"; amount: bigint; slippageBps?: number; referrer?: Address; referrerFeeBps?: number };
type Permit = NonNullable<PreparedEvmTrade["permitDetails"]> & { signature: Hex };

/** A trade's parameters as the query string and the JSON body carry them. */
const fields = (p: TradeParams) => ({
  side: p.side,
  amount: p.amount.toString(),
  ...(p.slippageBps === undefined ? {} : { slippageBps: p.slippageBps }),
  ...(p.referrer === undefined ? {} : { referrer: p.referrer }),
  ...(p.referrerFeeBps === undefined ? {} : { referrerFeeBps: p.referrerFeeBps }),
});

export const quoteResponse = (coin: string, p: TradeParams) =>
  fetch(`${env().apiUrl}/v1/launches/${coin}/quote?${new URLSearchParams(Object.entries(fields(p)).map(([k, v]): [string, string] => [k, String(v)]))}`);

/** A coin's quote, which must be answered and must be the contract's shape. */
export async function quoteOf(coin: string, p: TradeParams): Promise<EvmTradeQuote> {
  const res = await quoteResponse(coin, p);
  if (!res.ok) throw new Error(`quote of ${coin}: ${res.status} ${await res.text()}`);
  return EvmTradeQuote.parse(await res.json());
}

export const prepareResponse = (trader: Address, coin: string, p: TradeParams, permit?: Permit) =>
  fetch(`${env().apiUrl}/v1/trades/prepare`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ mint: coin, trader, ...fields(p), ...(permit ? { permit } : {}) }),
  });

/** A trade's next step, which must be answered and must be the contract's shape. */
export async function prepareTrade(trader: Address, coin: string, p: TradeParams, permit?: Permit): Promise<PreparedEvmTrade> {
  const res = await prepareResponse(trader, coin, p, permit);
  if (!res.ok) throw new Error(`prepare of ${coin}: ${res.status} ${await res.text()}`);
  return PreparedEvmTrade.parse(await res.json());
}

/** A refusal's status and its sentence. */
export async function refusal(res: Response) {
  const body = (await res.json()) as { error?: string; details?: { message: string }[] };
  return { status: res.status, error: body.error ?? "", details: (body.details ?? []).map((d) => d.message) };
}

/**
 * Sends a prepared transaction as a wallet does: exactly its `to`, `data`, `value` and `gas`, the wallet adding only
 * the nonce and the gas price. A transaction that reverts on the chain is answered with its receipt, not thrown.
 */
export async function send(trader: Trader, tx: EvmTransaction): Promise<TransactionReceipt> {
  if (tx.chainId !== ROBINHOOD_CHAIN.chainId) throw new Error(`the transaction is for chain ${tx.chainId}`);
  const hash = await clients().wallet(trader.key).sendTransaction({ to: tx.to as Address, data: tx.data as Hex, value: BigInt(tx.value), gas: BigInt(tx.gas) });
  return clients().public.waitForTransactionReceipt({ hash });
}

/** Signs prepared typed data as a wallet's `eth_signTypedData_v4` does: exactly what the API answered. */
export const sign = (trader: Trader, typed: EvmTypedData) => clients().wallet(trader.key).signTypedData(typed as never);

export type ApiTrade = {
  /** The steps the API asked for, in order, the trade last. */
  steps: PreparedEvmTrade["step"][];
  /** The answer that carried the trade's transaction, with the quote of the same read. */
  prepared: PreparedEvmTrade;
  quote: EvmTradeQuote;
  receipt: TransactionReceipt;
  /** What the trade's own transaction cost in gas, in wei: an approval's is not in it. */
  gas: bigint;
};

/**
 * A trade as the site makes it: prepare, do what the answer says (send the approval, sign the permit), prepare again,
 * until the trade's own transaction is sent. `beforeSending` runs once the trade is prepared and before it is sent.
 */
export async function tradeThroughApi(trader: Trader, coin: string, p: TradeParams, beforeSending?: () => Promise<void>): Promise<ApiTrade> {
  const steps: PreparedEvmTrade["step"][] = [];
  let permit: Permit | undefined;
  for (let i = 0; i < 4; i++) {
    const prepared = await prepareTrade(trader.address, coin, p, permit);
    steps.push(prepared.step);
    if (prepared.step === "approve") {
      const approval = await send(trader, prepared.transaction!);
      if (approval.status !== "success") throw new Error("the approval reverted");
    } else if (prepared.step === "permit") {
      permit = { ...prepared.permitDetails!, signature: await sign(trader, prepared.permit!) };
    } else {
      await beforeSending?.();
      const receipt = await send(trader, prepared.transaction!);
      return { steps, prepared, quote: prepared.quote, receipt, gas: gasCost(receipt) };
    }
  }
  throw new Error(`the trade was not reached in four steps: ${steps.join(", ")}`);
}

/** The fees the hook booked in a transaction for one pool, from its own events: the figures a quote's fee lines must be. */
export function feeEvents(receipt: TransactionReceipt, poolId: Hex) {
  const logs = parseEventLogs({ abi: stokerHookAbi, logs: receipt.logs }).filter((l) => "poolId" in l.args && l.args.poolId === poolId);
  const fees = { platform: 0n, tax: 0n, opening: 0n, referrer: 0n, referrerAddress: null as Address | null };
  for (const l of logs) {
    if (l.eventName === "FeeCredited") fees.platform += l.args.fee;
    else if (l.eventName === "TaxBooked") fees.tax += l.args.tax;
    else if (l.eventName === "OpeningFeeBooked") fees.opening += l.args.fee;
    else if (l.eventName === "ReferrerFeeCredited") {
      fees.referrer += l.args.fee;
      fees.referrerAddress = l.args.referrer;
    }
  }
  return fees;
}

/** A Launch's terms as the hook holds them. */
export const termsOf = (poolId: Hex) => clients().public.readContract({ address: evm()!.hook, abi: stokerHookAbi, functionName: "termsOf", args: [poolId] });

/** What the hook owes `owner` in `asset`: a Creator's share, a Referrer Fee or the platform's. */
export const creditOf = (owner: Address, asset: Address) =>
  clients().public.readContract({ address: evm()!.hook, abi: stokerHookAbi, functionName: "creditOf", args: [owner, asset] });

/** The time of the block a transaction landed in, in seconds. */
export const blockTimeOf = async (receipt: TransactionReceipt) => (await clients().public.getBlock({ blockNumber: receipt.blockNumber })).timestamp;

/**
 * Waits until every one of these Launches' Opening Fees has run out, on the fork's own clock: the wall clock first,
 * then an empty block, since a fork's time is its latest block's and no block is made while nothing is sent. The
 * clock is never moved: the block is made at the time it is.
 */
export async function afterOpeningFee(launches: EvmLaunch[]) {
  const pub = clients().public;
  let ends = 0n;
  for (const l of launches) {
    const t = await termsOf(l.poolId);
    const end = t.launchedAt + BigInt(t.openingFeeDuration);
    if (end > ends) ends = end;
  }
  for (;;) {
    const now = (await pub.getBlock({ blockTag: "latest" })).timestamp;
    if (now >= ends) return;
    await new Promise((r) => setTimeout(r, Math.max(Number(ends - now) * 1000, 500)));
    await clients().test.mine({ blocks: 1 });
  }
}

/** Runs `work` as an account the fork lets anyone act as (a contract, or a key nobody here holds), with gas to send from. */
async function as<T>(account: Address, work: (anvil: ReturnType<typeof clients>["test"]) => Promise<T>): Promise<T> {
  const { test: anvil } = clients();
  await anvil.impersonateAccount({ address: account });
  const before = await anvil.getBalance({ address: account });
  await anvil.setBalance({ address: account, value: before + 10n ** 18n });
  try {
    return await work(anvil);
  } finally {
    await anvil.stopImpersonatingAccount({ address: account });
  }
}

/** Gives `to` some of an ERC-20 from the PoolManager's own balance, which only a fork lets anyone move. */
export async function fundFromPoolManager(asset: Address, to: Address, amount: bigint) {
  const pm = evm()!.poolManager;
  const held = await clients().public.readContract({ address: asset, abi: erc20Abi, functionName: "balanceOf", args: [pm] });
  if (held < amount) throw new Error(`the PoolManager holds ${held} of ${asset} at the fork's block, less than the ${amount} a test asked for`);
  await as(pm, async (anvil) => {
    const receipt = await anvil.waitForTransactionReceipt({ hash: await anvil.writeContract({ account: pm, chain: anvil.chain, address: asset, abi: erc20Abi, functionName: "transfer", args: [to, amount] }) });
    if (receipt.status !== "success") throw new Error(`moving ${asset} out of the PoolManager reverted`);
  });
}

/** Lists a Quote Asset with a Referrer Fee cap of its own, as the Admin; an asset already listed keeps its Listing. */
export async function listQuoteWithCap(quote: Address, startTick: number, referrerFeeCapBps: number) {
  const e = evm()!;
  const listing = await clients().public.readContract({ address: e.registry, abi: quoteRegistryAbi, functionName: "listingOf", args: [quote] });
  if (listing.listed) return;
  const hash = await clients().wallet(e.admin.key).writeContract({ address: e.registry, abi: quoteRegistryAbi, functionName: "list", args: [quote, startTick, 20, referrerFeeCapBps] });
  await clients().public.waitForTransactionReceipt({ hash });
}

/** Uniswap's protocol fee controller on Robinhood Chain (contracts/test/fork/ForkBase.sol). */
const PROTOCOL_FEE_CONTROLLER: Address = "0x6d0009504D129CF5002Dba61D9Ae8575AA79314c";

/** Switches Uniswap's protocol fee on for one pool, as its controller: the pips each direction pays, at most 1,000. */
export async function setProtocolFee(key: PoolKey, zeroForOnePips: number, oneForZeroPips: number) {
  const pm = evm()!.poolManager;
  await as(PROTOCOL_FEE_CONTROLLER, async (anvil) => {
    const hash = await anvil.writeContract({
      account: PROTOCOL_FEE_CONTROLLER, chain: anvil.chain, address: pm, abi: iPoolManagerAbi, functionName: "setProtocolFee", args: [key, zeroForOnePips | (oneForZeroPips << 12)],
    });
    if ((await anvil.waitForTransactionReceipt({ hash })).status !== "success") throw new Error("setting the protocol fee reverted");
  });
}

/** The holder of the Stock Tokens' `TOKEN_PAUSER_ROLE` (the knowledge base's `56-stock-token-custody-and-payouts.md`). */
const STOCK_TOKEN_PAUSER: Address = "0xfccf56b674113d9c4eb0f9b3370930ced9e6ab23";
const pauseAbi = parseAbi(["function pause()", "function unpause()", "function paused() view returns (bool)"]);

/** Pauses one Stock Token, or lifts its pause, as its issuer's pauser does. */
export async function setStockPaused(token: Address, pause: boolean) {
  await as(STOCK_TOKEN_PAUSER, async (anvil) => {
    const hash = await anvil.writeContract({ account: STOCK_TOKEN_PAUSER, chain: anvil.chain, address: token, abi: pauseAbi, functionName: pause ? "pause" : "unpause" });
    if ((await anvil.waitForTransactionReceipt({ hash })).status !== "success") throw new Error(`${pause ? "pausing" : "unpausing"} ${token} reverted`);
  });
  const now = await clients().public.readContract({ address: token, abi: pauseAbi, functionName: "paused" });
  if (now !== pause) throw new Error(`${token} is ${now ? "" : "not "}paused after the pauser's call`);
}

/** A wallet's balances as the API answers them. */
export async function balancesOf(wallet: Address, assets: Address[]) {
  const res = await fetch(`${env().apiUrl}/v1/chains/robinhood/wallets/${wallet}${assets.length ? `?assets=${assets.join(",")}` : ""}`);
  if (!res.ok) throw new Error(`balances of ${wallet}: ${res.status} ${await res.text()}`);
  return EvmWalletBalances.parse(await res.json());
}

/**
 * Why a mined transaction reverted, as the four-byte selector of its error: the same call replayed on the block before
 * it. Null when it replays without reverting, which points at the gas it was given.
 */
export async function revertSelectorOf(hash: Hex): Promise<Hex | null> {
  const pub = clients().public;
  const tx = await pub.getTransaction({ hash });
  try {
    await pub.call({ account: tx.from, to: tx.to!, data: tx.input, value: tx.value, blockNumber: tx.blockNumber! - 1n });
    return null;
  } catch (e) {
    for (let x: unknown = e, i = 0; x && i < 10; x = (x as { cause?: unknown }).cause, i++) {
      const data = (x as { data?: unknown }).data;
      if (typeof data === "string" && /^0x[0-9a-fA-F]{8,}$/.test(data)) return data.slice(0, 10) as Hex;
    }
    throw e;
  }
}
