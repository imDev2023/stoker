// What a wallet does on an EVM chain (#252): launch through our factory and trade through the Universal Router the
// chain's traffic uses, on the test stack's fork of Robinhood Chain. Nothing here reaches into the API's internals.
import {
  createPublicClient, createTestClient, createWalletClient, encodeAbiParameters, encodePacked, erc20Abi, http, maxUint160, parseAbi,
  keccak256, parseAbiParameters, parseEventLogs, publicActions, toFunctionSelector, toHex, walletActions, type Address, type Hex, type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { quoteRegistryAbi, stokerFactoryAbi, NATIVE, ROBINHOOD_CHAIN } from "@launchpad/evm";
import { env } from "./client";

export const evm = () => env().evm;

/** The fork's chain, as viem needs it. */
const chainOf = (rpcUrl: string) => ({
  id: ROBINHOOD_CHAIN.chainId, name: ROBINHOOD_CHAIN.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});

export function clients() {
  const e = evm()!;
  const chain = chainOf(e.rpcUrl);
  const transport = http(e.rpcUrl);
  return {
    public: createPublicClient({ chain, transport }),
    test: createTestClient({ chain, transport, mode: "anvil" }).extend(publicActions).extend(walletActions),
    wallet: (key: Hex) => createWalletClient({ chain, transport, account: privateKeyToAccount(key) }),
  };
}

/** A fresh wallet on the fork with `eth` ether, as a faucet would fund one. */
export async function evmWallet(eth = 10n) {
  const key = (`0x${Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex")}`) as Hex;
  const account = privateKeyToAccount(key);
  await clients().test.setBalance({ address: account.address, value: eth * 10n ** 18n });
  return { key, address: account.address };
}

export type EvmLaunch = { coin: Address; poolId: Hex; quote: Address; receipt: TransactionReceipt; key: PoolKey };
export type PoolKey = { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };

let salts = 0;

/** Launches a coin as a Creator would, in one transaction; a native First Buy is the value sent. */
/** `StokerHook.LaunchType`: a standard coin, a Reward Launch, a Stoke Launch (`liquidity` in code, #215). */
export const LAUNCH_TYPE = { standard: 0, reward: 1, liquidity: 2 } as const;

export async function launchCoin(
  creator: { key: Hex },
  opts: { quote?: Address; firstBuy?: bigint; name?: string; symbol?: string; reward?: { taxBps: number; burnShareBps: number; liquidityShareBps: number } } = {},
): Promise<EvmLaunch> {
  const e = evm()!;
  const quote = opts.quote ?? NATIVE;
  const firstBuy = opts.firstBuy ?? 0n;
  const tag = `${Date.now().toString(36).slice(-4)}${(salts++).toString(36)}`.toUpperCase();
  const wallet = clients().wallet(creator.key);
  const hash = await wallet.writeContract({
    address: e.factory, abi: stokerFactoryAbi, functionName: "launch",
    args: [{ name: opts.name ?? `Fork Coin ${tag}`, symbol: opts.symbol ?? `F${tag}`, quote, salt: keccak256(toHex(tag)), creatorDestination: NATIVE, firstBuy,
      launchType: opts.reward ? LAUNCH_TYPE.reward : LAUNCH_TYPE.standard, taxBps: opts.reward?.taxBps ?? 0, burnShareBps: opts.reward?.burnShareBps ?? 0,
      liquidityShareBps: opts.reward?.liquidityShareBps ?? 0, payoutAsset: 0 }],
    value: quote === NATIVE ? firstBuy : 0n,
  });
  const receipt = await clients().public.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`launch reverted: ${hash}`);
  const [launched] = parseEventLogs({ abi: stokerFactoryAbi, logs: receipt.logs, eventName: "Launched" });
  const coin = launched!.args.coin;
  const quoteIsCurrency0 = BigInt(quote) < BigInt(coin);
  const key: PoolKey = {
    currency0: quoteIsCurrency0 ? quote : coin, currency1: quoteIsCurrency0 ? coin : quote, fee: 0, tickSpacing: e.tickSpacing, hooks: e.hook,
  };
  return { coin, poolId: launched!.args.poolId, quote, receipt, key };
}

/** Lists a Quote Asset on the fork's Quote Registry as the Admin. */
export async function listQuote(quote: Address, startTick: number) {
  const e = evm()!;
  const listing = await clients().public.readContract({ address: e.registry, abi: quoteRegistryAbi, functionName: "listingOf", args: [quote] });
  if (listing.listed) return;
  const hash = await clients().wallet(e.admin.key).writeContract({ address: e.registry, abi: quoteRegistryAbi, functionName: "list", args: [quote, startTick, 20, 100] });
  await clients().public.waitForTransactionReceipt({ hash });
}

