import { z } from "zod";
import { Chain } from "./chains";
import { QuoteRef } from "./quotes";
import { CreatorEarningsDestination, RewardPayoutAsset } from "./launchModes";
import { TradeSide } from "./trades";

/**
 * Launching and trading on an EVM chain (#253, PRD #231): what the API prepares and an EVM wallet signs. The web stays a
 * pure client (ADR 0003): every transaction arrives ready to send (`EvmTransaction`), every signature as typed data
 * ready to sign (`EvmTypedData`), and nothing here needs an ABI on the client's side.
 *
 * Amounts are raw units as decimal strings. A Stock Token's amounts are raw too, with its multiplier in force beside
 * them (`QuoteRef.multiplier`, ADR 0028).
 */

export const EvmAddress = z.string().regex(/^0x[0-9a-fA-F]{40}$/, "must be an EVM address");
/** A transaction's hash, or a Uniswap v4 pool's id. */
export const EvmHash = z.string().regex(/^0x[0-9a-fA-F]{64}$/, "must be 32 bytes of hex");
const hexData = z.string().regex(/^0x([0-9a-fA-F]{2})*$/, "must be hex data");
const raw = z.string().regex(/^\d+$/, "must be a raw integer amount");
const positiveRaw = z.string().regex(/^[1-9]\d*$/, "must be a whole number of raw units, more than zero");

/** The address that stands for a chain's native asset wherever a Quote Asset is named (the Quote Registry's own rule). */
export const EVM_NATIVE = "0x0000000000000000000000000000000000000000";

/** The chains of the EVM chain family. */
export const EvmChain = Chain.exclude(["solana"]);
export type EvmChain = z.infer<typeof EvmChain>;

/**
 * A transaction for the wallet to send as it is (`eth_sendTransaction`): `value` in wei, and `gas` the limit the API
 * worked out from an estimate of this very transaction with a margin, since a swap's cost depends on the second it lands
 * in (the Reference Price's write, #271). The wallet sets the gas price.
 */
export const EvmTransaction = z.object({
  chainId: z.number().int(),
  to: EvmAddress,
  data: hexData,
  value: raw,
  gas: raw,
});
export type EvmTransaction = z.infer<typeof EvmTransaction>;

/** EIP-712 typed data for the wallet to sign as it is (`eth_signTypedData_v4`); `types` names `EIP712Domain` too. */
export const EvmTypedData = z.object({
  domain: z.record(z.string(), z.unknown()),
  types: z.record(z.string(), z.array(z.object({ name: z.string(), type: z.string() }))),
  primaryType: z.string(),
  message: z.record(z.string(), z.unknown()),
});
export type EvmTypedData = z.infer<typeof EvmTypedData>;

/** A signature as a wallet returns it: 65 bytes, `r`, `s`, `v`. */
export const EvmSignature = z.string().regex(/^0x[0-9a-fA-F]{130}$/, "must be a 65-byte signature");

// ---------------------------------------------------------------------------------------------------- the launch form

/** One Quote Asset an EVM chain's Quote Registry lists, with the Listing a new Launch on it would take (ADR 0028). */
export const EvmQuoteOption = QuoteRef.extend({
  /** True for the chain's native asset, whose address here is `EVM_NATIVE`. */
  native: z.boolean(),
  listing: z.object({
    /** A coin's start price: whole units of the Quote Asset for one whole coin. */
    startPrice: z.number(),
    /** The Opening Value: what the whole supply is worth at the start price, in the Quote Asset's raw units. */
    openingValue: raw,
    /** The Graduation Target as a multiple of the start price. */
    graduationMultiple: z.number().int(),
    /** The most a trade may name as its Referrer Fee, in basis points. */
    referrerFeeCapBps: z.number().int(),
  }),
});
export type EvmQuoteOption = z.infer<typeof EvmQuoteOption>;

/**
 * Everything an EVM chain offers a Launch, read from that chain's contracts: GET /v1/chains/:chain/launch-options.
 * The launch form starts with the chain and shows only this (story 1).
 */
