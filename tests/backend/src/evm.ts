// What a wallet does on an EVM chain (#252): launch through our factory and trade through the Universal Router the
// chain's traffic uses, on the test stack's fork of Robinhood Chain. Nothing here reaches into the API's internals.
import {
  createPublicClient, createTestClient, createWalletClient, encodeAbiParameters, encodePacked, erc20Abi, http, maxUint160, parseAbi,
  keccak256, parseAbiParameters, parseEventLogs, publicActions, toHex, walletActions, type Address, type Hex, type TransactionReceipt,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { quoteRegistryAbi, stokerFactoryAbi, NATIVE, ROBINHOOD_CHAIN } from "@launchpad/evm";
import { env } from "./client";

let otherFork: NonNullable<ReturnType<typeof env>["evm"]> | null = null;
/** The fork every helper here acts on: the stack's, or another one while `onFork` runs. */
export const evm = () => otherFork ?? env().evm;

/** Runs `work` with every helper here acting on another fork (one a test started for itself), then back on the stack's. */
export async function onFork<T>(fork: NonNullable<ReturnType<typeof env>["evm"]>, work: () => Promise<T>): Promise<T> {
  otherFork = fork;
  try {
    return await work();
  } finally {
    otherFork = null;
  }
}

/** The fork's chain, as viem needs it. */
const chainOf = (rpcUrl: string) => ({
  id: ROBINHOOD_CHAIN.chainId, name: ROBINHOOD_CHAIN.name, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [rpcUrl] } },
});

export function clients() {
  const e = evm()!;
  const chain = chainOf(e.rpcUrl);
  // A fork under a loaded Mac can take more than viem's 10 seconds to mine a hundred blocks.
  const transport = http(e.rpcUrl, { timeout: 60_000 });
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
  opts: {
    quote?: Address; firstBuy?: bigint; name?: string; symbol?: string; reward?: { taxBps: number; burnShareBps: number; liquidityShareBps: number };
    lock?: { bps: number; cliff: number; unlock: number };
    /** A Stoke Launch's tax (#215, `liquidity` in code): all of it Support Liquidity. */
    stoke?: { taxBps: number };
    /** The Creator Earnings Destination the Creator's Credits are recorded to (#248): the Creator's own wallet unless set. */
    destination?: Address;
  } = {},
): Promise<EvmLaunch> {
  const e = evm()!;
  const quote = opts.quote ?? NATIVE;
  const firstBuy = opts.firstBuy ?? 0n;
  const tag = `${Date.now().toString(36).slice(-4)}${(salts++).toString(36)}`.toUpperCase();
  const wallet = clients().wallet(creator.key);
  const hash = await wallet.writeContract({
    address: e.factory, abi: stokerFactoryAbi, functionName: "launch",
    args: [{ name: opts.name ?? `Fork Coin ${tag}`, symbol: opts.symbol ?? `F${tag}`, quote, salt: keccak256(toHex(tag)), creatorDestination: opts.destination ?? NATIVE, firstBuy,
      launchType: opts.reward ? LAUNCH_TYPE.reward : opts.stoke ? LAUNCH_TYPE.liquidity : LAUNCH_TYPE.standard, taxBps: opts.reward?.taxBps ?? opts.stoke?.taxBps ?? 0, burnShareBps: opts.reward?.burnShareBps ?? 0,
      liquidityShareBps: opts.reward?.liquidityShareBps ?? 0, payoutAsset: 0,
      creatorLockBps: opts.lock?.bps ?? 0, creatorLockCliff: opts.lock?.cliff ?? 0, creatorLockUnlock: opts.lock?.unlock ?? 0 }],
    gas: SWAP_GAS,
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
/**
 * The gas a test's swap is sent with. The hook moves a taxed pool's Reference Price (#271) only on the first swap of a
 * new second, a storage write that an `eth_estimateGas` made within the previous block's second leaves out, so a swap
 * sent with the bare estimate can land a second later and run out of gas (met on the fork: 181,453 given, the replay
 * fine). A wallet's own margin covers it; #253's prepared trades must carry one.
 */
export const SWAP_GAS = 1_500_000n;
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
    args: [encodePacked(["uint8"], [V4_SWAP]), [input], await deadline()],
    value: tokenIn === NATIVE ? amountIn : 0n,
    gas: SWAP_GAS,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`swap reverted: ${hash}: ${await whyReverted(hash)}`);
  return { receipt, gas: gas + gasCost(receipt) };
}

/**
 * Two exact-in buys in one transaction, one in each coin's pool, through the Universal Router: what an aggregator's
 * route does, and how one transaction comes to touch two deployments' pools.
 */
export async function buyBoth(trader: { key: Hex }, pools: [EvmLaunch, EvmLaunch], amountIn: bigint) {
  const actions = encodePacked(["uint8", "uint8", "uint8"], [SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL]);
  const inputs = pools.map((l) =>
    encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, [
      encodeAbiParameters(exactInSingle, [{ poolKey: l.key, zeroForOne: l.key.currency0 === l.quote, amountIn, amountOutMinimum: 0n, minHopPriceX36: 0n, hookData: "0x" }]),
      encodeAbiParameters(parseAbiParameters("address, uint256"), [l.quote, amountIn]),
      encodeAbiParameters(parseAbiParameters("address, uint256"), [l.coin, 0n]),
    ]]),
  );
  const hash = await clients().wallet(trader.key).writeContract({
    address: ROBINHOOD_CHAIN.uniswap.universalRouter, abi: routerAbi, functionName: "execute",
    args: [encodePacked(["uint8", "uint8"], [V4_SWAP, V4_SWAP]), inputs, await deadline()], value: amountIn * 2n, gas: SWAP_GAS * 2n,
  });
  const receipt = await clients().public.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`swap reverted: ${hash}: ${await whyReverted(hash)}`);
  return receipt;
}