const routerAbi = parseAbi(["function execute(bytes commands, bytes[] inputs, uint256 deadline) payable"]);
const permit2Abi = parseAbi(["function approve(address token, address spender, uint160 amount, uint48 expiration)"]);
const V4_SWAP = 0x10;
const SWAP_EXACT_IN_SINGLE = 0x06;
const SETTLE_ALL = 0x0c;
const TAKE_ALL = 0x0f;
/** The six-field `ExactInputSingleParams` the chain's Universal Router reads (contracts/test/fork/RouterLib.sol). */
const exactInSingle = parseAbiParameters(
  "(( address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks ) poolKey, bool zeroForOne, uint128 amountIn, uint128 amountOutMinimum, uint256 minHopPriceX36, bytes hookData)",
);

/**
 * An exact-in swap through the Universal Router, as a wallet's swap screen sends it: a buy spends `amountIn` of the
 * Quote Asset, a sell `amountIn` coins (approved to Permit2 and the router first, as Uniswap's interface does).
 */
export async function swapExactIn(trader: { key: Hex; address: Address }, l: EvmLaunch, side: "buy" | "sell", amountIn: bigint) {
  const { public: pub } = clients();
  const wallet = clients().wallet(trader.key);
  const quoteIsCurrency0 = l.key.currency0 === l.quote;
  const zeroForOne = side === "buy" ? quoteIsCurrency0 : !quoteIsCurrency0;
  const tokenIn = side === "buy" ? l.quote : l.coin;
  const tokenOut = side === "buy" ? l.coin : l.quote;
  const router = ROBINHOOD_CHAIN.uniswap.universalRouter;
  // The approvals' gas is the wallet's too: `gas` counts every transaction the swap took, so a native balance's change
  // can be read as the trade alone.
  let gas = 0n;
  if (tokenIn !== NATIVE) {
    const approve = await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: tokenIn, abi: erc20Abi, functionName: "approve", args: [ROBINHOOD_CHAIN.uniswap.permit2, 2n ** 256n - 1n] }) });
    const allow = await pub.waitForTransactionReceipt({
      hash: await wallet.writeContract({ address: ROBINHOOD_CHAIN.uniswap.permit2, abi: permit2Abi, functionName: "approve", args: [tokenIn, router, maxUint160, 2 ** 47] }),
    });
    gas += gasCost(approve) + gasCost(allow);
  }
  const actions = encodePacked(["uint8", "uint8", "uint8"], [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]);
  const params = [
    encodeAbiParameters(exactInSingle, [{ poolKey: l.key, zeroForOne, amountIn, amountOutMinimum: 0n, minHopPriceX36: 0n, hookData: "0x" }]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [tokenIn, amountIn]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [tokenOut, 0n]),
  ];
  const input = encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params]);
  const hash = await wallet.writeContract({
    address: router, abi: routerAbi, functionName: "execute",
    args: [encodePacked(["uint8"], [V4_SWAP]), [input], BigInt(Math.floor(Date.now() / 1000) + 3600)],
    value: tokenIn === NATIVE ? amountIn : 0n,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`swap reverted: ${hash}`);
  return { receipt, gas: gas + gasCost(receipt) };
}

const quoterAbi = parseAbi([
  "function quoteExactOutputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountIn, uint256 gasEstimate)",
]);
const SWAP_EXACT_OUT_SINGLE = 0x08;
const exactOutSingle = parseAbiParameters(
  "(( address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks ) poolKey, bool zeroForOne, uint128 amountOut, uint128 amountInMaximum, uint256 minHopPriceX36, bytes hookData)",
);

/**
 * An exact-out swap through the Universal Router: a buy of exactly `exact` coins, or a sell for exactly `exact` of the
 * Quote Asset, optionally naming a referrer and its Referrer Fee in the trade's `hookData` as a front-end does (ADR
 * 0027). The wallet offers what the V4 Quoter says it costs, so it pays exactly that and the router keeps nothing.
 */
