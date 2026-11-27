import { getAddress, type Address } from "viem";

/**
 * Each EVM chain's profile (PRD #231, "Modules"): the facts the server needs about a chain that are the same for every
 * deployment of our contracts on it. A deployment's own addresses (the factory, the hook, the registry, the keys) are
 * not here: each API is given them (`EvmDeployment`), so the test stack's fork and a real chain use one profile.
 */
export type EvmChainProfile = {
  /** The API's name for the chain, as `Chain` in @launchpad/contract has it. */
  chain: "robinhood";
  /** What the site calls it, in plain text (ADR 0028: Robinhood Chain is named in words only). */
  name: string;
  chainId: number;
  /**
   * How many blocks behind the head the Indexer stops: what it reads is never deeper in the unconfirmed part of the
   * chain than this. Robinhood Chain is an Arbitrum Orbit chain whose sequencer confirms a block as it makes it (0.1 s);
   * it is reorganized only if the sequencer misbehaves before posting to Ethereum, the issuer treats one block's
   * confirmation as a legal transfer, and Solana's Indexer reads `confirmed` too, so trades show as the sequencer
   * confirms them (the knowledge base's `14-transaction-finality.md`), 25 blocks back, about two and a half seconds:
   * behind a load balancer the node that answers a `getLogs` may be behind the one that gave the head, and it answers
   * a range it has only part of with what it has and no error (#279; 5 blocks was half a second).
   * A job that pays (#254) waits for `safe` instead.
   */
  finalityDepth: number;
  /**
   * How many of the blocks it read last each run reads again (#279): a node that was further behind than the finality
   * depth gave a short answer, and the next run, a minute later, finds what it left out. Every write is idempotent.
   */
  rereadBlocks: number;
  /**
   * The widest block range one `eth_getLogs` asks for unless the deployment sets its own: 10, what Alchemy's free tier
   * accepts (it answers -32600 past that). The setting is a ceiling: a run halves the range when a provider refuses
   * one, and it grows back toward the setting after ranges read cleanly.
   */
  logBlockRange: number;
  /**
   * `block.number` on this chain is an estimate of the parent chain's block, so time and the chain's own block numbers
   * are read through the RPC (a block's `timestamp` and `number`), never from the opcode (the knowledge base's
   * `44-uniswap-v4-hooks.md`).
   */
  blockNumberIsL1Estimate: boolean;
  explorer: string;
  /** The chain's native asset, a Quote Asset at the zero address (#242). */
  native: { symbol: string; name: string; decimals: number };
  /** Uniswap v4 and its periphery on the chain (the knowledge base's `uniswap/DEPLOYMENTS.md`, contracts/README.md). */
  uniswap: {
    poolManager: Address;
    stateView: Address;
    v4Quoter: Address;
    permit2: Address;
    /** The Universal Router the chain's traffic uses (#249), and the one Uniswap's feed lists, which reads the same structs. */
    universalRouter: Address;
    universalRouterV212: Address;
  };
};

export const ROBINHOOD_CHAIN: EvmChainProfile = {
  chain: "robinhood",
  name: "Robinhood Chain",
  chainId: 4663,
  finalityDepth: 25,
  rereadBlocks: 25,
  logBlockRange: 10,
  blockNumberIsL1Estimate: true,
  explorer: "https://robinhoodchain.blockscout.com",
  native: { symbol: "ETH", name: "Ether", decimals: 18 },
  uniswap: {
    poolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
    stateView: "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b",
    v4Quoter: "0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94",
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    universalRouter: "0x8876789976dEcBfCbBbe364623C63652db8C0904",
    universalRouterV212: "0x204FAca1764B154221e35c0d20aBb3c525710498",
  },
};

export const EVM_CHAINS = { robinhood: ROBINHOOD_CHAIN } as const;
export type EvmChain = keyof typeof EVM_CHAINS;
export const isEvmChain = (chain: string): chain is EvmChain => Object.hasOwn(EVM_CHAINS, chain);

/** One deployment of our contracts on an EVM chain, as an API is configured with it. */
export type EvmDeployment = {
  chain: EvmChain;
  factory: Address;
  hook: Address;
  registry: Address;
  keys: Address;
  /** The Tax Vault (#245): its buys are its own, never the wallet's that sent the transaction. */
  taxVault: Address;
  /** The block the factory was deployed in: the Indexer starts there. */
  fromBlock: number;
  /** The widest `eth_getLogs` block range the provider takes, which a run never asks past; the chain's profile's when unset. */
  logBlockRange?: number;
  /**
   * A run's budget, after which it saves how far it got and leaves the rest for the next run: the seconds it spends
   * (40), the RPC requests it makes (2,000, a fifth of what one invocation of the Worker may make), and, when set, the
   * block ranges it reads. It is checked between blocks, so a run always finishes the block it is in.
   */
  maxRunSeconds?: number;
  maxRequestsPerRun?: number;
  maxRangesPerRun?: number;
  /**
   * How many runs fail on one transaction before it is set aside (#279): 3 when the node or the decoder says it can
   * never be written (a revert, an event we cannot read, data Postgres refuses), and 60, an hour of runs, when the
   * failure may be the provider's own (an internal error, a timeout).
   */
  retryRuns?: number;
  retryRunsUnclear?: number;
};

/** The native asset's address as a Quote Asset: the zero address, native ETH in the pool key (#242). */
export const NATIVE: Address = "0x0000000000000000000000000000000000000000";

/** An EVM address in its checksummed form, which is how the API stores and answers every one. */
export const checksum = (address: string): Address => getAddress(address);
