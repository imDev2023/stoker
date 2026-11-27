"use client";

import Link from "next/link";
import { useWallet } from "@solana/wallet-adapter-react";
import { WalletReadyState } from "@solana/wallet-adapter-base";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { listLaunches } from "@/lib/api";
import { CHAIN_NAMES, evmChainsOf } from "@/lib/chains";
import { shortAddress } from "@/lib/format";
import { useChains } from "./ChainsProvider";
import { useEvmWallet, type EvmWalletState } from "./EvmWalletProvider";
import { SchemeToggle } from "./SchemeToggle";
import styles from "./WalletButton.module.css";

/** The wallet's glyph: a card with its clasp. */
function Glyph() {
  return (
    <svg className={styles.glyph} viewBox="0 0 20 20" width="18" height="18" aria-hidden="true">
      <path
        d="M3 6.5A2.5 2.5 0 0 1 5.5 4h9A1.5 1.5 0 0 1 16 5.5V6h-1V5.5a.5.5 0 0 0-.5-.5h-9A1.5 1.5 0 0 0 4 6.5v7A1.5 1.5 0 0 0 5.5 15h9a.5.5 0 0 0 .5-.5V13h1v1.5a1.5 1.5 0 0 1-1.5 1.5h-9A2.5 2.5 0 0 1 3 13.5v-7Z"
        fill="currentColor"
      />
      <path d="M11 8h5.5a.5.5 0 0 1 .5.5v3a.5.5 0 0 1-.5.5H11a2 2 0 1 1 0-4Zm0 1.25a.75.75 0 1 0 0 1.5.75.75 0 0 0 0-1.5Z" fill="currentColor" />
    </svg>
  );
}

/**
 * A connected wallet's avatar: a disc whose two hues come from the address, so the same wallet looks the same on every
 * visit and two wallets look different, with nothing fetched and nothing stored.
 */
export function Avatar({ address, size = 24 }: { address: string; size?: number }) {
  let a = 0;
  let b = 0;
  for (let i = 0; i < address.length; i++) {
    const c = address.charCodeAt(i);
    if (i % 2 === 0) a = (a * 31 + c) % 360;
    else b = (b * 37 + c) % 360;
  }
  const style = { width: size, height: size, background: `linear-gradient(135deg, hsl(${a} 70% 56%), hsl(${(a + 40 + (b % 80)) % 360} 72% 38%))` };
  return <span className={styles.avatar} style={style} data-avatar aria-hidden="true" />;
}

type Variant = "header" | "inline" | "block" | "menu";

const wrapOf = (variant: Variant) => `${styles.wrap} ${variant === "header" ? styles.header : variant === "inline" ? styles.inline : variant === "block" ? styles.block : styles.inMenu}`;
// Inline the connection is the page's action; in the header and the phone menu it is a ghost beside the filled one.
const connectKindOf = (variant: Variant) => (variant === "inline" ? "button-primary" : variant === "block" ? "button-primary button-lg" : "button-ghost");

/** A menu that closes as menus do: on Escape, or a press anywhere outside it and its button. */
function useMenu() {
  const [open, setOpen] = useState(false);
  const menu = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent | KeyboardEvent) => {
      if (e instanceof KeyboardEvent ? e.key === "Escape" : !menu.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", close);
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("mousedown", close);
      document.removeEventListener("keydown", close);
    };
  }, [open]);
  return { open, setOpen, menu };
}

/**
 * The Solana wallet as the control needs it: the installed wallets, the connected address, and a connect that stages the
 * wallet first. The earnings page is a Creator's own (owner, 2026-10-08): the menu offers it only to a wallet that has
 * launched a coin here, which is asked once per connected wallet.
 */
function useSolanaAccount() {
  const { wallets, wallet, publicKey, connecting, select, connect, disconnect } = useWallet();
  const chains = useChains();
  const [pending, setPending] = useState<string | null>(null);
  const installed = wallets.filter((w) => w.readyState === WalletReadyState.Installed || w.readyState === WalletReadyState.Loadable);

  const address = publicKey?.toBase58() ?? null;
  const [launched, setLaunched] = useState<{ address: string; yes: boolean } | null>(null);
  useEffect(() => {
    if (!address) return;
    let gone = false;
    listLaunches({ chains, creator: address, limit: 1 })
      .then((list) => {
        if (!gone) setLaunched({ address, yes: list.launches.length > 0 });
      })
      .catch(() => undefined);
    return () => {
      gone = true;
    };
  }, [address, chains]);
  const hasLaunched = launched?.address === address && launched.yes;

  // Selecting a wallet only stages it; connect once the adapter has switched.
  useEffect(() => {
    if (pending && wallet?.adapter.name === pending && !publicKey) {
      setPending(null);
      connect().catch(() => undefined);
    }
  }, [pending, wallet, publicKey, connect]);

  return {
    installed, wallet, address, connecting, hasLaunched, disconnect,
    choose: (name: (typeof installed)[number]["adapter"]["name"]) => {
      setPending(name);
      select(name);
    },
  };
}

