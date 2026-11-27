// An EIP-6963 wallet for the browser under test (#253), beside the Solana stand-in in `wallet.ts`. The page sees an
// ordinary injected EVM wallet that announces itself; the key stays in Node, where viem signs with it and talks to the
// fork, and every request crosses through an exposed function, so a test decides per request whether the "user"
// approves, declines or takes their time, and can start the wallet on the wrong network.
import { expect, type Locator, type Page } from "@playwright/test";
import { createPublicClient, createTestClient, createWalletClient, defineChain, http, numberToHex, type Hex, type TypedDataDefinition } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const TEST_EVM_WALLET_NAME = "Test EVM Wallet";
/** The wallet's reverse-DNS name, which the site remembers it by between page loads. */
export const TEST_EVM_WALLET_RDNS = "markets.stoker.test-evm-wallet";

const ICON = `data:image/svg+xml;base64,${Buffer.from(
  `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#0e7a6b"/>` +
    `<path d="M16 6 8 16l8 4 8-4-8-10Zm0 20-8-8 8 4 8-4-8 8Z" fill="#fff"/></svg>`,
).toString("base64")}`;

/** EIP-1193's codes: the user said no; the method is not one this wallet has; the wallet has never met the chain. */
const USER_REJECTED = 4001;
const UNSUPPORTED = 4200;
const UNKNOWN_CHAIN = 4902;

/** A request the wallet was asked to approve: a transaction to send, or typed data to sign, as the page handed it over. */
export type EvmWalletRequest =
  | { method: "eth_sendTransaction"; transaction: { from?: string; to?: string; data?: string; value?: string; gas?: string } }
  | { method: "eth_signTypedData_v4"; address: string; typedData: Record<string, unknown> };

export type EvmTestWallet = {
  address: Hex;
  /** Every transaction and every signature the wallet was asked for, in order, as the page handed it over. */
  requests: EvmWalletRequest[];
  /** The hash of every transaction the wallet sent, in order. */
  sent: Hex[];
  /** The chain the wallet is on now, by its id. */
  chainId: () => number;
  /** The next transaction or signature request is declined, as a user pressing "Reject" in their wallet. */
  declineNext: () => void;
  /**
   * The next transaction or signature request waits until `release` is called, as a user reading their wallet's screen
   * before they approve: the page shows its signing step meanwhile.
   */
  holdNext: () => { release: () => void };
};

export type EvmTestWalletOptions = {
  /** The wallet's private key; its account must hold the fork's native asset to pay for gas. */
  key: Hex;
  /** The fork's RPC, which only Node talks to. */
  rpcUrl: string;
  /** The fork's chain id: the chain the site's coins and launches are on. */
  chainId: number;
  /** The chain the wallet starts on, when a test begins on the wrong network; the fork's own when left out. */
  startChainId?: number;
  /**
   * Whether the wallet has never met the fork's chain: it then answers a switch with 4902 until the site has added the
   * chain (`wallet_addEthereumChain`). False when left out.
   */
  unknownChain?: boolean;
  /** Blocks mined after each transaction, so the API's Indexer, which stops this far behind the head, can read it. Robinhood Chain's 5 when left out. */
  finalityDepth?: number;
};

type InitArgs = { name: string; icon: string; rdns: string; uuid: string };
type Answer = { result: unknown } | { error: { code: number; message: string } };

/** Runs in the page before any app code: announces the wallet to whichever EIP-6963 app asks, and forwards every request to Node. */
function register({ name, icon, rdns, uuid }: InitArgs) {
  const ask = (window as unknown as { __testEvmWallet: (method: string, params: string) => Promise<Answer> }).__testEvmWallet;
  const listeners = new Map<string, Set<(payload: unknown) => void>>();
  const emit = (event: string, payload: unknown) => listeners.get(event)?.forEach((listener) => listener(payload));
  const provider = {
    request: async ({ method, params }: { method: string; params?: unknown }) => {
      const answer = await ask(method, JSON.stringify(params ?? []));
      if ("error" in answer) throw Object.assign(new Error(answer.error.message), { code: answer.error.code });
      // A wallet says so when its chain or its accounts change; the site follows the events, not its own guess.
      if (method === "wallet_switchEthereumChain") emit("chainChanged", (params as [{ chainId: string }])[0].chainId);
      if (method === "eth_requestAccounts") emit("accountsChanged", answer.result);
      return answer.result;
    },
    on: (event: string, listener: (payload: unknown) => void) => {
      if (!listeners.has(event)) listeners.set(event, new Set());
      listeners.get(event)!.add(listener);
    },
    removeListener: (event: string, listener: (payload: unknown) => void) => {
      listeners.get(event)?.delete(listener);
    },
  };
  const detail = Object.freeze({ info: Object.freeze({ uuid, name, icon, rdns }), provider });
  const announce = () => window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail }));
  window.addEventListener("eip6963:requestProvider", announce);
  announce();
}

/** Opens the wallet menu from a "Connect wallet" button (or the account's own button) and connects the EVM test wallet from it. */
export async function connectEvmTestWallet(page: Page, button: Locator) {
  const item = page.getByRole("menuitem", { name: TEST_EVM_WALLET_NAME });
  // A click that lands before the page has hydrated does nothing, so the menu is asked for until it is open.
  await expect(async () => {
    if (!(await item.isVisible())) await button.click();
    await expect(item).toBeVisible({ timeout: 1_000 });
  }).toPass({ timeout: 30_000 });
  await item.click();
}

/** Installs the wallet into a page; call before the first navigation. */
export async function installEvmTestWallet(page: Page, { key, rpcUrl, chainId, startChainId, unknownChain = false, finalityDepth = 5 }: EvmTestWalletOptions): Promise<EvmTestWallet> {
  const account = privateKeyToAccount(key);
  const chain = defineChain({ id: chainId, name: "Fork", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } });
  const transport = http(rpcUrl);
  const reader = createPublicClient({ chain, transport });
  const signer = createWalletClient({ account, chain, transport });
  const miner = createTestClient({ chain, transport, mode: "anvil" });

  let current = startChainId ?? chainId;
  let connected = false;
  const known = new Set<number>([current, ...(unknownChain ? [] : [chainId])]);
  let decline = false;
  let held: Promise<void> | null = null;
  const wallet: EvmTestWallet = {
    address: account.address,
    requests: [],
    sent: [],
    chainId: () => current,
    declineNext: () => void (decline = true),
    holdNext: () => {
      let release!: () => void;
      held = new Promise<void>((resolve) => (release = resolve));
      return { release };
    },
  };

  class WalletError extends Error {
    constructor(readonly code: number, message: string) {
      super(message);
    }
  }

  /** The "user" at their wallet's screen: they may take their time, and they may say no. */
  async function approve() {
    if (held) {
      const wait = held;
      held = null;
      await wait;
    }
    if (decline) {
      decline = false;
      throw new WalletError(USER_REJECTED, "User rejected the request.");
    }
  }

  async function handle(method: string, params: unknown[]): Promise<unknown> {
    switch (method) {
      case "eth_requestAccounts":
        connected = true;
        return [account.address];
      case "eth_accounts":
        return connected ? [account.address] : [];
      case "eth_chainId":
        return numberToHex(current);
      case "wallet_switchEthereumChain": {
        const to = Number(BigInt((params[0] as { chainId: string }).chainId));
        if (!known.has(to)) throw new WalletError(UNKNOWN_CHAIN, `Unrecognized chain ID "${numberToHex(to)}".`);
        current = to;
        return null;
      }
      case "wallet_addEthereumChain":
        known.add(Number(BigInt((params[0] as { chainId: string }).chainId)));
        return null;
      case "eth_sendTransaction": {
        const tx = params[0] as { from?: string; to?: Hex; data?: Hex; value?: Hex; gas?: Hex };
        wallet.requests.push({ method, transaction: tx });
        await approve();
        // The stand-in can only reach the fork: a transaction sent while it is on another network is the site's fault to show.
        if (current !== chainId) throw new WalletError(-32603, `The test wallet is on chain ${current}, not ${chainId}: the site must ask it to switch first.`);
        // Sent exactly as it was given: the same target, data, value and gas limit; the node prices the gas.
        const hash = await signer.sendTransaction({ to: tx.to, data: tx.data, value: tx.value ? BigInt(tx.value) : 0n, gas: tx.gas ? BigInt(tx.gas) : undefined });
        // The Indexer stops a few blocks behind the head, so the chain is taken that far past the transaction.
        if (finalityDepth > 0) await miner.mine({ blocks: finalityDepth });
        wallet.sent.push(hash);
        return hash;
      }
      case "eth_signTypedData_v4": {
        const typedData = JSON.parse(params[1] as string) as Record<string, unknown>;
        wallet.requests.push({ method, address: params[0] as string, typedData });
        await approve();
        return account.signTypedData(typedData as unknown as TypedDataDefinition);
      }
      // Reads go to the fork as they are: the receipt the site waits for, and a balance at a block.
      case "eth_getTransactionReceipt":
      case "eth_getTransactionByHash":
      case "eth_getBalance":
      case "eth_blockNumber":
      case "eth_gasPrice":
      case "eth_estimateGas":
      case "eth_call":
        return reader.request({ method, params } as never);
      default:
        throw new WalletError(UNSUPPORTED, `The test wallet does not support ${method}.`);
    }
  }

  await page.exposeFunction("__testEvmWallet", async (method: string, params: string): Promise<Answer> => {
    try {
      return { result: await handle(method, JSON.parse(params) as unknown[]) };
    } catch (e) {
      // An error thrown across the bridge loses its code, so it travels as data and the page throws it again.
      return { error: { code: e instanceof WalletError ? e.code : -32603, message: (e as Error).message } };
    }
  });
  // A script run through tsx carries esbuild's `__name` helper into the injected function; the page has it defined first.
  await page.addInitScript("globalThis.__name ??= (target) => target;");
  await page.addInitScript(register, { name: TEST_EVM_WALLET_NAME, icon: ICON, rdns: TEST_EVM_WALLET_RDNS, uuid: "7f3b6c1e-2a4d-4e8b-9c1f-5d2a8b7e6f40" } satisfies InitArgs);
  return wallet;
}
