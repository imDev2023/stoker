import type { EvmLaunchOptions, EvmTransaction, EvmTypedData } from "@launchpad/contract";

/**
 * An EVM wallet as the site talks to one (#253): the wallet's own EIP-1193 `request` and nothing else. The API prepares
 * every transaction and every typed-data signature (ADR 0003), so nothing here knows an ABI, and the web app takes no
 * viem, ethers or wagmi: a transaction is sent as it arrived, a signature is asked for the data as it arrived, and a
 * receipt is read by asking for it until the chain has one.
 */
export type Eip1193Provider = {
  request: (args: { method: string; params?: unknown }) => Promise<unknown>;
  on?: (event: string, listener: (payload: never) => void) => void;
  removeListener?: (event: string, listener: (payload: never) => void) => void;
};

/** A wallet a browser announced (EIP-6963): what the menu names it by, and its provider. */
export type AnnouncedWallet = {
  uuid: string;
  name: string;
  icon: string;
  /** The wallet's reverse-DNS name, which stays the same between visits: what the site remembers a wallet by. */
  rdns: string;
  provider: Eip1193Provider;
};

/** What `wallet_addEthereumChain` takes for a chain, as the chain's launch options carry it. */
export type WalletChain = EvmLaunchOptions["wallet"];

/** EIP-1193's codes: the user said no; the wallet has never met the chain. */
const USER_REJECTED = 4001;
const UNKNOWN_CHAIN = 4902;

type ProviderError = { code?: number; message?: string; data?: { originalError?: { code?: number } } };

const codeOf = (e: unknown) => (e as ProviderError | null)?.code;
const messageOf = (e: unknown) => String((e as ProviderError | null)?.message ?? "");

/** Declining in the wallet is the user's choice, not an error: the component that asked says what happened. */
export function isRejection(e: unknown) {
  return codeOf(e) === USER_REJECTED || /reject|denied|declin|cancel/i.test(messageOf(e));
}

/** A wallet or its node saying the account cannot pay: for the amount sent with a transaction, or for its network fee. */
export function isShortOfFunds(e: unknown) {
  return /insufficient funds|insufficient balance|exceeds (the )?balance/i.test(messageOf(e));
}

/** A raw integer amount (a decimal string, or a bigint) as the hex quantity a wallet takes. */
export const toQuantity = (amount: string | bigint) => `0x${BigInt(amount).toString(16)}`;
/** A hex quantity a wallet answered, as a bigint. */
export const fromQuantity = (hex: string) => BigInt(hex);

/** Asks the wallet to connect, which opens it: the accounts it lets the site see, the one in use first. */
export async function requestAccounts(provider: Eip1193Provider) {
  return (await provider.request({ method: "eth_requestAccounts" })) as string[];
}

/** The accounts the wallet already lets the site see, asked quietly: none opens nothing. */
export async function readAccounts(provider: Eip1193Provider) {
  return (await provider.request({ method: "eth_accounts" })) as string[];
}

/** The chain the wallet is on, by its id. */
export async function readChainId(provider: Eip1193Provider) {
  return Number(fromQuantity((await provider.request({ method: "eth_chainId" })) as string));
}

/**
 * Moves the wallet to a chain. A wallet that has never met the chain says so (4902, which some wallets wrap), and is
 * then given the chain to add, from the chain's own launch options, before it is asked to switch again.
 */
export async function switchChain(provider: Eip1193Provider, chain: WalletChain) {
  const chainId = toQuantity(chain.chainId);
  const ask = () => provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] });
  try {
    await ask();
  } catch (e) {
    const unknown = codeOf(e) === UNKNOWN_CHAIN || (e as ProviderError | null)?.data?.originalError?.code === UNKNOWN_CHAIN || /unrecognized chain|unknown chain/i.test(messageOf(e));
    if (!unknown) throw e;
    await provider.request({ method: "wallet_addEthereumChain", params: [{ ...chain, chainId }] });
    await ask();
  }
}

/** Sends a transaction the API prepared, exactly as it arrived, and answers its hash. The wallet sets the gas price. */
export async function sendTransaction(provider: Eip1193Provider, from: string, tx: EvmTransaction) {
  const params = [{ from, to: tx.to, data: tx.data, value: toQuantity(tx.value), gas: toQuantity(tx.gas) }];
  return (await provider.request({ method: "eth_sendTransaction", params })) as string;
}

/** Asks the wallet to sign typed data the API prepared (EIP-712), exactly as it arrived. A signature costs no gas. */
export async function signTypedData(provider: Eip1193Provider, from: string, typed: EvmTypedData) {
  return (await provider.request({ method: "eth_signTypedData_v4", params: [from, JSON.stringify(typed)] })) as string;
}

