// The EVM side of the UI suite (#253): what a test needs of the stack's fork of Robinhood Chain around the browser. A
// Stock Token listed on the fork's Quote Registry, a wallet funded with ether and that Stock Token, the cookie that
// shows the fork's chain on the test site, balances read from the chain, and a coin launched through the API as any
// client would, for a flow that starts on a coin's page. Nothing here reaches into the API's internals; the ABIs are
// written out because the suite depends on viem alone.
import type { BrowserContext, Page } from "@playwright/test";
import { createPublicClient, createTestClient, createWalletClient, erc20Abi, http, parseAbi, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { EvmLaunchOptions, EvmTradeQuote, EvmTransactionReport, LaunchSummary, PreparedEvmLaunch } from "@launchpad/contract";
import { QUOTE_CANDIDATES, type EvmStackEnv } from "@launchpad/stack";
import { coinImage, stackEnv } from "./fixtures";
import { installEvmTestWallet, type EvmTestWallet, type EvmTestWalletOptions } from "./evmWallet";

/**
 * The cookie that shows a browser the site's preview chains, and its value (`CHAINS_COOKIE` and `CHAINS_PREVIEW` in
 * apps/web/src/lib/chains.ts). The stack starts the web with the fork's chain as a preview chain, so a page opened
 * without the cookie is Solana's alone, as the site is deployed today, and every other spec's baselines stay as they are.
 */
export const CHAINS_COOKIE = "stoker.chains";
export const CHAINS_PREVIEW = "preview";

/** What the site calls the fork's chain, in full and in plain text, and never anything else (ADR 0028). */
export const CHAIN_NAME = "Robinhood Chain";
/** The unaudited statement up to its link, word for word (ADR 0030, CONTEXT.md). */
export const UNAUDITED = `Stoker's contracts on ${CHAIN_NAME} have not been audited by an independent firm. Their source is public and verified: `;

/** The address that stands for the chain's native asset wherever a Quote Asset is named. */
export const NATIVE: Address = "0x0000000000000000000000000000000000000000";
/**
 * The Stock Token the suite launches against: CrowdStrike's, one of the deployment's candidates, listed at the tick the
 * backend suite lists it at (about $5,000 for a coin's whole supply at the start price). 18 decimals, raw amounts.
 */
export const STOCK = { symbol: "CRWD", address: QUOTE_CANDIDATES.CRWD as Address, startTick: -244_200, decimals: 18 } as const;
/** Every coin of an EVM chain's Launch Shape has 18 decimals. */
export const COIN_DECIMALS = 18;
/** How far behind the head the API's Indexer stops on Robinhood Chain: a transaction this deep is final to it. */
const FINALITY_DEPTH = 5;

const registryAbi = parseAbi([
  "struct Listing { bool listed; int24 startTick; uint16 graduationMultiple; uint16 referrerFeeCapBps; }",
  "function listingOf(address quote) view returns (Listing listing)",
  "function list(address quote, int24 startTick, uint16 graduationMultiple, uint16 referrerFeeCapBps)",
]);

/** Whether the stack has an EVM fork: none without `ROBINHOOD_RPC_URL`, and every EVM flow is then skipped. */
export const hasEvm = () => stackEnv().evm !== null;

export function evmStack(): EvmStackEnv {
  const evm = stackEnv().evm;
  if (!evm) throw new Error("the stack has no EVM fork: start the suite with ROBINHOOD_RPC_URL set");
  return evm;
}

function clients() {
  const e = evmStack();
  const chain = { id: e.chainId, name: "Fork", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [e.rpcUrl] } } };
  // A fork under a loaded Mac can take more than viem's 10 seconds.
  const transport = http(e.rpcUrl, { timeout: 60_000 });
  return {
    chain,
    pub: createPublicClient({ chain, transport }),
    anvil: createTestClient({ chain, transport, mode: "anvil" }),
    wallet: (key: Hex) => createWalletClient({ chain, transport, account: privateKeyToAccount(key) }),
  };
}

async function api(path: string, init?: RequestInit) {
  const res = await fetch(`${stackEnv().apiUrl}${path}`, init);
  if (!res.ok) throw new Error(`${init?.method ?? "GET"} ${path}: ${res.status} ${await res.text()}`);
  return res.json() as Promise<unknown>;
}

/** What the fork's chain offers a Launch, as the API reads it from the contracts. */
export const launchOptions = async () => EvmLaunchOptions.parse(await api(`/v1/chains/${evmStack().chain}/launch-options`));

/** A coin as the API has it. */
export const launchOf = async (coin: string) => LaunchSummary.parse(await api(`/v1/launches/${coin}`));

/** A trade's quote as the API reads it from the chain; `amount` is raw units of what is paid. */
export const quoteOf = async (coin: string, side: "buy" | "sell", amount: bigint) =>
  EvmTradeQuote.parse(await api(`/v1/launches/${coin}/quote?${new URLSearchParams({ side, amount: amount.toString() })}`));

/**
 * Lists the suite's Stock Token on the fork's Quote Registry as the Admin, once, and waits until the launch options
 * name it: the API keeps that answer for a few seconds. The fork is the suite's own, so nothing else lists or delists.
 */
