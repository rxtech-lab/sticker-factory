-- Gold moves to RxSubscription (unit `gold`). `user_wallet_grants` becomes the outbox every gold
-- move is written to before it is carried there. Wallet balances are not carried over: owners with
-- a wallet start from zero, and new owners from the starting purse.
ALTER TABLE "user_wallet_grants" DROP CONSTRAINT "user_wallet_grants_kind_check";
--> statement-breakpoint
ALTER TABLE "user_wallet_grants" ADD COLUMN "reservation_id" text;
--> statement-breakpoint
ALTER TABLE "user_wallet_grants" ADD COLUMN "billing_environment" text;
--> statement-breakpoint
ALTER TABLE "user_wallet_grants" ADD COLUMN "settled_at" timestamp with time zone;
--> statement-breakpoint
-- Sticker rewards already paid went into the dropped wallet balance: kept as settled, so a retried
-- step still finds them, and with no gold of their own, so nothing carries them.
UPDATE "user_wallet_grants" SET "gold" = 0, "settled_at" = "created_at";
--> statement-breakpoint
ALTER TABLE "user_wallet_grants" ADD CONSTRAINT "user_wallet_grants_kind_check" CHECK ("user_wallet_grants"."kind" IN ('sticker', 'pet', 'starting'));
--> statement-breakpoint
ALTER TABLE "user_wallet_grants" ADD CONSTRAINT "user_wallet_grants_billing_environment_check" CHECK ("user_wallet_grants"."billing_environment" IN ('xcode', 'sandbox', 'production'));
--> statement-breakpoint
CREATE INDEX "user_wallet_grants_unsettled_idx" ON "user_wallet_grants" ("user_id") WHERE "settled_at" IS NULL;
--> statement-breakpoint
ALTER TABLE "user_wallets" DROP CONSTRAINT "user_wallets_gold_check";
--> statement-breakpoint
ALTER TABLE "user_wallets" DROP COLUMN "gold";
