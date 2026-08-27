-- An edit made in the on-device editor stops masquerading as a user turn.
--
-- It was posted as `kind='animation'` with the text "Edited on device", which the app had no way
-- to tell apart from something the user actually typed, so it rendered as a chat bubble. Giving it
-- its own kind lets the transcript draw it as a divider — a marker in the history rather than a
-- message — without the app guessing from the shape of the row.
--
-- SQLite cannot ALTER a CHECK constraint, so widening the enum means rebuilding the table.
-- `PRAGMA legacy_alter_table = ON` keeps the rename from rewriting the foreign keys in
-- `chat_attachments`, `generation_jobs` and `plans`, which must keep pointing at the real name.

PRAGMA foreign_keys = OFF;
PRAGMA legacy_alter_table = ON;

ALTER TABLE chat_messages RENAME TO chat_messages_old;
DROP INDEX IF EXISTS chat_messages_thread_sequence_unique;
DROP INDEX IF EXISTS chat_messages_thread_created_idx;

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY NOT NULL,
  thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  kind TEXT NOT NULL
    CHECK (kind IN ('text', 'image', 'image_edit', 'animation', 'device_edit', 'plan', 'export', 'status')),
  content TEXT NOT NULL,
  target_layer_id TEXT,
  base_revision_id TEXT,
  image_placement TEXT NOT NULL DEFAULT 'replace' CHECK (image_placement IN ('replace', 'add')),
  sequence INTEGER NOT NULL,
  revision_id TEXT,
  job_id TEXT REFERENCES generation_jobs(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'complete' CHECK (status IN ('complete', 'streaming', 'failed')),
  created_at INTEGER NOT NULL,
  -- Appended by 0004's ALTER, so they sit at the end of the column order the copy below relies on.
  plan_id TEXT REFERENCES plans(id) ON DELETE SET NULL,
  plan_revision INTEGER
);
INSERT INTO chat_messages SELECT * FROM chat_messages_old;
DROP TABLE chat_messages_old;

CREATE UNIQUE INDEX chat_messages_thread_sequence_unique ON chat_messages(thread_id, sequence);
CREATE INDEX chat_messages_thread_created_idx ON chat_messages(thread_id, created_at);

-- Reclassify the edits already in the transcript. A device edit is the only user message that
-- names a revision without owning a job: every typed turn is posted with the job that will answer
-- it, and the revision it eventually produces is recorded on the assistant's reply instead.
UPDATE chat_messages
SET kind = 'device_edit'
WHERE role = 'user' AND kind = 'animation' AND revision_id IS NOT NULL AND job_id IS NULL;

PRAGMA legacy_alter_table = OFF;
PRAGMA foreign_keys = ON;
