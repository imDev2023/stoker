import { z } from "zod";

/**
 * The chains Stoker runs on (#231, #252): Solana, and each EVM chain of the EVM chain family, Robinhood Chain first.
 * Every coin, trade, round, Ledger entry and holder list carries its chain, and every list endpoint takes one as a
 * filter (`?chain=`), so one client covers all of Stoker (story 43). A chain is a network's family member, never the
 * cluster: Solana's devnet rehearsal is `solana` too, and the deployment says which network it reads (`GET /v1/platform`).
 */
export const CHAINS = ["solana", "robinhood"] as const;
export const Chain = z.enum(CHAINS);
export type Chain = z.infer<typeof Chain>;

/** Solana, or the EVM chains taken together. */
export const ChainFamily = z.enum(["solana", "evm"]);
export type ChainFamily = z.infer<typeof ChainFamily>;

export const familyOf = (chain: Chain): ChainFamily => (chain === "solana" ? "solana" : "evm");

const base58 = /^[1-9A-HJ-NP-Za-km-z]{32,44}$/;
const evmAddress = /^0x[0-9a-fA-F]{40}$/;
/** An address on any chain: base58 on Solana, `0x` and 40 hex digits (checksummed when the API answers) on an EVM chain. */
export const ChainAddress = z.string().refine((s) => base58.test(s) || evmAddress.test(s), "must be a Solana or an EVM address");
/**
 * Where a coin trades: on Solana its curve's or its pool's address, on an EVM chain its Uniswap v4 pool's id (`0x` and
 * 64 hex digits), which is what v4 names a pool by.
 */
export const PoolRef = z.string().refine((s) => base58.test(s) || /^0x[0-9a-fA-F]{64}$/.test(s), "must be a Solana address or a v4 pool id");

/** The chain filter every list endpoint takes: only that chain's items; absent, every chain's. An unknown chain is a 400. */
export const ChainFilter = z.object({ chain: Chain.optional() });
export type ChainFilter = z.infer<typeof ChainFilter>;

/**
 * How far one chain's Indexer is behind the chain's head (story 50): the head it last saw, the newest block (a slot on
 * Solana) whose events it has written, and the distance between them. On an EVM chain the Indexer reads our contracts'
 * events up to the chain's finality depth on every run, so the gap is how far it has to go. Solana's Indexer is pushed
 * each transaction by Helius's webhook (and the site's fast path), so its newest indexed slot is that of the newest
 * transaction of ours, and on a quiet platform the gap also grows while nothing is wrong.
 */
export const ChainIndexer = z.object({
  /** `poll` reads the chain on a schedule (an EVM chain); `push` is delivered each transaction (Solana). */
  mode: z.enum(["poll", "push"]),
  head: z.object({ block: z.number().int(), time: z.iso.datetime().nullable() }).nullable(),
  indexed: z.object({ block: z.number().int(), time: z.iso.datetime().nullable() }).nullable(),
  /** Blocks (slots on Solana) between the head and the newest indexed one; null until both are known. */
  blocksBehind: z.number().int().nullable(),
  /** Seconds between the head's time and the newest indexed block's; null until both are known. */
  secondsBehind: z.number().nullable(),
  /** How many blocks behind the head the Indexer stops on purpose: the chain's finality depth (0 on Solana's `confirmed`). */
  finalityDepth: z.number().int(),
  /** When the head was read; null if it never has been. */
  checkedAt: z.iso.datetime().nullable(),
});
export type ChainIndexer = z.infer<typeof ChainIndexer>;

/** One chain this deployment of the API reads. */
export const ChainInfo = z.object({
  chain: Chain,
  family: ChainFamily,
  /** What the site calls it, in plain text. */
  name: z.string(),
  /** An EVM chain's id; null on Solana. */
  chainId: z.number().int().nullable(),
  /** The chain's block explorer. */
  explorer: z.string(),
  indexer: ChainIndexer,
});
export type ChainInfo = z.infer<typeof ChainInfo>;

export const ChainList = z.object({ chains: z.array(ChainInfo) });
export type ChainList = z.infer<typeof ChainList>;