export const EvmLaunchOptions = z.object({
  chain: EvmChain,
  /** The chain's name in plain text, in full. */
  name: z.string(),
  chainId: z.number().int(),
  explorer: z.string(),
  /** What `wallet_addEthereumChain` takes, for a wallet that has never met the chain. */
  wallet: z.object({
    chainId: z.string(),
    chainName: z.string(),
    nativeCurrency: z.object({ name: z.string(), symbol: z.string(), decimals: z.number().int() }),
    rpcUrls: z.array(z.string()),
    blockExplorerUrls: z.array(z.string()),
  }),
  native: z.object({ symbol: z.string(), name: z.string(), decimals: z.number().int() }),
  /** What this chain calls one of its tokenized stocks, the only name the site gives it ("Stock Token" on Robinhood Chain); null where it has no name of its own. */
  stockName: z.string().nullable(),
  contracts: z.object({
    factory: EvmAddress,
    hook: EvmAddress,
    registry: EvmAddress,
    taxVault: EvmAddress,
    /** Where the contracts' verified source is read: the link of the unaudited statement (ADR 0030). */
    source: z.string(),
  }),
  /** The listed Quote Assets, the native asset first. */
  quotes: z.array(EvmQuoteOption),
  /** A coin's whole supply in raw units, and its decimals. */
  supply: raw,
  decimals: z.number().int(),
  platformFeeBps: z.number().int(),
  /** The Opening Fee every Launch on this chain opens with: every buy's fees together at the launch's own second, and the seconds it runs. */
  openingFee: z.object({ startBps: z.number().int(), seconds: z.number().int() }),
  /** The Reward Tax's and the Stoke Tax's rates, in basis points. */
  taxRatesBps: z.array(z.number().int()),
  /** The steps of a Reward Launch's burn and liquidity shares, and the most the two may be together. */
  shareStepsBps: z.array(z.number().int()),
  sharesMaxBps: z.number().int(),
  payoutAssets: z.array(RewardPayoutAsset),
  creatorLock: z.object({ maxBps: z.number().int(), minSeconds: z.number().int(), maxPartSeconds: z.number().int() }),
  /** The Creator Earnings Destinations this chain's contracts offer today. */
  destinations: z.array(CreatorEarningsDestination),
});
export type EvmLaunchOptions = z.infer<typeof EvmLaunchOptions>;

/** What a First Buy inside the launch buys: it pays the Platform Fee and the coin's tax, and never the Opening Fee. */
export const EvmFirstBuy = z.object({
  /** The Quote Asset the Creator spends, fees included. */
  amountIn: positiveRaw,
  /** The coins that reach the Creator's wallet. */
  coinsOut: raw,
  fees: z.object({ platform: raw, tax: raw }),
});
export type EvmFirstBuy = z.infer<typeof EvmFirstBuy>;

/** A launch's cost in the chain's native asset, said before the Creator signs (story 13). */
export const EvmLaunchCost = z.object({
  /** The gas the launch is estimated to use, and the price per gas at the moment of the estimate, in wei. */
  gas: raw,
  gasPrice: raw,
  /** `gas` times `gasPrice`: the network's fee, an estimate. */
  fee: raw,
  /** The native asset the launch itself is sent: a First Buy in the native asset, otherwise 0. */
  value: raw,
});
export type EvmLaunchCost = z.infer<typeof EvmLaunchCost>;

/** A Launch's terms as the transaction fixes them, for the form's review. */
export const EvmLaunchTerms = z.object({
  type: z.enum(["standard", "reward", "liquidity"]),
  taxBps: z.number().int(),
  burnShareBps: z.number().int(),
  liquidityShareBps: z.number().int(),
  payoutAsset: RewardPayoutAsset.nullable(),
  earningsDestination: CreatorEarningsDestination,
  creatorLock: z.object({ bps: z.number().int(), cliffSeconds: z.number().int(), unlockSeconds: z.number().int() }).nullable(),
});
export type EvmLaunchTerms = z.infer<typeof EvmLaunchTerms>;

/**
 * Query of GET /v1/chains/:chain/launch-quote: what a First Buy would buy and what the launch would cost, as the form's
 * choices stand. Every field but `quote` may be left out.
 */
