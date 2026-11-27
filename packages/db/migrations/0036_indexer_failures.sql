CREATE TABLE "indexer_failures" (
	"chain" text NOT NULL,
	"factory" text NOT NULL,
	"transaction" text NOT NULL,
	"block" bigint NOT NULL,
	"attempts" integer DEFAULT 1 NOT NULL,
	"error" text NOT NULL,
	"first_failed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_failed_at" timestamp with time zone DEFAULT now() NOT NULL,
	"set_aside_at" timestamp with time zone,
	"resolved_at" timestamp with time zone,
	CONSTRAINT "indexer_failures_chain_factory_transaction_pk" PRIMARY KEY("chain","factory","transaction")
);
--> statement-breakpoint
ALTER TABLE "indexer_failures" ENABLE ROW LEVEL SECURITY;--> statement-breakpoint
ALTER TABLE "chain_cursors" ADD COLUMN "log_block_range_setting" integer;--> statement-breakpoint
ALTER TABLE "chain_cursors" ADD COLUMN "log_clean_ranges" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "launches" ADD COLUMN "factory" text;--> statement-breakpoint
CREATE INDEX "launches_created_at_idx" ON "launches" USING btree ("created_at");--> statement-breakpoint
CREATE INDEX "launches_pool_idx" ON "launches" USING btree ("pool");