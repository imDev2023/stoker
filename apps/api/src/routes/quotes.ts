import { Hono } from "hono";
import { chainFilter, chainIs } from "../chains/filter";
import { eq } from "drizzle-orm";
import type { QuoteAssetList } from "@launchpad/contract";
import { quoteAssets } from "@launchpad/db";
import type { AppEnv } from "../env";
import { byPickerOrder, toQuoteAsset } from "../quotes/assets";

/** The Quote Registry, read side: every Quote Asset with its price, Graduation Target and whether it can be launched against. */
export const quotes = new Hono<AppEnv>();

quotes.get("/quotes", async (c) => {
  // Solana's Quote Registry; an EVM chain's Listings are on-chain and come here with its jobs (#254), so `?chain=` of an
  // EVM chain answers an empty list until then.
  const rows = await c.get("db").select().from(quoteAssets).where(chainIs(quoteAssets.chain, chainFilter(c)));
  const body: QuoteAssetList = { quotes: rows.map((r) => toQuoteAsset(c.get("cfg"), r)).sort(byPickerOrder) };
  return c.json(body);
});

quotes.get("/quotes/:mint", async (c) => {
  const [row] = await c.get("db").select().from(quoteAssets).where(eq(quoteAssets.mint, c.req.param("mint"))).limit(1);
  if (!row) return c.json({ error: "quote asset not found" }, 404);
  return c.json(toQuoteAsset(c.get("cfg"), row));
});
