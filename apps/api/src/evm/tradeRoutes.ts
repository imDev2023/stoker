import { Hono } from "hono";
import type { Address } from "viem";
import { EvmAddress, type EvmWalletBalances } from "@launchpad/contract";
import { checksum, NATIVE } from "@launchpad/evm";
import type { AppEnv } from "../env";
import { evmContext, reading } from "./context";
import { balanceRead, nativeBalanceRead, readTogether, type Read } from "./tradeReads";

/**
 * Trading on an EVM chain (#253): a wallet's balances. A coin's quote and a trade's prepare are the existing paths
 * (`GET /v1/launches/:coin/quote`, `POST /v1/trades/prepare`) in `src/routes/trades.ts`, which hand an EVM coin to this
 * folder's `quoteEvmTrade` and `prepareEvmTrade`.
 */
export const evmTradeRoutes = new Hono<AppEnv>();

/** The most ERC-20s one request reads: a trade panel shows a coin and its Quote Asset, a wallet's page a few more. */
const MAX_ASSETS = 8;

/**
 * What a wallet holds on an EVM chain: its native asset and each ERC-20 named in `assets`, read in one `eth_call` so
 * they are of one block, and never kept. `block` is the chain's own number (the opcode's is the parent chain's here),
 * asked for before the balances, so the balances are never older than it: a client that has a transaction's block asks
 * again until `block` reaches it and then holds figures that include the transaction.
 */
evmTradeRoutes.get("/chains/:chain/wallets/:address", async (c) => {
  const x = evmContext(c, c.req.param("chain"));
  const wallet = EvmAddress.safeParse(c.req.param("address"));
  if (!wallet.success) return c.json({ error: "invalid wallet address" }, 400);
  const named = (c.req.query("assets") ?? "").split(",").map((a) => a.trim()).filter((a) => a !== "");
  const unreadable = named.find((a) => !EvmAddress.safeParse(a).success);
  if (unreadable !== undefined) return c.json({ error: `"${unreadable}" isn't an asset's address` }, 400);
  const assets = [...new Set(named.map((a) => checksum(a.toLowerCase())))];
  if (assets.length > MAX_ASSETS) return c.json({ error: `at most ${MAX_ASSETS} assets can be read at once` }, 400);
  const who = checksum(wallet.data.toLowerCase());

  const { block, read } = await reading(x, async () => {
    // viem keeps a block number for seconds unless told not to.
    const block = await x.client.getBlockNumber({ cacheTime: 0 });
    // The native asset named among the assets (the zero address, as a Quote Asset names it) is the native balance.
    const reads: Record<string, Read<bigint>> = { native: nativeBalanceRead(x, who) };
    assets.forEach((asset, i) => (reads[`asset${i}`] = asset === NATIVE ? nativeBalanceRead(x, who) : balanceRead(asset, who)));
    return { block, read: await readTogether(x, reads) };
  });
  const balanceOf = (name: string, asset: Address | null) => {
    const answer = read[name]!;
    if (!answer.ok) throw new Error(`the balance of ${asset ?? "the native asset"} could not be read`);
    return answer.value.toString();
  };
  const failed = assets.find((_, i) => !read[`asset${i}`]!.ok);
  if (failed !== undefined) return c.json({ error: `${failed} isn't an asset whose balance can be read on ${x.config.profile.name}` }, 400);
  const res: EvmWalletBalances = {
    chain: x.config.chain,
    wallet: who,
    block: Number(block),
    native: balanceOf("native", null),
    assets: assets.map((address, i) => ({ address, balance: balanceOf(`asset${i}`, address) })),
  };
  c.header("cache-control", "no-store");
  return c.json(res);
});
