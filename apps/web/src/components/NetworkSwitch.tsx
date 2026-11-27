"use client";

import { useState } from "react";
import { isRejection, type WalletChain } from "@/lib/evmWallet";
import { useEvmWallet } from "./EvmWalletProvider";
import styles from "./NetworkSwitch.module.css";

/** Whether the connected EVM wallet is known to be on another chain than `chainId`; false while its chain is not known. */
export function onAnotherNetwork(connected: { chainId: number | null } | null | undefined, chainId: number) {
  return Boolean(connected && connected.chainId !== null && connected.chainId !== chainId);
}

/**
 * The one action while an EVM wallet is on another network than the coin's or the launch's (#253): a sentence that says
 * so, and "Switch to [chain]", which asks the wallet to switch and, for a wallet that has never met the chain, to add
 * it first. It stands where the sign button would: nothing can be signed until the wallet is on the right chain.
 */
export function NetworkSwitch({ name, chain, size = "lg" }: {
  /** The chain's name, in full, as its launch options give it. */
  name: string;
  chain: WalletChain;
  size?: "lg" | "md";
}) {
  const evm = useEvmWallet();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function change() {
    if (!evm) return;
    setError(null);
    setBusy(true);
    try {
      await evm.switchChain(chain);
    } catch (e) {
      // Declining in the wallet is the user's choice: the action stays as it was.
      if (!isRejection(e)) setError(`Your wallet could not switch to ${name}. Switch it there, then come back.`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className={styles.box} role="group" aria-label="Network">
      {error && <p className={styles.error} role="alert">{error}</p>}
      <p>{`Your wallet is on another network. Switch it to ${name} to go on.`}</p>
      <button type="button" className={`button button-primary ${size === "lg" ? "button-lg" : ""} ${styles.primary}`} onClick={() => void change()} disabled={busy} aria-busy={busy || undefined}>
        {busy ? "Switching…" : `Switch to ${name}`}
      </button>
    </div>
  );
}
