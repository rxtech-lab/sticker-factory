-- Multi-image composition: a plan the assistant proposes and the user confirms before any
-- image is generated.
--
-- SQLite cannot ALTER a CHECK constraint, so widening the two `kind` enums means rebuilding
-- both tables. `PRAGMA legacy_alter_table = ON` keeps the rename from rewriting the foreign
-- keys in the tables that reference these two (chat_attachments, sticker_revisions,
-- generation_events), which must keep pointing at the real table name.

PRAGMA foreign_keys = OFF;
PRAGMA legacy_alter_table = ON;

-- generation_jobs: + 'compose'
ALTER TABLE generation_jobs RENAME TO generation_jobs_old;
DROP INDEX IF EXISTS generation_jobs_owner_created_idx;
DROP INDEX IF EXISTS generation_jobs_sticker_state_idx;
DROP INDEX IF EXISTS generation_jobs_one_active_per_sticker;

CREATE TABLE generation_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  source_message_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'edit', 'animation', 'chat', 'compose', 'export', 'cleanup')),
  prior_sticker_status TEXT CHECK (prior_sticker_status IN ('draft', 'published')),
  state TEXT NOT NULL DEFAULT 'queued' CHECK (state IN ('queued', 'running', 'waiting', 'succeeded', 'failed', 'cancelled')),
  workflow_run_id TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  error_code TEXT,
  error_message TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  completed_at INTEGER
);
INSERT INTO generation_jobs SELECT * FROM generation_jobs_old;
DROP TABLE generation_jobs_old;

CREATE INDEX generation_jobs_owner_created_idx ON generation_jobs(owner_id, created_at);
CREATE INDEX generation_jobs_sticker_state_idx ON generation_jobs(sticker_id, state);
CREATE UNIQUE INDEX generation_jobs_one_active_per_sticker
  ON generation_jobs(sticker_id) WHERE state IN ('queued', 'running', 'waiting');

-- chat_messages: + 'plan'
ALTER TABLE chat_messages RENAME TO chat_messages_old;
DROP INDEX IF EXISTS chat_messages_thread_sequence_unique;
DROP INDEX IF EXISTS chat_messages_thread_created_idx;

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY NOT NULL,
  thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  kind TEXT NOT NULL CHECK (kind IN ('text', 'image', 'image_edit', 'animation', 'plan', 'export', 'status')),
  content TEXT NOT NULL,
  target_layer_id TEXT,
  base_revision_id TEXT,
  image_placement TEXT NOT NULL DEFAULT 'replace' CHECK (image_placement IN ('replace', 'add')),
  sequence INTEGER NOT NULL,
  revision_id TEXT,
  job_id TEXT REFERENCES generation_jobs(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'complete' CHECK (status IN ('complete', 'streaming', 'failed')),
  created_at INTEGER NOT NULL
);
INSERT INTO chat_messages SELECT * FROM chat_messages_old;
DROP TABLE chat_messages_old;

CREATE UNIQUE INDEX chat_messages_thread_sequence_unique ON chat_messages(thread_id, sequence);
CREATE INDEX chat_messages_thread_created_idx ON chat_messages(thread_id, created_at);

CREATE TABLE composition_plans (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  plan_json TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'proposed' CHECK (state IN ('proposed', 'confirmed', 'superseded', 'cancelled')),
  job_id TEXT REFERENCES generation_jobs(id) ON DELETE SET NULL,
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);
CREATE INDEX composition_plans_sticker_state_idx ON composition_plans(sticker_id, state);
CREATE UNIQUE INDEX composition_plans_message_unique ON composition_plans(message_id);

PRAGMA legacy_alter_table = OFF;
PRAGMA foreign_keys = ON;
