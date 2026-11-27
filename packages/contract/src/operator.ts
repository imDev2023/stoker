import { z } from "zod";
import { Chain } from "./chains";
import { JobRun } from "./revenue";

/**
 * The operator view and fee-change announcements (#22). The view is behind the operator token; announcements are public,
 * so a change to the fees every live curve pays never comes as a surprise.
 */

/** Everything at a glance, for support. */
export const OperatorOverview = z.object({
  launches: z.object({
    total: z.number().int(),
    byStatus: z.object({ live: z.number().int(), graduating: z.number().int(), graduated: z.number().int() }),
    /** Reward Launches among them. */
    reward: z.number().int(),
  }),
  rewardRounds: z.object({ paying: z.number().int(), paid: z.number().int() }),
  /** Buy-and-burn transactions so far. */
  burns: z.number().int(),
  /**
   * Permanent metadata (#44): Launches whose image and metadata JSON are on Arweave, and launched ones still waiting
   * for the Metadata Upload job (an item signed for a launch that never landed is neither).
   */
  metadataUploads: z.object({ uploaded: z.number().int(), pending: z.number().int() }),
  /** The latest run of each scheduled job. */
  jobs: z.array(JobRun),
  openAlerts: z.number().int(),
  /** The Platform Fee and Creator Fee as the chain has them now, in basis points. */
  fees: z.object({ platformFeeBps: z.number(), creatorFeeBps: z.number() }),
});
export type OperatorOverview = z.infer<typeof OperatorOverview>;

/** LaunchLab caps each of the platform's two fee rates; 10000 basis points is its 1e6 denominator's whole. */
export const FEE_BPS_MAX = 10_000;

/** Operator: announces a fee change. It applies to every live curve at once, so it takes effect no sooner than the lead time. */
export const AnnounceFeeChange = z.object({
  platformFeeBps: z.number().int().min(0).max(FEE_BPS_MAX),
  creatorFeeBps: z.number().int().min(0).max(FEE_BPS_MAX),
  effectiveAt: z.iso.datetime(),
  note: z.string().trim().max(500).optional(),
});
export type AnnounceFeeChange = z.infer<typeof AnnounceFeeChange>;

export const FeeAnnouncement = z.object({
  id: z.string(),
  platformFeeBps: z.number().int(),
  creatorFeeBps: z.number().int(),
  note: z.string().nullable(),
  announcedAt: z.iso.datetime(),
  effectiveAt: z.iso.datetime(),
  /** The `update_platform_config` transaction that applied it, once the admin has signed and sent it. */
  appliedSignature: z.string().nullable(),
  appliedAt: z.iso.datetime().nullable(),
});
export type FeeAnnouncement = z.infer<typeof FeeAnnouncement>;

/** Newest effective time first. */
export const FeeAnnouncementList = z.object({ announcements: z.array(FeeAnnouncement) });
export type FeeAnnouncementList = z.infer<typeof FeeAnnouncementList>;

/** Operator: asks for the transaction that applies an announced change, once its time has come. */
export const PrepareFeeChange = z.object({ id: z.string() });
export type PrepareFeeChange = z.infer<typeof PrepareFeeChange>;

/** The `update_platform_config` transaction for the cold admin key to sign (ADR 0004), unsigned, with its rates. */
export const PreparedFeeChange = z.object({
  id: z.string(),
  admin: z.string(),
  platformFeeBps: z.number().int(),
  creatorFeeBps: z.number().int(),
  /** Base64 legacy transaction; the admin signs as fee payer and sends it. */
  transaction: z.string(),
  lastValidBlockHeight: z.number().int(),
});
export type PreparedFeeChange = z.infer<typeof PreparedFeeChange>;

/**
 * Operator: each EVM chain's keys (ADR 0030, story 47): the Admin and the three server keys, each with its address on
 * the chain, what it can and cannot do, and whether this API holds the key (a Worker secret); and the Keeper's native
 * balance, which pays every job's gas and the chain's Volume Rebates (#254).
 */
export const EvmKey = z.object({
  role: z.enum(["admin", "round_key", "ladder_key", "keeper"]),
  /** The address the chain's StokerKeys names; null when the role is held by nobody (revoked, or never appointed). */
  address: z.string().nullable(),
  /** Whether this API holds the role's key, and it is the address the chain names. Never for the Admin, a hardware wallet. */
  heldByApi: z.boolean(),
  /** What the role can do, and what no key of ours can do. */
  can: z.array(z.string()),
  cannot: z.array(z.string()),
});
export type EvmKey = z.infer<typeof EvmKey>;

export const EvmChainKeys = z.object({
  chain: Chain,
  name: z.string(),
  keys: z.array(EvmKey),
  keeper: z.object({
    /** The Keeper's native balance in raw units of the chain's native asset; null when the API holds no Keeper key. */
    balance: z.string().nullable(),
    symbol: z.string(),
    decimals: z.number().int(),
    /** Below this the chain's `keeper_low` alert is open and the Keeper pays no Volume Rebate. */
    minBalance: z.string(),
    low: z.boolean(),
  }),
});
export type EvmChainKeys = z.infer<typeof EvmChainKeys>;

export const EvmKeysPage = z.object({ chains: z.array(EvmChainKeys), problem: z.string().nullable() });
export type EvmKeysPage = z.infer<typeof EvmKeysPage>;

/**
 * Operator: the owner's record of an EVM chain's Burn budget carried to Solana by hand (ADR 0030): what left the Admin's
 * address on the EVM chain, in which transaction, and what reached the operations wallet on Solana, in which. The
 * Ledger gains one entry on each side; Solana's Burn may spend what arrived, and the EVM chain's budget is the less.
 */
export const RecordBurnCarry = z.object({
  chain: Chain.exclude(["solana"]),
  /** The EVM chain's transaction from the Admin's address. */
  evmTransaction: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  /** What left, in raw units of the chain's native asset. */
  amount: z.string().regex(/^[1-9]\d*$/),
  /** The Solana transaction that paid the operations wallet, and the lamports it paid. */
  solanaSignature: z.string().regex(/^[1-9A-HJ-NP-Za-km-z]{64,88}$/),
  lamports: z.string().regex(/^[1-9]\d*$/),
});
export type RecordBurnCarry = z.infer<typeof RecordBurnCarry>;
