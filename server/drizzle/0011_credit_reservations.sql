-- Credits are held before a generation job runs, and charged only if it succeeds.
--
-- Generation is asynchronous and fallible: a provider times out, a workflow dies, a user hits stop.
-- Charging when the job is queued would bill people for stickers they never received, and charging
-- when it finishes would let someone queue ten jobs on credits for one. A hold does both — the
-- balance leaves `available` the moment the job is accepted, and comes back whole on any ending
-- that is not success.
--
-- The hold lives in RxSubscription, not here; these two columns are only the reference. Every
-- terminal transition a job can take — succeeded in the workflow, failed there, dispatch failure,
-- cancellation — has to be able to find the hold again, and there is no other row that outlives all
-- four. `reservation_amount` is stored alongside because settling names the amount to charge, and
-- re-deriving it from the job kind would silently drift the day the price table changes.
--
-- Both are cleared once the hold is closed, so a replayed terminal transition cannot try to settle
-- a reservation that has already been settled. They stay null for free jobs (chat, plan, cleanup,
-- still exports) and for every job on a server where billing is unconfigured, which is how local
-- development and the test suites run.

ALTER TABLE generation_jobs ADD COLUMN reservation_id text;--> statement-breakpoint
ALTER TABLE generation_jobs ADD COLUMN reservation_amount integer NOT NULL DEFAULT 0;
