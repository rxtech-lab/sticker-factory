-- What a pet remembers: short notes its memory agent keeps from everything that happens between it and its
-- owner, each with an embedding so the ones that matter to a new moment can be found by meaning.
CREATE EXTENSION IF NOT EXISTS vector;
--> statement-breakpoint
CREATE TABLE "pet_memories" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"life_id" text NOT NULL,
	"content" text NOT NULL,
	"category" text NOT NULL,
	"importance" integer NOT NULL,
	"embedding" vector(1536) NOT NULL,
	"sources_json" jsonb NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	CONSTRAINT "pet_memories_category_check" CHECK ("pet_memories"."category" IN ('owner', 'bond', 'experience', 'place', 'feeling')),
	CONSTRAINT "pet_memories_importance_check" CHECK ("pet_memories"."importance" BETWEEN 1 AND 5)
);
--> statement-breakpoint
ALTER TABLE "pet_memories" ADD CONSTRAINT "pet_memories_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;
--> statement-breakpoint
CREATE INDEX "pet_memories_life_idx" ON "pet_memories" ("user_id", "life_id", "updated_at");
--> statement-breakpoint
CREATE INDEX "pet_memories_embedding_idx" ON "pet_memories" USING hnsw ("embedding" vector_cosine_ops);
