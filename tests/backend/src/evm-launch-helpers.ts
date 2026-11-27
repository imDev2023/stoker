// What a Creator's wallet does to launch on an EVM chain through the API (#253): ask what the chain offers, prepare,
// then sign and send exactly what the API answered, on the test stack's fork of Robinhood Chain. Black box: HTTP and
// the chain, nothing of the API's own.
import { deflateSync } from "node:zlib";
import { erc20Abi, parseEventLogs, type Address, type Hex, type TransactionReceipt } from "viem";
import { expect } from "vitest";
import {
  CopyCheck, EvmLaunchOptions, EvmLaunchQuote, EvmTransactionReport, LaunchSummary, PreparedEvmLaunch, type EvmTransaction, type EvmTypedData,
} from "@launchpad/contract";
import { quoteRegistryAbi, stokerFactoryAbi } from "@launchpad/evm";
import { QUOTE_CANDIDATES } from "@launchpad/stack";
import { env, PNG, uniqueTag } from "./client";
import { clients, evm, listQuote } from "./evm";

export const { CRWD, AAPL, NVDA, USDG } = QUOTE_CANDIDATES;
/** About $5,000 for the whole supply at the start price: a Stock Token near $450 (`evm-indexer.test.ts` lists CRWD at the same tick). */
export const STOCK_START_TICK = -244_200;

type Rgb = [number, number, number];
/**
 * A PNG in two colours, big enough to hash, in upright stripes: `stripes` of them, the first in `b`. Copy Protection
 * compares pictures across every launch on the shared stack by which side of each edge is the brighter, so a test's
 * picture must differ from `copies.test.ts`'s (eight stripes, the first the darker) in the stripes' count or order.
 */
export function png(a: Rgb, b: Rgb, size = 32, stripes = 8) {
  const rows: number[] = [];
  for (let y = 0; y < size; y++) {
    rows.push(0);
    for (let x = 0; x < size; x++) rows.push(...(Math.floor((x * stripes) / size) % 2 ? a : b));
  }
  const crc32 = (buf: Buffer) => {
    let c = ~0;
    for (const byte of buf) {
      c ^= byte;
      for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
    }
    return ~c;
  };
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body) >>> 0);
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return new Uint8Array(Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk("IHDR", ihdr), chunk("IDAT", deflateSync(Buffer.from(rows))), chunk("IEND", Buffer.alloc(0)),
  ]));
}

export type EvmLaunchForm = {
  creator: Address;
  quote?: Address;
  name?: string;
  symbol?: string;
  description?: string;
  website?: string;
  x?: string;
  telegram?: string;
  firstBuy?: string;
  rewardTax?: string;
  rewardPayout?: string;
  rewardBurn?: string;
  rewardLiquidity?: string;
  liquidityTax?: string;
  earningsDestination?: string;
  lockBps?: string;
  lockCliffSeconds?: string;
  lockUnlockSeconds?: string;
  salt?: string;
  permitDeadline?: string;
  permitSignature?: string;
  chain?: string;
  /** The suite's 1x1 PNG unless given, which is too small to be compared with any other; null sends none. */
  image?: Uint8Array | null;
};

const NATIVE: Address = "0x0000000000000000000000000000000000000000";

/** A name and a ticker no other launch has, far enough apart that Copy Protection never takes two for near copies. */
export function ownName() {
  const tag = uniqueTag();
  return { name: `Forge ${tag}`, symbol: `F${tag}` };
}

/** POST /v1/launches/prepare for the fork's chain, exactly the fields given (plus a name and a ticker of its own, and a picture). */
export function prepareEvm(form: EvmLaunchForm) {
  const body = new FormData();
  const { image, ...rest } = form;
  const fields = { chain: "robinhood", quote: NATIVE, description: "A coin forged on the fork", ...(rest.name && rest.symbol ? {} : ownName()), ...rest };
  for (const [k, v] of Object.entries(fields)) if (typeof v === "string") body.set(k, v);
  const picture = image === undefined ? (form.salt ? null : PNG) : image;
  if (picture) body.set("image", new Blob([picture], { type: "image/png" }), "coin.png");
  return fetch(`${env().apiUrl}/v1/launches/prepare`, { method: "POST", body });
}

/** A prepare that must answer 200, parsed. */
export async function prepared(form: EvmLaunchForm) {
  const res = await prepareEvm(form);
  if (!res.ok) throw new Error(`prepare failed: ${res.status} ${await res.text()}`);
  return PreparedEvmLaunch.parse(await res.json());
}

/** A prepare that must be refused: its status and its error. */
export async function refusal(form: EvmLaunchForm) {
  const res = await prepareEvm(form);
  const body = (await res.json()) as { error: string; details?: unknown; refusals?: { field: string; reason: string }[]; copy?: { kind: string; of: { mint: string; chain: string } } };
  return { status: res.status, ...body };
}

