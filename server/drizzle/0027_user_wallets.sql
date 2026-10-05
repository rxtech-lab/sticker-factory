CREATE TABLE "user_wallets" (
	"user_id" text PRIMARY KEY NOT NULL,
	"gold" integer NOT NULL,
	"walk_gold_json" jsonb,
	"daily_gold_date" text,
	"version" integer DEFAULT 0 NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	CONSTRAINT "user_wallets_gold_check" CHECK ("user_wallets"."gold" >= 0)
);
--> statement-breakpoint
ALTER TABLE "user_wallets" ADD CONSTRAINT "user_wallets_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE TABLE "user_wallet_grants" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"kind" text NOT NULL,
	"gold" integer NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	CONSTRAINT "user_wallet_grants_kind_check" CHECK ("user_wallet_grants"."kind" IN ('sticker'))
);
--> statement-breakpoint
ALTER TABLE "user_wallet_grants" ADD CONSTRAINT "user_wallet_grants_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX "user_wallet_grants_user_idx" ON "user_wallet_grants" ("user_id", "created_at");
--> statement-breakpoint
INSERT INTO "user_wallets" ("user_id", "gold", "walk_gold_json", "version", "created_at", "updated_at")
SELECT "user_id", GREATEST(0, COALESCE(("stats_json"->>'gold')::integer, 20)), "walk_gold_json", 0, now(), now()
FROM "user_pets";
--> statement-breakpoint
UPDATE "user_pets" SET "stats_json" = "stats_json" - 'gold' WHERE "stats_json" ? 'gold';
--> statement-breakpoint
ALTER TABLE "user_pets" DROP COLUMN "walk_gold_json";