/** The Solana wallets this browser has, as the menu's rows, or where to get one. */
function SolanaWallets({ account, onChosen }: { account: ReturnType<typeof useSolanaAccount>; onChosen: () => void }) {
  if (account.installed.length === 0)
    return (
      <p className={styles.empty}>
        No Solana wallet found in this browser. Install{" "}
        <a href="https://phantom.com" target="_blank" rel="noreferrer">Phantom</a> or{" "}
        <a href="https://solflare.com" target="_blank" rel="noreferrer">Solflare</a>, then reload.
      </p>
    );
  return (
    <>
      {account.installed.map((w) => (
        <button key={w.adapter.name} type="button" role="menuitem" onClick={() => { onChosen(); account.choose(w.adapter.name); }}>
          <img src={w.adapter.icon} alt="" width={20} height={20} />
          {w.adapter.name}
        </button>
      ))}
    </>
  );
}

/** The EVM wallets this browser announced, as the menu's rows, or where to get one. */
function EvmWallets({ evm, onChosen }: { evm: EvmWalletState; onChosen: () => void }) {
  if (evm.wallets.length === 0)
    return (
      <p className={styles.empty}>
        No EVM wallet found in this browser. Install{" "}
        <a href="https://metamask.io" target="_blank" rel="noreferrer">MetaMask</a> or{" "}
        <a href="https://rabby.io" target="_blank" rel="noreferrer">Rabby</a>, then reload.
      </p>
    );
  return (
    <>
      {evm.wallets.map((w) => (
        <button key={w.uuid} type="button" role="menuitem" onClick={() => { onChosen(); void evm.connect(w); }}>
          <img src={w.icon} alt="" width={20} height={20} />
          {w.name}
        </button>
      ))}
    </>
  );
}

/** The "Connect wallet" button every variant starts as. */
function ConnectButton({ variant, open, connecting, onClick }: { variant: Variant; open: boolean; connecting: boolean; onClick: () => void }) {
  return (
    <button type="button" className={`button ${connectKindOf(variant)} ${styles.connect}`} onClick={onClick} aria-expanded={open} disabled={connecting} data-wallet-connect={variant === "header" || undefined}>
      {/* On a phone the header's button is the glyph alone; the words stay as its name. */}
      {variant === "header" && <span className={styles.connectGlyph}><Glyph /></span>}
      <span className={styles.connectWord}>{connecting ? "Connecting…" : "Connect wallet"}</span>
    </button>
  );
}

/**
 * The account control. In the header it is the ghost beside the one filled action (`header`): "Connect wallet", or
 * the wallet's avatar and short address once connected, each opening a menu that also holds the light-or-dark toggle
 * (the toggle left the bar in #131; a preference used once lives in the account menu). `inline` sits inside page
 * content as the action itself; `block` is that action at the full width and the large size (the launch summary's);
 * `menu` fills the phone menu's foot as a ghost under the launch button.
 *
 * Where the site shows an EVM chain (#253) the header's and the phone's control hold an EVM wallet beside the Solana
 * one: each chain family under its own name in plain text, connected and disconnected on its own. A page's own action
 * (`inline`, `block`) connects the wallet that page needs: Solana's unless `family` says the EVM one, on a coin or a
 * launch of an EVM chain.
 */
export function WalletButton({ variant = "header", family }: { variant?: Variant; family?: "solana" | "evm" }) {
  const evm = useEvmWallet();
  if (evm && family === "evm") return <EvmWalletButton variant={variant} evm={evm} />;
  if (evm && !family && (variant === "header" || variant === "menu")) return <AccountControl variant={variant} evm={evm} />;
  return <SolanaWalletButton variant={variant} />;
}

/** The control for the Solana wallet alone: all there is on a site that shows no EVM chain. */
function SolanaWalletButton({ variant }: { variant: Variant }) {
  const account = useSolanaAccount();
  const { open, setOpen, menu } = useMenu();
  const wrap = wrapOf(variant);
  // The toggle rides in the header's menus only: the phone menu shows it in its own foot.
  const toggle = variant === "header" && (
    <div className={styles.foot}>
      <SchemeToggle variant="menu" />
    </div>
  );

  if (account.address) {
    return (
      <div className={wrap} ref={menu}>
        <button
          type="button"
          className={`button button-ghost ${styles.connected}`}
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          title={account.wallet ? `Connected with ${account.wallet.adapter.name}` : undefined}
        >
          <Avatar address={account.address} />
          <span className={`mono ${styles.address}`}>{shortAddress(account.address)}</span>
        </button>
        {open && (
          <div className={styles.menu} role="menu" aria-label={account.wallet ? `Connected with ${account.wallet.adapter.name}` : "Wallet"}>
            {account.hasLaunched && (
              <Link href="/creator" role="menuitem" className={styles.menuLink} onClick={() => setOpen(false)}>
                Your earnings
              </Link>
            )}
            <button type="button" role="menuitem" onClick={() => { setOpen(false); void account.disconnect(); }}>
              Disconnect
            </button>
            {toggle}
          </div>
        )}
      </div>
    );
  }

  return (
    <div className={wrap} ref={menu}>
      <ConnectButton variant={variant} open={open} connecting={account.connecting} onClick={() => setOpen((o) => !o)} />
      {open && (
        <div className={styles.menu} role="menu" aria-label="Choose a wallet">
          <SolanaWallets account={account} onChosen={() => setOpen(false)} />
          {toggle}
        </div>
      )}
    </div>
  );
}

