-- Which surface asked for the turn, because it decides which image model draws it.
--
-- The Messages extension's quick mode has a different economy from the main app. Someone is
-- standing inside a conversation with the keyboard open, waiting to send something now, and the
-- artwork they get is going to be looked at once at thumbnail size. Three minutes on
-- `AI_IMAGE_MODEL` is the wrong trade there; `AI_QUICK_IMAGE_MODEL` is a fraction of the wait and a
-- fraction of the price, and pays for it with a background that has to be keyed out afterwards
-- rather than arriving transparent (see `lib/ai/chroma-key.ts`).
--
-- It lives on the job rather than on the sticker because it describes one turn, not one project: a
-- sticker started in Messages and then opened in the main app should have its next turn drawn
-- properly, and the job row is the only thing the generation workflow is handed. A retry copies the
-- flag from the job it retries, so the second attempt is drawn by the same model as the first.

ALTER TABLE generation_jobs ADD COLUMN quick integer NOT NULL DEFAULT 0;