export const EvmLaunchQuoteQuery = z.object({
  quote: EvmAddress,
  /** The Creator's wallet, when one is connected: the cost is then estimated from it. */
  creator: EvmAddress.optional(),
  firstBuy: positiveRaw.optional(),
  /** The coin's tax in basis points (a Reward Tax or a Stoke Tax), which a First Buy pays. */
  taxBps: z.coerce.number().int().min(0).max(500).default(0),
  lockBps: z.coerce.number().int().min(0).max(2_000).default(0),
});
export type EvmLaunchQuoteQuery = z.infer<typeof EvmLaunchQuoteQuery>;

export const EvmLaunchQuote = z.object({
  chain: EvmChain,
  quote: EvmQuoteOption,
  firstBuy: EvmFirstBuy.nullable(),
  cost: EvmLaunchCost,
});
export type EvmLaunchQuote = z.infer<typeof EvmLaunchQuote>;

/**
 * The answer of an EVM launch's prepare. `step` says what the wallet does next:
 * `approve`: send `transaction`, which lets the factory take the First Buy (an asset with no permit), then prepare again with `salt`;
 * `permit`: sign `permit`, then prepare again with `salt`, `permitDeadline` and the signature;
 * `launch`: send `transaction`, the launch itself.
 */
export const PreparedEvmLaunch = z.object({
  chain: EvmChain,
  /** The coin's address, fixed by the Creator, the salt, the name and the ticker before the launch is sent. */
  coin: EvmAddress,
  /** The coin's Uniswap v4 pool. */
  pool: EvmHash,
  salt: EvmHash,
  /** Where the coin's metadata will be on Arweave. */
  metadataUri: z.string(),
  step: z.enum(["approve", "permit", "launch"]),
  transaction: EvmTransaction.nullable(),
  permit: EvmTypedData.nullable(),
  permitDeadline: raw.nullable(),
  terms: EvmLaunchTerms,
  firstBuy: EvmFirstBuy.nullable(),
  cost: EvmLaunchCost,
});
export type PreparedEvmLaunch = z.infer<typeof PreparedEvmLaunch>;

// ------------------------------------------------------------------------------------------------------------ trading

/** Query of GET /v1/launches/:coin/quote for a coin on an EVM chain. */
export const EvmTradeQuoteQuery = z.object({
  side: TradeSide,
  /** What the trader pays, in raw units: the Quote Asset for a buy, coins for a sell. */
  amount: positiveRaw,
  slippageBps: z.coerce.number().int().min(0).max(5_000).default(100),
  /** The address that brought the trade, credited the Referrer Fee in the swap itself (ADR 0027). */
  referrer: EvmAddress.optional(),
  /** The Referrer Fee the trade names, in basis points, at most the Launch's cap; the API's own setting when left out. */
  referrerFeeBps: z.coerce.number().int().min(0).max(500).optional(),
});
export type EvmTradeQuoteQuery = z.infer<typeof EvmTradeQuoteQuery>;

/**
 * What a trade on an EVM chain pays and what reaches the wallet, read from the chain at one block: Uniswap's own Quoter
 * runs the coin's hook, so `amountOut` is the figure the swap delivers at that block's second.
 *
 * `fees` are in the Quote Asset's raw units: the Platform Fee, the coin's tax (a Reward Tax or a Stoke Tax), the Opening
 * Fee while it runs (buys only), and the Referrer Fee as the hook takes it, which inside the Opening Fee's window is
 * only the room the others leave and may be less than the trade named, down to nothing (ADR 0026). `protocolFee` is
 * Uniswap's own, read from the pool, in the asset the trader pays with.
 *
 * Inside the Opening Fee's window the fee falls every second, so a buy that lands later than it was quoted pays less
 * and delivers more, never less; `opening.endsAt` says when it is over.
 */
