CREATE TABLE "evm_job_transactions" (
	"chain" text NOT NULL,
	"hash" text NOT NULL,
	"job" text NOT NULL,
	"purpose" text NOT NULL,
	"subject" text NOT NULL,
	"sender" text NOT NULL,
	"nonce" integer NOT NULL,
	"raw" text NOT NULL,
	"status" text DEFAULT 'pending' NOT NULL,
	"error" text,
	"block" bigint,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"resolved_at" timestamp with time zone,
	CONSTRAINT "evm_job_transactions_chain_hash_pk" PRIMARY KEY("chain","hash")
);
--> statement-breakpoint
ALTER TABLE "evm_job_transactions" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "evm_rebate_weeks" (
	"chain" text NOT NULL,
	"week_start" timestamp with time zone NOT NULL,
	"week_end" timestamp with time zone NOT NULL,
	"cap_bps" integer NOT NULL,
	"budget" numeric(40, 0) NOT NULL,
	"fees" numeric(40, 0) NOT NULL,
	"pot" numeric(40, 0) NOT NULL,
	"price_sol" numeric NOT NULL,
	"traders" integer NOT NULL,
	"credited" numeric(78, 0) NOT NULL,
	"settled_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "evm_rebate_weeks_chain_week_start_pk" PRIMARY KEY("chain","week_start")
);
--> statement-breakpoint
ALTER TABLE "evm_rebate_weeks" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
CREATE TABLE "evm_rebates" (
	"chain" text NOT NULL,
	"week_start" timestamp with time zone NOT NULL,
	"wallet" text NOT NULL,
	"fees" numeric(40, 0) NOT NULL,
	"amount" numeric(78, 0) NOT NULL,
	"status" text DEFAULT 'waiting' NOT NULL,
	"transaction" text,
	"paid_at" timestamp with time zone,
	CONSTRAINT "evm_rebates_chain_week_start_wallet_pk" PRIMARY KEY("chain","week_start","wallet")
);
--> statement-breakpoint
ALTER TABLE "evm_rebates" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "evm_quote_assets" ADD COLUMN "price_sol" numeric;--> statement-breakpoint
ALTER TABLE "evm_quote_assets" ADD COLUMN "priced_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "launches" ADD COLUMN "creator_destination" text;--> statement-breakpoint
ALTER TABLE "launches" ADD COLUMN "graduation_quote" numeric(78, 0);--> statement-breakpoint
ALTER TABLE "trades" ADD COLUMN "creator_credit" numeric(40, 0);--> statement-breakpoint
CREATE INDEX "evm_job_transactions_status_idx" ON "evm_job_transactions" USING btree ("chain","status");--> statement-breakpoint
CREATE INDEX "evm_rebates_status_idx" ON "evm_rebates" USING btree ("chain","status");