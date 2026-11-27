"use client";

import { useCallback, useRef, useState } from "react";
import type { Chain, EvmChain, EvmLaunchOptions, PlatformInfo, QuoteAsset } from "@launchpad/contract";
import { CHAIN_NAMES, isEvm } from "@/lib/chains";
import { EmptyState } from "./EmptyState";
import { EvmLaunchForm } from "./EvmLaunchForm";
import type { LaunchDraft } from "./LaunchFields";
import { LaunchForm } from "./LaunchForm";
import { OptionRow } from "./OptionRow";
import form from "./LaunchForm.module.css";
import rows from "./LaunchOptions.module.css";

/**
 * The launch page where the site shows more than Solana (#253): the form starts with the chain, Solana first, and every
 * later section is that chain's own form, the Solana one or an EVM chain's, each showing only what its chain offers. A
 * chain is named in plain text, in full. What the Creator has typed about the coin itself (its name, ticker, image,
 * description and links) is carried from one chain's form to the other's; the choices a chain offers are its own.
 * With one chain shown there is no chain section. `evmOptions` holds each EVM chain's launch options as the API read
 * them from its contracts, null for a chain it could not read, which is then listed and cannot be chosen.
 */
export function LaunchChains({
  platform, quotes, chains, evmOptions, initialQuote = null, initialName = "", initialSymbol = "",
}: {
  platform: PlatformInfo;
  quotes: QuoteAsset[];
  chains: readonly Chain[];
  evmOptions: Partial<Record<EvmChain, EvmLaunchOptions | null>>;
  initialQuote?: string | null;
  initialName?: string;
  initialSymbol?: string;
}) {
  const optionsOf = (chain: Chain) => (isEvm(chain) ? (evmOptions[chain] ?? null) : null);
  const offered = (chain: Chain) => !isEvm(chain) || optionsOf(chain) !== null;
  const [chain, setChain] = useState<Chain>(() => chains.find(offered) ?? chains[0] ?? "solana");
  // The coin's own fields as the form shown last had them, for the form shown next.
  const draft = useRef<LaunchDraft | null>(null);
  const onDraft = useCallback((next: LaunchDraft) => {
    draft.current = next;
  }, []);
  const nameOf = (c: Chain) => optionsOf(c)?.name ?? CHAIN_NAMES[c];

  const chainSection = chains.length > 1 ? (
    <section className={form.set} aria-labelledby="block-chain">
      <h2 id="block-chain" className={`t-h3 ${form.legend}`}>Chain</h2>
      <div className={rows.types} role="radiogroup" aria-labelledby="block-chain">
        {chains.map((c) => (
          <OptionRow key={c} name="launch-chain" value={c} checked={c === chain} disabled={!offered(c)} onChange={() => setChain(c)}>
            <span>{offered(c) ? <b>{nameOf(c)}</b> : `${nameOf(c)} can't be read just now. Try again in a moment.`}</span>
          </OptionRow>
        ))}
      </div>
    </section>
  ) : undefined;

  const options = optionsOf(chain);
  if (options)
    return <EvmLaunchForm key={chain} options={options} platform={platform} initialName={initialName} initialSymbol={initialSymbol} chainSection={chainSection} draft={draft.current} onDraft={onDraft} />;
  if (isEvm(chain))
    return (
      <div className={`shell ${form.page}`}>
        <EmptyState title={`${nameOf(chain)} can't be read just now`}>Its launch options did not load, so nothing can launch there for the moment. Reload the page to try again.</EmptyState>
      </div>
    );
  return (
    <LaunchForm
      key={chain} platform={platform} quotes={quotes} initialQuote={initialQuote} initialName={initialName} initialSymbol={initialSymbol}
      chainSection={chainSection} draft={draft.current} onDraft={onDraft}
    />
  );
}