/** One chain family's part of the account menu: its name in plain text, then its wallet or the wallets to choose from. */
function Group({ name, children }: { name: string; children: ReactNode }) {
  return (
    <div className={styles.group} role="group" aria-label={name}>
      <p className={styles.heading}>{name}</p>
      {children}
    </div>
  );
}

/** A connected wallet inside the menu: its avatar and short address, as the header's button writes them. */
function Account({ address, title }: { address: string; title: string }) {
  return (
    <p className={styles.account} title={title}>
      <Avatar address={address} size={20} />
      <span className="mono">{shortAddress(address)}</span>
    </p>
  );
}

/**
 * The header's and the phone's control where the site shows an EVM chain: one button, one menu, and in it Solana and the
 * EVM chains each under their own name, with the wallet connected there or the wallets to connect. The button wears the
 * avatar and address of the one wallet connected, and counts them when both are.
 */
function AccountControl({ variant, evm }: { variant: Variant; evm: EvmWalletState }) {
  const solana = useSolanaAccount();
  const chains = useChains();
  const { open, setOpen, menu } = useMenu();
  const evmName = evmChainsOf(chains).map((chain) => CHAIN_NAMES[chain]).join(", ");
  const evmAddress = evm.connected?.address ?? null;
  const shown = solana.address ?? evmAddress;
  const both = solana.address !== null && evmAddress !== null;

  return (
    <div className={wrapOf(variant)} ref={menu}>
      {shown ? (
        <button type="button" className={`button button-ghost ${styles.connected}`} onClick={() => setOpen((o) => !o)} aria-expanded={open}>
          <Avatar address={shown} />
          {both ? <span className={styles.address}>2 wallets</span> : <span className={`mono ${styles.address}`}>{shortAddress(shown)}</span>}
        </button>
      ) : (
        <ConnectButton variant={variant} open={open} connecting={solana.connecting || evm.connecting} onClick={() => setOpen((o) => !o)} />
      )}
      {open && (
        <div className={`${styles.menu} ${styles.families}`} role="menu" aria-label="Wallets">
          <Group name={CHAIN_NAMES.solana}>
            {solana.address ? (
              <>
                <Account address={solana.address} title={solana.wallet ? `Connected with ${solana.wallet.adapter.name}` : solana.address} />
                {solana.hasLaunched && (
                  <Link href="/creator" role="menuitem" className={styles.menuLink} onClick={() => setOpen(false)}>
                    Your earnings
                  </Link>
                )}
                <button type="button" role="menuitem" aria-label={`Disconnect the ${CHAIN_NAMES.solana} wallet`} onClick={() => { setOpen(false); void solana.disconnect(); }}>
                  Disconnect
                </button>
              </>
            ) : (
              <SolanaWallets account={solana} onChosen={() => setOpen(false)} />
            )}
          </Group>
          <Group name={evmName}>
            {evm.connected ? (
              <>
                <Account address={evm.connected.address} title={`Connected with ${evm.connected.wallet.name}`} />
                <button type="button" role="menuitem" aria-label={`Disconnect the ${evmName} wallet`} onClick={() => { setOpen(false); evm.disconnect(); }}>
                  Disconnect
                </button>
              </>
            ) : (
              <EvmWallets evm={evm} onChosen={() => setOpen(false)} />
            )}
          </Group>
          {/* The toggle rides in the header's menus only: the phone menu shows it in its own foot. */}
          {variant === "header" && (
            <div className={styles.foot}>
              <SchemeToggle variant="menu" />
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** A page's own action on a coin or a launch of an EVM chain: connect an EVM wallet, the one that page needs. */
function EvmWalletButton({ variant, evm }: { variant: Variant; evm: EvmWalletState }) {
  const { open, setOpen, menu } = useMenu();
  if (evm.connected) {
    return (
      <div className={wrapOf(variant)} ref={menu}>
        <button type="button" className={`button button-ghost ${styles.connected}`} onClick={() => setOpen((o) => !o)} aria-expanded={open} title={`Connected with ${evm.connected.wallet.name}`}>
          <Avatar address={evm.connected.address} />
          <span className={`mono ${styles.address}`}>{shortAddress(evm.connected.address)}</span>
        </button>
        {open && (
          <div className={styles.menu} role="menu" aria-label={`Connected with ${evm.connected.wallet.name}`}>
            <button type="button" role="menuitem" onClick={() => { setOpen(false); evm.disconnect(); }}>
              Disconnect
            </button>
          </div>
        )}
      </div>
    );
  }
  return (
    <div className={wrapOf(variant)} ref={menu}>
      <ConnectButton variant={variant} open={open} connecting={evm.connecting} onClick={() => setOpen((o) => !o)} />
      {open && (
        <div className={styles.menu} role="menu" aria-label="Choose a wallet">
          <EvmWallets evm={evm} onChosen={() => setOpen(false)} />
        </div>
      )}
    </div>
  );
}