export async function listStock() {
  const e = evmStack();
  const { pub, wallet } = clients();
  const listing = await pub.readContract({ address: e.registry, abi: registryAbi, functionName: "listingOf", args: [STOCK.address] });
  if (!listing.listed) {
    const hash = await wallet(e.admin.key).writeContract({ address: e.registry, abi: registryAbi, functionName: "list", args: [STOCK.address, STOCK.startTick, 20, 100] });
    const receipt = await pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`listing ${STOCK.symbol} on the fork reverted`);
  }
  for (let i = 0; i < 30; i++) {
    const options = await launchOptions();
    if (options.quotes.some((q) => q.mint.toLowerCase() === STOCK.address.toLowerCase())) return options;
    await new Promise((r) => setTimeout(r, 1_000));
  }
  throw new Error(`the launch options never named ${STOCK.symbol}`);
}

export type EvmKey = { key: Hex; address: Address };

/** Gives `to` some of the Stock Token from the PoolManager's own balance, which only a fork lets anyone move. */
async function fundStock(to: Address, amount: bigint) {
  const { anvil, pub, chain } = clients();
  const pm = evmStack().poolManager;
  const held = await pub.readContract({ address: STOCK.address, abi: erc20Abi, functionName: "balanceOf", args: [pm] });
  if (held < amount) throw new Error(`the PoolManager holds ${held} of ${STOCK.symbol} at the fork's block, less than the ${amount} asked for`);
  await anvil.impersonateAccount({ address: pm });
  try {
    await anvil.setBalance({ address: pm, value: (await pub.getBalance({ address: pm })) + 10n ** 18n });
    const hash = await createWalletClient({ chain, transport: http(evmStack().rpcUrl, { timeout: 60_000 }), account: pm }).writeContract({
      address: STOCK.address, abi: erc20Abi, functionName: "transfer", args: [to, amount],
    });
    if ((await pub.waitForTransactionReceipt({ hash })).status !== "success") throw new Error(`moving ${STOCK.symbol} out of the PoolManager reverted`);
  } finally {
    await anvil.stopImpersonatingAccount({ address: pm });
  }
}

/** A fresh key on the fork with ether for gas and, when asked, some of the Stock Token (raw units), as a faucet would fund one. */
export async function fundedEvmKey({ eth = 10n, stock = 0n }: { eth?: bigint; stock?: bigint } = {}): Promise<EvmKey> {
  const key = generatePrivateKey();
  const address = privateKeyToAccount(key).address;
  await clients().anvil.setBalance({ address, value: eth * 10n ** 18n });
  if (stock > 0n) await fundStock(address, stock);
  return { key, address };
}

/** What `who` holds of `asset` on the chain, raw units (the native asset by the zero address). */
export async function evmBalance(asset: Address | string, who: Address | string) {
  const { pub } = clients();
  if (asset === NATIVE) return pub.getBalance({ address: who as Address });
  return pub.readContract({ address: asset as Address, abi: erc20Abi, functionName: "balanceOf", args: [who as Address] });
}

/** The fork's own clock: its latest block's time, in seconds. No block is made while nothing is sent, so it stands still between transactions. */
export const forkTime = async () => (await clients().pub.getBlock({ blockTag: "latest" })).timestamp;

/** Makes empty blocks at the time it is; the clock is never set. */
export const mineBlocks = (blocks = 1) => clients().anvil.mine({ blocks });

/** Shows this browser the site's preview chains, the fork's among them; call before the first navigation. */
export async function showPreviewChains(context: BrowserContext, baseURL: string | undefined) {
  if (!baseURL) throw new Error("the stack has no web app");
  await context.addCookies([{ name: CHAINS_COOKIE, value: CHAINS_PREVIEW, url: baseURL }]);
}

/** Installs the EVM test wallet for `owner` on the fork's chain; call before the first navigation. */
export function installEvmWallet(page: Page, owner: EvmKey, options: Partial<Pick<EvmTestWalletOptions, "startChainId" | "unknownChain">> = {}): Promise<EvmTestWallet> {
  const e = evmStack();
  return installEvmTestWallet(page, { key: owner.key, rpcUrl: e.rpcUrl, chainId: e.chainId, finalityDepth: FINALITY_DEPTH, ...options });
}

export type EvmCoin = { coin: Address; pool: Hex; hash: Hex; symbol: string; name: string; quote: Address; launchedAt: bigint };

/**
 * Launches a standard coin on the fork through the API, as any client's wallet would: prepare, sign the permit a First
 * Buy in an ERC-20 takes, send the launch exactly as it was prepared, then report it until the API has indexed it. The
 * coin's picture is its ticker's own, since Copy Protection covers every chain.
 *
 * With `atSecond` the fork's clock is left exactly that many seconds past the launch's own block, by empty blocks made
 * one after another (a fork stamps blocks made inside one second a second apart, and stands still between them), so a
 * quote read next is the Opening Fee's at that second, the same on every run. The launch is simulated first: on a fork
 * a launch reads dozens of the PoolManager's storage words from the remote chain while it executes, and the simulation
 * leaves them in the fork's cache, so the launch itself returns within its block's own second.
 */