export async function swapExactOut(
  trader: { key: Hex; address: Address }, l: EvmLaunch, side: "buy" | "sell", exact: bigint, referral?: { referrer: Address; bps: number },
) {
  const pub = clients().public;
  const wallet = clients().wallet(trader.key);
  const hookData = referral ? encodeAbiParameters(parseAbiParameters("address, uint256"), [referral.referrer, BigInt(referral.bps)]) : "0x";
  const quoteIsCurrency0 = l.key.currency0 === l.quote;
  const zeroForOne = side === "buy" ? quoteIsCurrency0 : !quoteIsCurrency0;
  const tokenIn = side === "buy" ? l.quote : l.coin;
  const tokenOut = side === "buy" ? l.coin : l.quote;
  const router = ROBINHOOD_CHAIN.uniswap.universalRouter;
  let gas = 0n;
  if (tokenIn !== NATIVE) {
    const approve = await pub.waitForTransactionReceipt({ hash: await wallet.writeContract({ address: tokenIn, abi: erc20Abi, functionName: "approve", args: [ROBINHOOD_CHAIN.uniswap.permit2, 2n ** 256n - 1n] }) });
    const allow = await pub.waitForTransactionReceipt({
      hash: await wallet.writeContract({ address: ROBINHOOD_CHAIN.uniswap.permit2, abi: permit2Abi, functionName: "approve", args: [tokenIn, router, maxUint160, 2 ** 47] }),
    });
    gas += gasCost(approve) + gasCost(allow);
  }
  const { result } = await pub.simulateContract({
    address: ROBINHOOD_CHAIN.uniswap.v4Quoter, abi: quoterAbi, functionName: "quoteExactOutputSingle",
    args: [{ poolKey: l.key, zeroForOne, exactAmount: exact, hookData }],
  });
  const amountIn = result[0];
  const actions = encodePacked(["uint8", "uint8", "uint8"], [SWAP_EXACT_OUT_SINGLE, SETTLE_ALL, TAKE_ALL]);
  const params = [
    encodeAbiParameters(exactOutSingle, [{ poolKey: l.key, zeroForOne, amountOut: exact, amountInMaximum: amountIn, minHopPriceX36: 0n, hookData }]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [tokenIn, amountIn]),
    encodeAbiParameters(parseAbiParameters("address, uint256"), [tokenOut, exact]),
  ];
  const hash = await wallet.writeContract({
    address: router, abi: routerAbi, functionName: "execute",
    args: [encodePacked(["uint8"], [V4_SWAP]), [encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params])], BigInt(Math.floor(Date.now() / 1000) + 3600)],
    value: tokenIn === NATIVE ? amountIn : 0n,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`swap reverted: ${hash}`);
  return { receipt, amountIn, gas: gas + gasCost(receipt) };
}

/** What `who` holds of `asset` (the native asset by the zero address). */
export async function balanceOf(asset: Address, who: Address) {
  const pub = clients().public;
  return asset === NATIVE ? pub.getBalance({ address: who }) : pub.readContract({ address: asset, abi: erc20Abi, functionName: "balanceOf", args: [who] });
}

/** What a transaction cost its sender in gas, in wei, so a native balance's change can be read as the trade alone. */
export const gasCost = (r: TransactionReceipt) => r.gasUsed * r.effectiveGasPrice;

/**
 * Runs the Indexer for every chain it polls, as its cron does, and answers with the run's summary. The fork mines a
 * block per transaction, so it first mines the chain's finality depth, as the chain itself would in half a second, so
 * what the test just did is deep enough to be read.
 */
export async function runIndexer(apiUrl = env().apiUrl) {
  await clients().test.mine({ blocks: ROBINHOOD_CHAIN.finalityDepth });
  const res = await fetch(`${apiUrl}/v1/operator/jobs/indexer`, { method: "POST", headers: { authorization: `Bearer ${env().operatorToken}` } });
  if (!res.ok) throw new Error(`indexer run failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as { status: string; summary: unknown };
}

/**
 * A JSON-RPC proxy in front of the fork that answers as a stricter provider would: `eth_getLogs` over more than
 * `maxLogRange` blocks is refused with -32600, as Alchemy's free tier refuses past 10, and while `failMultiplier` is
 * set every `uiMultiplier()` call fails with HTTP 503, a transport error. `getLogsRanges` keeps every range asked for.
 */
export async function strictRpc(maxLogRange: number) {
  const { createServer } = await import("node:http");
  const { freePort } = await import("@launchpad/stack");
  const upstream = evm()!.rpcUrl;
  const MULTIPLIER = toFunctionSelector("uiMultiplier()");
  const state = { failMultiplier: false, getLogsRanges: [] as number[] };
  const server = createServer((req, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", async () => {
      const calls = [JSON.parse(body)].flat() as { id: number; method: string; params: { fromBlock?: Hex; toBlock?: Hex; data?: Hex; input?: Hex }[] }[];
      for (const call of calls) {
        if (call.method === "eth_getLogs") {
          const range = Number(BigInt(call.params[0]!.toBlock!) - BigInt(call.params[0]!.fromBlock!)) + 1;
          state.getLogsRanges.push(range);
          if (range > maxLogRange) {
            res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: call.id, error: { code: -32600, message: `You can make eth_getLogs requests with up to a ${maxLogRange} block range.` } }));
            return;
          }
        }
        const data = call.params?.[0]?.data ?? call.params?.[0]?.input;
        if (state.failMultiplier && call.method === "eth_call" && data?.startsWith(MULTIPLIER)) {
          res.writeHead(503).end("upstream unavailable");
          return;
        }
      }
      const answer = await fetch(upstream, { method: "POST", headers: { "content-type": "application/json" }, body });
      res.writeHead(answer.status, { "content-type": "application/json" }).end(await answer.text());
    });
  });
  const port = await freePort();
  await new Promise<void>((resolve) => server.listen(port, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${port}`, state, stop: () => new Promise<void>((resolve) => server.close(() => resolve())) };
}

/** The operator's alerts, as the operator view lists them. */
export async function operatorAlerts(apiUrl = env().apiUrl) {
  const res = await fetch(`${apiUrl}/v1/operator/alerts`, { headers: { authorization: `Bearer ${env().operatorToken}` } });
  return ((await res.json()) as { alerts: { kind: string; subject: string; message: string }[] }).alerts;
}