const quoterAbi = parseAbi([
  "function quoteExactOutputSingle(((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) poolKey, bool zeroForOne, uint128 exactAmount, bytes hookData) params) returns (uint256 amountIn, uint256 gasEstimate)",
]);
const SWAP_EXACT_OUT_SINGLE = 0x08;
/** The Universal Router's SWEEP, and its stand-in for "the caller" as a recipient (Commands.sol, Constants.sol). */
const SWEEP = 0x04;
const MSG_SENDER: Address = "0x0000000000000000000000000000000000000001";
const exactOutSingle = parseAbiParameters(
  "(( address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks ) poolKey, bool zeroForOne, uint128 amountOut, uint128 amountInMaximum, uint256 minHopPriceX36, bytes hookData)",
);

/**
 * An exact-out swap through the Universal Router: a buy of exactly `exact` coins, or a sell for exactly `exact` of the
 * Quote Asset, optionally naming a referrer and its Referrer Fee in the trade's `hookData` as a front-end does (ADR
 * 0027). The wallet offers what the V4 Quoter says it costs; a native buy also sweeps back what the swap did not take,
 * as a front-end must: the Opening Fee (#246) falls every second, so a quote made a second before over-asks, and
 * without the sweep the rest would stay in the router for anyone to take.
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
  const swap = encodeAbiParameters(parseAbiParameters("bytes, bytes[]"), [actions, params]);
  const sweep = tokenIn === NATIVE ? [encodeAbiParameters(parseAbiParameters("address, address, uint256"), [NATIVE, MSG_SENDER, 0n])] : [];
  const hash = await wallet.writeContract({
    address: router, abi: routerAbi, functionName: "execute",
    args: [sweep.length ? encodePacked(["uint8", "uint8"], [V4_SWAP, SWEEP]) : encodePacked(["uint8"], [V4_SWAP]), [swap, ...sweep], await deadline()],
    value: tokenIn === NATIVE ? amountIn : 0n,
    gas: SWAP_GAS,
  });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`swap reverted: ${hash}: ${await whyReverted(hash)}`);
  return { receipt, amountIn, gas: gas + gasCost(receipt) };
}

/** An hour after the fork's own latest block: the fork's clock is its own (a test may move it), never the wall clock's. */
const deadline = async () => (await clients().public.getBlock({ blockTag: "latest" })).timestamp + 3600n;

/**
 * Why a mined transaction reverted: the same call replayed on the block before it, so the reason is decoded; "it
 * replays without reverting" points at the gas it was given rather than the state.
 */
export async function whyReverted(hash: Hex) {
  const pub = clients().public;
  const tx = await pub.getTransaction({ hash });
  try {
    await pub.call({ account: tx.from, to: tx.to!, data: tx.input, value: tx.value, blockNumber: tx.blockNumber! - 1n });
    return `it replays without reverting (gas limit ${tx.gas})`;
  } catch (e) {
    return (e as Error).message.split("\n").slice(0, 3).join(" ");
  }
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

/** The operator's alerts, as the operator view lists them. */
export async function operatorAlerts(apiUrl = env().apiUrl) {
  const res = await fetch(`${apiUrl}/v1/operator/alerts`, { headers: { authorization: `Bearer ${env().operatorToken}` } });
  return ((await res.json()) as { alerts: { kind: string; subject: string; message: string; resolvedAt: string | null }[] }).alerts;
}

/** Runs one of the API's jobs by hand, as the operator does, and answers with the run. */
export async function runApiJob(job: string, apiUrl = env().apiUrl) {
  const res = await fetch(`${apiUrl}/v1/operator/jobs/${job}`, { method: "POST", headers: { authorization: `Bearer ${env().operatorToken}` } });
  return (await res.json()) as { status: string; error: string | null; summary: { chains: Record<string, unknown>[] } };
}

/**
 * Runs the Keeper (#254) as its cron does. It decides on the chain's `safe` block, which anvil answers 32 blocks behind
 * its head, so the fork first mines past it, as the chain would in seconds; then the Indexer reads what it sent.
 */
export async function runKeeper(apiUrl = env().apiUrl) {
  await clients().test.mine({ blocks: 40 });
  const run = await runApiJob("keeper", apiUrl);
  if (run.status !== "succeeded") throw new Error(`keeper run ${run.status}: ${run.error}`);
  await runIndexer(apiUrl);
  return run.summary.chains[0] as { paid: { asset: string; owners: number; hash: string }[]; support: { coin: string; hash: string }[]; burned: { coin: string; hash: string }[]; applied: { coin: string; hash: string }[]; refused: { call: string; subject: string; reason: string }[] };
}

/** One page of the Ledger, as anyone reads it. */
export async function ledgerOf(query: string, apiUrl = env().apiUrl) {
  const res = await fetch(`${apiUrl}/v1/ledger?limit=100&${query}`);
  if (!res.ok) throw new Error(`GET /v1/ledger?${query}: ${res.status} ${await res.text()}`);
  return ((await res.json()) as { entries: LedgerRow[] }).entries;
}

export type LedgerRow = { chain: string; signature: string; index: number; kind: string; asset: { mint: string; decimals: number }; amount: string; source: string; destination: string; launch: { mint: string } | null; slot: number };
