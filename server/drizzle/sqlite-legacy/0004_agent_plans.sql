-- Plans become a mutable artifact the agent drafts, revises, shows, and finalizes.
--
-- Three things change shape here:
--   * `composition_plans` becomes `plans`: it gains a revision counter, a supersedes link, and two
--     new states (`draft`, `finalized`) replacing the single `proposed` state.
--   * `chat_messages` gains a pointer to the plan a `kind='plan'` card renders, because one plan is
--     now shown many times instead of owning exactly one message.
--   * `generation_jobs` gains the `plan` kind for the drafting turn itself.
--
-- SQLite cannot ALTER a CHECK constraint, so widening an enum means rebuilding the table.
-- `PRAGMA legacy_alter_table = ON` keeps the renames from rewriting foreign keys in the tables that
-- reference these, which must keep pointing at the real table name.

PRAGMA foreign_keys = OFF;
PRAGMA legacy_alter_table = ON;

-- generation_jobs: + 'plan'
ALTER TABLE generation_jobs RENAME TO generation_jobs_old;
DROP INDEX IF EXISTS generation_jobs_owner_created_idx;
DROP INDEX IF EXISTS generation_jobs_sticker_state_idx;
DROP INDEX IF EXISTS generation_jobs_one_active_per_sticker;

CREATE TABLE generation_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  source_message_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'edit', 'animation', 'chat', 'plan', 'compose', 'export', 'cleanup')),
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

-- composition_plans -> plans
ALTER TABLE composition_plans RENAME TO composition_plans_old;
DROP INDEX IF EXISTS composition_plans_sticker_state_idx;
DROP INDEX IF EXISTS composition_plans_message_unique;

CREATE TABLE plans (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  sticker_id TEXT NOT NULL REFERENCES stickers(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL REFERENCES chat_threads(id) ON DELETE CASCADE,
  -- The message the plan was first shown in. No longer unique: `show_plan` posts a fresh card
  -- every time the agent wants the user to look at the current draft.
  message_id TEXT NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  plan_json TEXT NOT NULL,
  state TEXT NOT NULL DEFAULT 'draft'
    CHECK (state IN ('draft', 'finalized', 'confirmed', 'superseded', 'cancelled')),
  -- Bumped by every `update_plan` so the transcript can tell which revision a card was showing.
  revision INTEGER NOT NULL DEFAULT 1,
  -- Set when the agent starts a fresh plan while an earlier one was already finalized or running.
  supersedes_id TEXT REFERENCES plans(id) ON DELETE SET NULL,
  job_id TEXT REFERENCES generation_jobs(id) ON DELETE SET NULL,
  -- A storyboard render of the plan, shown on the card before anything real is made.
  concept_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL,
  -- Why the user rejected the plan. Fed back into the next planning turn.
  decision_reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  decided_at INTEGER
);

-- Carry existing proposals over into the new shape. Each old `part` becomes a `generate` layer, and
-- the sticker's own kind supplies the plan kind that the old schema never recorded.
--
-- `motionInstruction` and `conceptPrompt` are intentionally dropped: motion is now expressed as
-- structured animation specs, and there is no faithful way to turn a free-text sentence into them.
-- An imported plan therefore arrives with no animations, which the user can ask the agent to add.
INSERT INTO plans (
  id, owner_id, sticker_id, thread_id, message_id, plan_json, state, revision,
  supersedes_id, job_id, concept_asset_id, decision_reason, created_at, updated_at, decided_at
)
SELECT
  p.id, p.owner_id, p.sticker_id, p.thread_id, p.message_id,
  json_object(
    'version', 1,
    'title', json_extract(p.plan_json, '$.title'),
    'summary', json_extract(p.plan_json, '$.summary'),
    'kind', s.kind,
    'timing', json_object('durationSeconds', 2.0, 'fps', 30, 'loop', 'loop'),
    'layers', json((
      SELECT json_group_array(json_object(
        'layerId', json_extract(part.value, '$.layerId'),
        'name', json_extract(part.value, '$.name'),
        'source', json_object('kind', 'generate', 'prompt', json_extract(part.value, '$.prompt')),
        'x', json_extract(part.value, '$.x'),
        'y', json_extract(part.value, '$.y'),
        'scaleX', json_extract(part.value, '$.scaleX'),
        'scaleY', json_extract(part.value, '$.scaleY'),
        'rotationDegrees', 0,
        'animations', json_array()
      ))
      FROM json_each(p.plan_json, '$.parts') AS part
    ))
  ),
  -- 'proposed' was what 'finalized' now means: shown to the user and awaiting their decision.
  CASE p.state WHEN 'proposed' THEN 'finalized' ELSE p.state END,
  1, NULL, p.job_id, p.concept_asset_id, p.decision_reason, p.created_at, p.created_at, p.decided_at
FROM composition_plans_old p
JOIN stickers s ON s.id = p.sticker_id;

DROP TABLE composition_plans_old;

CREATE INDEX plans_sticker_state_idx ON plans(sticker_id, state);
CREATE INDEX plans_owner_created_idx ON plans(owner_id, created_at);

-- chat_messages: a plan card points at the plan and the revision it was rendering.
-- Nullable with no default is the one shape SQLite allows ADD COLUMN to use with REFERENCES.
ALTER TABLE chat_messages ADD COLUMN plan_id TEXT REFERENCES plans(id) ON DELETE SET NULL;
ALTER TABLE chat_messages ADD COLUMN plan_revision INTEGER;

PRAGMA legacy_alter_table = OFF;
PRAGMA foreign_keys = ON;
