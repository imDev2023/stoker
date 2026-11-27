"use client";

import { ConnectionProvider, WalletProvider } from "@solana/wallet-adapter-react";
import type { WalletError } from "@solana/wallet-adapter-base";
import type { ReactNode } from "react";
import type { Chain } from "@launchpad/contract";
import { evmChainsOf } from "@/lib/chains";
import { ChainsProvider } from "./ChainsProvider";
import { EvmWalletProvider } from "./EvmWalletProvider";
import { RegionProvider } from "./RegionGate";

/** Declining in the wallet is the user's choice, not an error; the component that asked shows what happened. */
function onWalletError(error: WalletError) {
  if (!/reject|declin|cancel/i.test(error.message)) console.error(error);
}

/**
 * Wallets are discovered through the Wallet Standard, so no wallet-specific adapters are bundled. `chains` is what this
 * visitor is shown (src/lib/chains.ts): every client component reads it from here, and an EVM wallet is looked for
 * beside the Solana one only where an EVM chain is among them.
 */
export function Providers({ rpcUrl, chains, children }: { rpcUrl: string; chains: readonly Chain[]; children: ReactNode }) {
  const tree = <RegionProvider>{children}</RegionProvider>;
  return (
    <ChainsProvider chains={chains}>
      <ConnectionProvider endpoint={rpcUrl} config={{ commitment: "confirmed" }}>
        <WalletProvider wallets={[]} autoConnect onError={onWalletError}>
          {evmChainsOf(chains).length > 0 ? <EvmWalletProvider>{tree}</EvmWalletProvider> : tree}
        </WalletProvider>
      </ConnectionProvider>
    </ChainsProvider>
  );
}