/** The wallet side: sends a prepared transaction exactly as the API gave it (`to`, `data`, `value`, `gas`), and waits for it. */
export async function send(wallet: { key: Hex }, tx: EvmTransaction): Promise<TransactionReceipt> {
  expect(tx.chainId).toBe(evm()!.chainId);
  const hash = await clients().wallet(wallet.key).sendTransaction({ to: tx.to as Address, data: tx.data as Hex, value: BigInt(tx.value), gas: BigInt(tx.gas) });
  const receipt = await clients().public.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`the prepared transaction reverted: ${hash}`);
  return receipt;
}

/** The wallet side of a permit: signs the typed data exactly as the API gave it (`eth_signTypedData_v4`). */
export function signTypedData(wallet: { key: Hex }, data: EvmTypedData) {
  return clients().wallet(wallet.key).signTypedData(data as never);
}

/** The factory's `Launched` event of a launch transaction. */
export function launchedIn(receipt: TransactionReceipt) {
  const [launched] = parseEventLogs({ abi: stokerFactoryAbi, logs: receipt.logs, eventName: "Launched" });
  if (!launched) throw new Error(`no Launched event in ${receipt.transactionHash}`);
  return launched.args;
}

/** Gives `to` some of an ERC-20 from the PoolManager's own balance, which only a fork lets anyone move. */
export async function fundWith(asset: Address, to: Address, amount: bigint) {
  const { test: anvil } = clients();
  const pm = evm()!.poolManager;
  await anvil.impersonateAccount({ address: pm });
  await anvil.setBalance({ address: pm, value: 10n ** 18n });
  await anvil.waitForTransactionReceipt({ hash: await anvil.writeContract({ account: pm, chain: anvil.chain, address: asset, abi: erc20Abi, functionName: "transfer", args: [to, amount] }) });
  await anvil.stopImpersonatingAccount({ address: pm });
}

/** CrowdStrike's Stock Token listed on the fork's Quote Registry, as `evm-indexer.test.ts` lists it. */
export const listCrwd = () => listQuote(CRWD, STOCK_START_TICK);

/** An asset's Listing as the fork's Quote Registry has it now: the stack is shared, so a test reads it rather than assume it. */
export const listingOnChain = (quote: Address) => clients().public.readContract({ address: evm()!.registry, abi: quoteRegistryAbi, functionName: "listingOf", args: [quote] });

/** Delists a Quote Asset on the fork's Quote Registry as the Admin: no new Launch may pair with it from that block. */
export async function delistQuote(quote: Address) {
  const e = evm()!;
  const hash = await clients().wallet(e.admin.key).writeContract({ address: e.registry, abi: quoteRegistryAbi, functionName: "delist", args: [quote] });
  await clients().public.waitForTransactionReceipt({ hash });
}

async function api(path: string, init?: RequestInit) {
  const res = await fetch(`${env().apiUrl}${path}`, init);
  if (!res.ok) throw new Error(`${init?.method ?? "GET"} ${path}: ${res.status} ${await res.text()}`);
  return res.json() as Promise<unknown>;
}

export const launchOptions = async () => EvmLaunchOptions.parse(await api("/v1/chains/robinhood/launch-options"));

/** The options once they answer `listed`, which the API keeps a few seconds: a Listing just written shows within them. */
export async function optionsListing(asset: Address) {
  await expect.poll(async () => (await launchOptions()).quotes.map((q) => q.mint), { timeout: 15_000, interval: 1_000 }).toContain(asset);
  return launchOptions();
}

export const launchQuote = (query: Record<string, string>) => fetch(`${env().apiUrl}/v1/chains/robinhood/launch-quote?${new URLSearchParams(query)}`);
export const quoted = async (query: Record<string, string>) => {
  const res = await launchQuote(query);
  if (!res.ok) throw new Error(`launch-quote failed: ${res.status} ${await res.text()}`);
  return EvmLaunchQuote.parse(await res.json());
};

/** POST /v1/launches/check, as the launch form asks while the Creator types. */
export async function check(fields: { chain?: string; creator?: string; name?: string; symbol?: string; description?: string; links?: string; image?: Uint8Array }) {
  const body = new FormData();
  for (const [k, v] of Object.entries(fields)) if (typeof v === "string") body.set(k, v);
  if (fields.image) body.set("image", new Blob([fields.image], { type: "image/png" }), "coin.png");
  const res = await fetch(`${env().apiUrl}/v1/launches/check`, { method: "POST", body });
  expect(res.status).toBe(200);
  const json = (await res.json()) as Record<string, unknown>;
  return { ...CopyCheck.parse(json), keys: Object.keys(json) };
}

/** POST /v1/transactions/:hash?chain=robinhood: the site's report of a transaction it sent. */
export async function report(hash: Hex) {
  const res = await fetch(`${env().apiUrl}/v1/transactions/${hash}?chain=robinhood`, { method: "POST" });
  return { status: res.status, body: res.ok ? EvmTransactionReport.parse(await res.json()) : null };
}

export const coinPage = async (coin: string) => LaunchSummary.parse(await api(`/v1/launches/${coin}`));
