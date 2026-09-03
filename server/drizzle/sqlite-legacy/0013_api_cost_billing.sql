-- Provider pricing is captured from Vercel AI Gateway after each successful API call.
--
-- Text spend stays in nanodollars until the whole chat turn finishes, then converts at
-- 70 points/USD and rounds once. Image spend keeps both its USD audit total and the sum of points
-- produced by rounding each image separately. The reservation columns remain the up-front estimate
-- held in RxSubscription; these columns are the exact amount settled on success.

ALTER TABLE generation_jobs ADD COLUMN api_text_cost_nanodollars integer NOT NULL DEFAULT 0;--> statement-breakpoint
ALTER TABLE generation_jobs ADD COLUMN api_image_cost_nanodollars integer NOT NULL DEFAULT 0;--> statement-breakpoint
ALTER TABLE generation_jobs ADD COLUMN api_image_points integer NOT NULL DEFAULT 0;