export async function launchEvmViaApi(creator: EvmKey, fields: { name: string; symbol: string; quote?: Address; firstBuy?: bigint; atSecond?: number }): Promise<EvmCoin> {
  const e = evmStack();
  const { pub, anvil, wallet } = clients();
  const quote = fields.quote ?? NATIVE;
  const form = (extra: Record<string, string>) => {
    const body = new FormData();
    const text: Record<string, string> = { chain: e.chain, creator: creator.address, quote, name: fields.name, symbol: fields.symbol, ...extra };
    if (fields.firstBuy) text.firstBuy = fields.firstBuy.toString();
    for (const [k, v] of Object.entries(text)) body.set(k, v);
    if (!extra.salt) body.set("image", new Blob([new Uint8Array(coinImage(fields.symbol))], { type: "image/png" }), "coin.png");
    return body;
  };
  const prepare = async (extra: Record<string, string> = {}) => PreparedEvmLaunch.parse(await api("/v1/launches/prepare", { method: "POST", body: form(extra) }));

  let prepared = await prepare();
  for (let round = 0; prepared.step !== "launch"; round++) {
    if (round >= 3) throw new Error(`the launch of ${fields.symbol} was not reached in four steps`);
    if (prepared.step === "permit" && prepared.permit && prepared.permitDeadline) {
      const signature = await wallet(creator.key).signTypedData(prepared.permit as never);
      prepared = await prepare({ salt: prepared.salt, permitDeadline: prepared.permitDeadline, permitSignature: signature });
    } else if (prepared.step === "approve" && prepared.transaction) {
      const tx = prepared.transaction;
      const hash = await wallet(creator.key).sendTransaction({ to: tx.to as Address, data: tx.data as Hex, value: BigInt(tx.value), gas: BigInt(tx.gas) });
      if ((await pub.waitForTransactionReceipt({ hash })).status !== "success") throw new Error(`the approval for ${fields.symbol} reverted`);
      prepared = await prepare({ salt: prepared.salt });
    } else throw new Error(`the API answered a launch step without what it takes: ${prepared.step}`);
  }
  const tx = prepared.transaction!;
  const request = { to: tx.to as Address, data: tx.data as Hex, value: BigInt(tx.value), gas: BigInt(tx.gas) };
  await pub.call({ account: creator.address, ...request });
  const hash = await wallet(creator.key).sendTransaction(request);
  const receipt = await pub.waitForTransactionReceipt({ hash, pollingInterval: 100 });
  if (receipt.status !== "success") throw new Error(`the launch of ${fields.symbol} reverted: ${hash}`);
  const launchedAt = (await pub.getBlock({ blockNumber: receipt.blockNumber })).timestamp;

  if (fields.atSecond === undefined) await anvil.mine({ blocks: FINALITY_DEPTH });
  else {
    if (fields.atSecond < FINALITY_DEPTH) throw new Error(`a launch is final ${FINALITY_DEPTH} blocks on, so the fork cannot stand at second ${fields.atSecond}`);
    const target = launchedAt + BigInt(fields.atSecond);
    for (let now = launchedAt; now < target; now = await forkTime()) await anvil.mine({ blocks: 1 });
    const stands = (await forkTime()) - launchedAt;
    if (stands !== BigInt(fields.atSecond)) throw new Error(`the fork stands ${stands} seconds past the launch of ${fields.symbol}, not ${fields.atSecond}: the Mac was too slow for the blocks to stay a second apart`);
  }

  for (let i = 0; i < 60; i++) {
    const res = await fetch(`${stackEnv().apiUrl}/v1/transactions/${hash}?chain=${e.chain}`, { method: "POST" });
    if (res.ok && EvmTransactionReport.parse(await res.json()).status === "indexed") {
      return { coin: prepared.coin as Address, pool: prepared.pool as Hex, hash, symbol: fields.symbol, name: fields.name, quote, launchedAt };
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`the API never indexed the launch of ${fields.symbol}`);
}

/**
 * Waits until a Launch's Opening Fee has run out on the fork's own clock: the wall clock first, then an empty block,
 * since a fork's time is its latest block's and no block is made while nothing is sent. The clock is never moved.
 * `launchedAt` is the time of the launch's own block, in seconds.
 */
export async function afterOpeningFee(launchedAt: bigint) {
  const ends = launchedAt + BigInt((await launchOptions()).openingFee.seconds);
  for (;;) {
    const now = await forkTime();
    if (now >= ends) return;
    await new Promise((r) => setTimeout(r, Math.max(Number(ends - now) * 1000, 500)));
    await mineBlocks(1);
  }
}

/** The time of the block a coin was launched in, in seconds, read from the chain by its launch transaction. */
export async function launchedAtOf(coin: string) {
  const { pub } = clients();
  const launch = await launchOf(coin);
  const receipt = await pub.getTransactionReceipt({ hash: launch.createdSignature as Hex });
  return (await pub.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
}
