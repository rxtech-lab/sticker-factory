-- A composition plan is now approved against a rendered storyboard, and rejecting one carries a
-- reason that is fed straight back into the next planning turn.
--
-- Both columns are nullable with no default, which is the one shape SQLite allows ADD COLUMN to
-- use alongside a REFERENCES clause, so no table rebuild is needed here.
ALTER TABLE composition_plans ADD COLUMN concept_asset_id TEXT REFERENCES assets(id) ON DELETE SET NULL;
ALTER TABLE composition_plans ADD COLUMN decision_reason TEXT;
