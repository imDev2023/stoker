import { CHAINS, familyOf, type Chain, type EvmChain } from "@launchpad/contract";

/**
 * The chains this site shows (#253). `NEXT_PUBLIC_CHAINS` is the comma list every visitor sees, Solana alone when it is
 * unset; `NEXT_PUBLIC_PREVIEW_CHAINS` names chains shown only to a browser that carries the preview cookie, which
 * `?chains=preview` on any page sets and `?chains=live` clears (components/ChainsProvider.tsx). That is how a chain is
 * tried on a real deployment before everyone sees it. Every list the site asks the API for names these chains, so a
 * chain the API has begun to read never appears on a site that is not ready for it. A plain module, not a client one:
 * a server component importing a constant from a client module gets a reference in place of the value.
 */
export const CHAINS_COOKIE = "stoker.chains";
export const CHAINS_PARAM = "chains";
export const CHAINS_PREVIEW = "preview";
export const CHAINS_LIVE = "live";

/** A comma list's known chains, each once, in the contract's own order (Solana first). */
function listed(value: string | undefined): Chain[] {
  const named = new Set((value ?? "").split(",").map((part) => part.trim()));
  return CHAINS.filter((chain) => named.has(chain));
}

const configured = listed(process.env.NEXT_PUBLIC_CHAINS);

/** What every visitor sees, and what anything rendered without a visitor's cookie shows (the sitemap, a share image). */
export const PUBLIC_CHAINS: readonly Chain[] = configured.length > 0 ? configured : ["solana"];

/** What the preview cookie adds. */
export const PREVIEW_CHAINS: readonly Chain[] = listed(process.env.NEXT_PUBLIC_PREVIEW_CHAINS).filter((chain) => !PUBLIC_CHAINS.includes(chain));

/** The chains a visitor is shown, from their preview cookie's value. */
export function chainsShown(cookie: string | undefined): readonly Chain[] {
  if (cookie !== CHAINS_PREVIEW || PREVIEW_CHAINS.length === 0) return PUBLIC_CHAINS;
  return CHAINS.filter((chain) => PUBLIC_CHAINS.includes(chain) || PREVIEW_CHAINS.includes(chain));
}

/** What the site calls each chain, in plain text and in full: never a logo, a badge, an icon or a short form (ADR 0028, #253). */
export const CHAIN_NAMES: Record<Chain, string> = { solana: "Solana", robinhood: "Robinhood Chain" };

export const isEvm = (chain: Chain): chain is EvmChain => familyOf(chain) === "evm";

/** The EVM chains among those shown. */
export const evmChainsOf = (chains: readonly Chain[]): EvmChain[] => chains.filter(isEvm);

/**
 * What a chain calls one of its tokenized stocks, where it has a name of its own (ADR 0028): on Robinhood Chain a Stock
 * Token, and never anything else. A list's cards and tags read it from here by the asset's chain; a page that has the
 * chain's launch options says the chain's own `stockName`.
 */
export const STOCK_KIND: Partial<Record<Chain, string>> = { robinhood: "Stock Token" };