export type EvmLog = { address: string; topics: string[]; data: string };
/** A transaction's receipt, as far as the site reads one. */
export type EvmReceipt = { hash: string; block: number; succeeded: boolean; gasUsed: bigint; gasPrice: bigint; logs: EvmLog[] };

type RawReceipt = { transactionHash: string; blockNumber: string; status?: string; gasUsed: string; effectiveGasPrice?: string; logs?: EvmLog[] };

/** A transaction that the chain took and reverted: nothing it was meant to do happened, and its network fee was paid. */
export class EvmReverted extends Error {
  constructor(readonly receipt: EvmReceipt) {
    super("The transaction failed on the chain.");
  }
}

/** A transaction whose receipt never came in the time allowed: it may still land. */
export class EvmReceiptTimeout extends Error {
  constructor(readonly hash: string) {
    super("The transaction was not seen to land in time.");
  }
}

const pause = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Waits for a transaction's receipt by asking the wallet's own node until it has one. A reverted transaction throws
 * `EvmReverted`; none within `timeoutMs` throws `EvmReceiptTimeout`. A read that fails is asked again.
 */
export async function waitForReceipt(provider: Eip1193Provider, hash: string, { timeoutMs = 120_000, everyMs = 1_000 }: { timeoutMs?: number; everyMs?: number } = {}): Promise<EvmReceipt> {
  const until = Date.now() + timeoutMs;
  for (;;) {
    const raw = (await provider.request({ method: "eth_getTransactionReceipt", params: [hash] }).catch(() => null)) as RawReceipt | null;
    if (raw?.blockNumber) {
      const receipt: EvmReceipt = {
        hash,
        block: Number(fromQuantity(raw.blockNumber)),
        succeeded: raw.status === undefined || fromQuantity(raw.status) === 1n,
        gasUsed: fromQuantity(raw.gasUsed),
        gasPrice: raw.effectiveGasPrice ? fromQuantity(raw.effectiveGasPrice) : 0n,
        logs: raw.logs ?? [],
      };
      if (!receipt.succeeded) throw new EvmReverted(receipt);
      return receipt;
    }
    if (Date.now() >= until) throw new EvmReceiptTimeout(hash);
    await pause(everyMs);
  }
}

/** The topic of an ERC-20 `Transfer(address,address,uint256)` log, whose second and third topics are who paid and who was paid. */
const TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
/** An address as a log's topic carries it: 32 bytes, lower case. */
const asTopic = (address: string) => `0x${address.slice(2).toLowerCase().padStart(64, "0")}`;

/**
 * What a transaction moved of one ERC-20 into a wallet, less what it moved out of it, read from the receipt's own
 * `Transfer` logs: positive when the wallet received, negative when it paid. The figure is the chain's, never a quote's.
 */
export function erc20Moved(receipt: EvmReceipt, asset: string, wallet: string): bigint {
  const who = asTopic(wallet);
  let moved = 0n;
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== asset.toLowerCase() || log.topics[0]?.toLowerCase() !== TRANSFER_TOPIC || log.topics.length < 3) continue;
    const amount = log.data === "0x" ? 0n : fromQuantity(log.data);
    if (log.topics[2]!.toLowerCase() === who) moved += amount;
    if (log.topics[1]!.toLowerCase() === who) moved -= amount;
  }
  return moved;
}

/** A wallet's balance of the chain's native asset at a block, in wei; null when the wallet's node cannot say. */
async function nativeBalanceAt(provider: Eip1193Provider, wallet: string, block: number): Promise<bigint | null> {
  try {
    return fromQuantity((await provider.request({ method: "eth_getBalance", params: [wallet, toQuantity(BigInt(block))] })) as string);
  } catch {
    return null;
  }
}

/**
 * What a transaction moved of the chain's native asset into the wallet that sent it, apart from its network fee: the
 * balance after the transaction's block less the balance before it, with the receipt's own fee added back. Right when
 * the transaction is the wallet's only one in its block, which a wallet's one trade is. Null when the node cannot say.
 */
export async function nativeMoved(provider: Eip1193Provider, receipt: EvmReceipt, wallet: string): Promise<bigint | null> {
  const [before, after] = await Promise.all([nativeBalanceAt(provider, wallet, receipt.block - 1), nativeBalanceAt(provider, wallet, receipt.block)]);
  if (before === null || after === null) return null;
  return after - before + receipt.gasUsed * receipt.gasPrice;
}
