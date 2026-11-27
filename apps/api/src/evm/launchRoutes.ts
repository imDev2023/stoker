import { Hono } from "hono";
import { EvmLaunchQuoteQuery, type EvmLaunchQuote } from "@launchpad/contract";
import { checksum, NATIVE } from "@launchpad/evm";
import type { AppEnv } from "../env";
import { evmContext } from "./context";
import { firstBuyOrRefuse, launchCost } from "./launch";
import { chainOptions, listedQuote } from "./options";

/**
 * Launching on an EVM chain (#253): what a chain offers a Launch, and what a First Buy would buy and the launch would
 * cost. The launch's own prepare is `POST /v1/launches/prepare` with `chain`, in `src/index.ts`, which hands an EVM
 * chain's form to `prepareEvmLaunch`; the report of a sent transaction is `POST /v1/transactions/:hash?chain=`, there too.
 */
export const evmLaunchRoutes = new Hono<AppEnv>();

/** Everything the chain offers a Launch, read from its contracts and kept for a few seconds (`chainOptions`). */
evmLaunchRoutes.get("/chains/:chain/launch-options", async (c) => {
  const x = evmContext(c, c.req.param("chain"));
  return c.json((await chainOptions(c.get("db"), x)).body);
});

/** An address above which most addresses are not: half of every address there is. */
const HALFWAY = 1n << 159n;

/**
 * What a First Buy would buy and what the launch would cost, as the form's choices stand.
 *
 * The coins a First Buy gets depend, in their last digits, on the order of the pool's two currencies, which is the
 * order of the Quote Asset's and the coin's addresses, and a coin has no address until its launch is prepared. The
 * native asset is always the lower, so its figure is exact here. For any other asset the figure is for the order its
 * address makes likelier, and the prepared launch's own figure, which is exact, can differ from it by the pool's
 * rounding: a few million raw units of 10^18 a coin, far less than any amount a wallet shows.
 */
evmLaunchRoutes.get("/chains/:chain/launch-quote", async (c) => {
  const x = evmContext(c, c.req.param("chain"));
  const query = EvmLaunchQuoteQuery.safeParse(c.req.query());
  if (!query.success) return c.json({ error: "invalid launch quote query", details: query.error.issues }, 400);
  const q = query.data;
  const db = c.get("db");
  const quote = checksum(q.quote.toLowerCase());
  const { settings } = await chainOptions(db, x);
  const listed = await listedQuote(db, x, quote);
  if (!listed) return c.json({ error: `That asset isn't a Quote Asset on ${x.config.profile.name}. Choose one from the list.` }, 400);
  const amount = q.firstBuy ? BigInt(q.firstBuy) : null;
  const bought =
    amount === null
      ? null
      : firstBuyOrRefuse(listed, settings, { amountIn: amount, taxBps: q.taxBps, lockBps: q.lockBps, quoteIsCurrency0: quote === NATIVE || BigInt(quote) < HALFWAY });
  const cost = await launchCost(x, settings, { quote, creator: q.creator ? checksum(q.creator.toLowerCase()) : undefined, firstBuy: amount, taxBps: q.taxBps, lockBps: q.lockBps });
  const body: EvmLaunchQuote = {
    chain: x.config.chain,
    quote: listed.option,
    firstBuy: bought && { amountIn: bought.amountIn.toString(), coinsOut: bought.coinsOut.toString(), fees: { platform: bought.platformFee.toString(), tax: bought.tax.toString() } },
    cost,
  };
  return c.json(body);
});
