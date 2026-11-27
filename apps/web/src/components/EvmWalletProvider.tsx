"use client";

import { createStore } from "mipd";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { EvmTransaction, EvmTypedData } from "@launchpad/contract";
import {
  isRejection, readAccounts, readChainId, requestAccounts, sendTransaction, signTypedData, switchChain, waitForReceipt,
  type AnnouncedWallet, type Eip1193Provider, type EvmReceipt, type WalletChain,
} from "@/lib/evmWallet";

/** Where the browser keeps the name of the wallet it last connected, so the next visit comes back to it without asking. */
const REMEMBERED_KEY = "stoker.evm-wallet";

function remembered() {
  try {
    return window.localStorage.getItem(REMEMBERED_KEY);
  } catch {
    return null;
  }
}

function remember(rdns: string | null) {
  try {
    if (rdns) window.localStorage.setItem(REMEMBERED_KEY, rdns);
    else window.localStorage.removeItem(REMEMBERED_KEY);
  } catch {
    // storage unavailable: the wallet is connected for this page view alone
  }
}

/** The connected EVM wallet: which one, the account in use, and the chain it is on (null until the wallet has said). */
export type ConnectedEvmWallet = { wallet: AnnouncedWallet; address: string; chainId: number | null };

export type EvmWalletState = {
  /** The EVM wallets this browser announced (EIP-6963), in the order they did. */
  wallets: readonly AnnouncedWallet[];
  connected: ConnectedEvmWallet | null;
  connecting: boolean;
  connect: (wallet: AnnouncedWallet) => Promise<void>;
  /** Forgets the wallet here; EIP-1193 has no disconnect of its own, so the wallet keeps its own list of sites. */
  disconnect: () => void;
  /** The chain the wallet is on, asked now: what is checked right before every send and signature. */
  readChainId: () => Promise<number>;
  switchChain: (chain: WalletChain) => Promise<void>;
  sendTransaction: (tx: EvmTransaction) => Promise<string>;
  signTypedData: (typed: EvmTypedData) => Promise<string>;
  waitForReceipt: (hash: string) => Promise<EvmReceipt>;
  /** The connected wallet's own provider, for a read the calls above do not cover; null when none is connected. */
  provider: Eip1193Provider | null;
};

const EvmWalletContext = createContext<EvmWalletState | null>(null);

/** The EVM wallet beside the Solana one; null on a site that shows no EVM chain, where the provider is not mounted. */
export function useEvmWallet() {
  return useContext(EvmWalletContext);
}

/**
 * An EVM wallet beside the Solana one (#253), mounted only where the site shows an EVM chain. Wallets are found as they
 * announce themselves (EIP-6963, through mipd), so none is bundled; the one the visitor connects is remembered by its
 * name and comes back quietly on the next visit, asked for the accounts it already shows this site and nothing more.
 * The wallet says when its account or its chain changes, and the site follows.
 */
export function EvmWalletProvider({ children }: { children: ReactNode }) {
  const [wallets, setWallets] = useState<readonly AnnouncedWallet[]>([]);
  const [connected, setConnected] = useState<ConnectedEvmWallet | null>(null);
  const [connecting, setConnecting] = useState(false);
  /** Whether the quiet return to the remembered wallet has been tried, or made needless by a connection or a disconnect. */
  const returned = useRef(false);

  useEffect(() => {
    const store = createStore();
    const unsubscribe = store.subscribe(
      (details) => setWallets(details.map((d) => ({ uuid: d.info.uuid, name: d.info.name, icon: d.info.icon, rdns: d.info.rdns, provider: d.provider as Eip1193Provider }))),
      { emitImmediately: true },
    );
    return () => {
      unsubscribe();
      store.destroy();
    };
  }, []);

  // The remembered wallet, once it has announced itself: connected again if it still shows this site an account.
  useEffect(() => {
    if (returned.current) return;
    const rdns = remembered();
    if (!rdns) return void (returned.current = true);
    const wallet = wallets.find((w) => w.rdns === rdns);
    if (!wallet) return;
    // Tried once, and never undone by a cleanup: React's development double-mount would otherwise cancel the one try.
    returned.current = true;
    void (async () => {
      try {
        const [address] = await readAccounts(wallet.provider);
        if (!address) return;
        const chainId = await readChainId(wallet.provider).catch(() => null);
        // A wallet the visitor connected by hand meanwhile stays, and one they disconnected meanwhile stays away.
        if (remembered() === wallet.rdns) setConnected((current) => current ?? { wallet, address, chainId });
      } catch {
        // The wallet would not say: the visitor connects it again by hand.
      }
    })();
  }, [wallets]);

  const connect = useCallback(async (wallet: AnnouncedWallet) => {
    returned.current = true;
    setConnecting(true);
    try {
      const [address] = await requestAccounts(wallet.provider);
      if (!address) return;
      const chainId = await readChainId(wallet.provider).catch(() => null);
      remember(wallet.rdns);
      setConnected({ wallet, address, chainId });
    } catch (e) {
      // Declining in the wallet is the user's choice, not an error.
      if (!isRejection(e)) console.error(e);
    } finally {
      setConnecting(false);
    }
  }, []);

  const disconnect = useCallback(() => {
    returned.current = true;
    remember(null);
    setConnected(null);
  }, []);

  // The wallet says when its account or its chain changes; no account left means it was disconnected from its own side.
  const provider = connected?.wallet.provider ?? null;
  useEffect(() => {
    if (!provider?.on) return;
    const onAccounts = (accounts: string[]) => {
      const address = accounts[0];
      if (!address) {
        remember(null);
        return setConnected(null);
      }
      setConnected((current) => current && { ...current, address });
    };
    const onChain = (chainId: string) => setConnected((current) => current && { ...current, chainId: Number(BigInt(chainId)) });
    provider.on("accountsChanged", onAccounts);
    provider.on("chainChanged", onChain);
    return () => {
      provider.removeListener?.("accountsChanged", onAccounts);
      provider.removeListener?.("chainChanged", onChain);
    };
  }, [provider]);

  const state = useMemo<EvmWalletState>(() => {
    const needs = () => {
      if (!connected) throw new Error("Connect a wallet first.");
      return connected;
    };
    /** Reads the wallet's chain and keeps what the site shows in step with it, for a wallet that announces no change. */
    const chain = async () => {
      const { wallet } = needs();
      const chainId = await readChainId(wallet.provider);
      setConnected((current) => (current && current.wallet === wallet && current.chainId !== chainId ? { ...current, chainId } : current));
      return chainId;
    };
    return {
      wallets, connected, connecting, connect, disconnect, provider,
      readChainId: chain,
      switchChain: async (to) => {
        await switchChain(needs().wallet.provider, to);
        await chain();
      },
      sendTransaction: (tx) => sendTransaction(needs().wallet.provider, needs().address, tx),
      signTypedData: (typed) => signTypedData(needs().wallet.provider, needs().address, typed),
      waitForReceipt: (hash) => waitForReceipt(needs().wallet.provider, hash),
    };
  }, [wallets, connected, connecting, connect, disconnect, provider]);

  return <EvmWalletContext.Provider value={state}>{children}</EvmWalletContext.Provider>;
}