export const EvmTradeQuote = z.object({
  chain: EvmChain,
  coin: EvmAddress,
  pool: EvmHash,
  side: TradeSide,
  amountIn: positiveRaw,
  /** What reaches the wallet after every fee: coins on a buy, the Quote Asset on a sell. */
  amountOut: raw,
  /** The least the chain lets the trade deliver: `amountOut` less the slippage, enforced by the router. */
  minAmountOut: raw,
  slippageBps: z.number().int(),
  quote: QuoteRef,
  fees: z.object({ platform: raw, tax: raw, opening: raw, referrer: raw }),
  feeBps: z.object({ platform: z.number().int(), tax: z.number().int(), opening: z.number().int(), referrer: z.number().int() }),
  protocolFee: z.object({ amount: raw, asset: z.enum(["quote", "coin"]), pips: z.number().int() }),
  /** Which tax the coin has; null for a standard coin. */
  tax: z.enum(["reward", "liquidity"]).nullable(),
  /** Set while the Launch's Opening Fee runs at the quote's block. */
  opening: z.object({ endsAt: z.iso.datetime() }).nullable(),
  referral: z.object({ referrer: EvmAddress, namedBps: z.number().int(), fee: raw }).nullable(),
  /** The coin's price before the trade, and the trade's own average price, in whole Quote Asset per whole coin. */
  priceBefore: z.number(),
  averagePrice: z.number(),
  /** The block the figures were read at, and its time. */
  block: z.number().int(),
  at: z.iso.datetime(),
});
export type EvmTradeQuote = z.infer<typeof EvmTradeQuote>;

/** What a wallet signed for Permit2, sent back with its signature so the trade's transaction can carry it. */
export const EvmTradePermit = z.object({
  signature: EvmSignature,
  amount: raw,
  expiration: raw,
  nonce: raw,
  sigDeadline: raw,
});
export type EvmTradePermit = z.infer<typeof EvmTradePermit>;

/** Body of POST /v1/trades/prepare for a coin on an EVM chain. */
export const PrepareEvmTradeRequest = EvmTradeQuoteQuery.extend({
  mint: EvmAddress,
  trader: EvmAddress,
  permit: EvmTradePermit.optional(),
}).refine((r) => r.referrer?.toLowerCase() !== r.trader.toLowerCase(), { message: "a trader can't refer themselves", path: ["referrer"] });
export type PrepareEvmTradeRequest = z.infer<typeof PrepareEvmTradeRequest>;

/**
 * The answer of an EVM trade's prepare. `step` says what the wallet does next:
 * `approve`: send `transaction`, which lets Permit2 move the asset the trade pays with (once per asset), then prepare again;
 * `permit`: sign `permit` (this trade's amount alone, for a few minutes), then prepare again with `permit` as `permitDetails` and the signature;
 * `trade`: send `transaction`, the trade itself.
 * A buy with the chain's native asset is `trade` at once: one signature.
 */
export const PreparedEvmTrade = z.object({
  chain: EvmChain,
  step: z.enum(["approve", "permit", "trade"]),
  transaction: EvmTransaction.nullable(),
  permit: EvmTypedData.nullable(),
  permitDetails: EvmTradePermit.omit({ signature: true }).nullable(),
  quote: EvmTradeQuote,
});
export type PreparedEvmTrade = z.infer<typeof PreparedEvmTrade>;

/** GET /v1/chains/:chain/wallets/:address: what a wallet holds, at one block. `assets` (a comma list, at most 8) names the ERC-20s to read. */
export const EvmWalletBalances = z.object({
  chain: EvmChain,
  wallet: EvmAddress,
  block: z.number().int(),
  /** The native asset, in wei. */
  native: raw,
  assets: z.array(z.object({ address: EvmAddress, balance: raw })),
});
export type EvmWalletBalances = z.infer<typeof EvmWalletBalances>;

/**
 * The answer of POST /v1/transactions/:hash?chain=<an EVM chain>: the site reports a transaction it sent so the coin or
 * the trade shows without waiting for the Indexer's next scheduled run. `pending` means the chain has not made it final
 * yet (ask again); `indexed` means its events are written.
 */
export const EvmTransactionReport = z.object({
  chain: EvmChain,
  status: z.enum(["pending", "indexed"]),
  /** The transaction's block, once it is in one. */
  block: z.number().int().nullable(),
});
export type EvmTransactionReport = z.infer<typeof EvmTransactionReport>;
