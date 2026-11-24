CREATE TABLE "chain_cursors" (
	"chain" text PRIMARY KEY NOT NULL,
	"indexed_block" bigint NOT NULL,
	"indexed_block_time" timestamp with time zone,
	"head_block" bigint,
	"head_block_time" timestamp with time zone,
	"checked_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "chain_cursors" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "evm_quote_assets" (
	"chain" text NOT NULL,
	"address" text NOT NULL,
	"symbol" text,
	"name" text,
	"decimals" integer NOT NULL,
	"category" text DEFAULT 'community' NOT NULL,
	"multiplier" numeric(78, 0),
	"multiplier_at" timestamp with time zone,
	"read_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "evm_quote_assets_chain_address_pk" PRIMARY KEY("chain","address")
);
--> statement-breakpoint
ALTER TABLE "evm_quote_assets" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "launches" ALTER COLUMN "global_config" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "airdrop_recipients" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "arweave_top_ups" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "chosen_mint_keys" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "coin_mentions" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "creator_buybacks" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "creator_forwards" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "creator_tiers" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "curves" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "fee_announcements" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "fee_keys" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "graduations" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "holding_checks" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "holding_lots" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "job_transactions" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "launch_drafts" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "launch_markets" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "launch_metadata" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "launches" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "ledger_entries" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "mention_polls" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "metadata_uploads" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "notable_wallets" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "quote_assets" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "rebates" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "reward_payouts" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "reward_rounds" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "reward_sales" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
ALTER TABLE "trades" ADD COLUMN "chain" text DEFAULT 'solana' NOT NULL;--> statement-breakpoint
CREATE INDEX "launches_chain_created_at_idx" ON "launches" USING btree ("chain","created_at");