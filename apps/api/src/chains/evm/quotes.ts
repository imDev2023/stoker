import type { Chain, QuoteRef } from "@launchpad/contract";
import type { evmQuoteAssets } from "@launchpad/db";

/** An EVM chain's Quote Asset as every coin carries it (#252): raw amounts, with a Stock Token's multiplier in force beside them. */
export function evmQuoteRef(r: typeof evmQuoteAssets.$inferSelect): QuoteRef {
  return {
    chain: r.chain as Chain,
    mint: r.address,
    symbol: r.symbol,
    name: r.name,
    decimals: r.decimals,
    logo: null,
    category: r.category,
    issuer: null,
    multiplier: r.multiplier,
  };
}
