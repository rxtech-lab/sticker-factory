# Sticker Factory server

Next.js 16 backend and read-only web library for Sticker Factory. The iOS app creates and renders stickers; this service owns authentication, private project/chat history, immutable revisions, durable AI work, and presigned Cloudflare R2 media access.

## Architecture

- `app/api/v1`: bearer-authenticated iOS and Messages APIs. Ownership always comes from the verified OAuth `sub` claim.
- `app/library`: authenticated web Library, private previews/downloads, parent-based revision comparison, read-only chat, and durable deletion.
- `lib/contracts`: strict Zod `StickerDocumentV1`, operation, event, and API envelopes shared through `fixtures/`.
- `lib/db` and `drizzle/`: Drizzle/Postgres model on Neon, active-job constraints, asset deletion guards, and immutable revision triggers. `drizzle/sqlite-legacy/` is the pre-migration libSQL history, kept for reference and never applied.
- `workflows/sticker-generation`: Vercel Workflow generation, editing, validated animation snapshots, decision transitions, and delayed R2 deletion sweeps. Its `"use step"` wrappers are shells over `lib/services/job-lifecycle.ts`, which owns the three transitions a job can take and is shared with the work that does not need a workflow.
- `lib/ai`: Vercel AI Gateway adapter (`AI_IMAGE_MODEL` for every image generation/edit,
  `AI_QUICK_IMAGE_MODEL` for turns the Messages extension's quick mode starts, and
  `AI_ORCHESTRATOR_MODEL` for chat, routing, planning, review, and animation) plus a deterministic
  local/test adapter. The quick model cannot draw transparency, so those turns are drawn against a
  pure green or blue backdrop that `lib/ai/chroma-key.ts` cuts back out.
- `lib/storage`: private R2 S3-compatible storage, signed URLs, checksum/media/transparency verification, and bounded image decoding.

OAuth access tokens are verified against RxLab JWKS and are never forwarded to Vercel AI Gateway. Postgres transcripts/revisions and private R2 assets are the recoverable AI context; provider conversation state is not the source of truth.

## Local setup

Requires Bun 1.3+ and native Sharp support.

```bash
bun install
cp .env.example .env.local
bun run db:migrate
bun run dev
```

For a local AI-free environment, set `STICKER_FACTORY_MOCK_SERVICES=true`; jobs still run through the local Vercel Workflow runtime. Never enable mock services in production. Missing OAuth, AI, database, or R2 secrets do not prevent a production build; the corresponding runtime operation returns a configuration error.

Set server-only `FIRECRAWL_API_KEY` to enable Firecrawl web research. Chat, planning, layout, editing, animation, and generation share `web_search`, `web_scrape`, `web_crawl`, and `web_crawl_status`. Image and video generation research runs through the orchestrator before the media API call; when configured, this adds a model call even if no research is needed. Search/crawl requests are limited to five pages and time out after 30 seconds per API request. Crawl status is scoped to the agent invocation that started it. Without the key, web tools report a configuration error and image/video generation skips research. Firecrawl usage is billed by Firecrawl and is not included in AI Gateway point accounting. API contracts: [search](https://docs.firecrawl.dev/api-reference/endpoint/search), [crawl](https://docs.firecrawl.dev/api-reference/endpoint/crawl-post), and [crawl status](https://docs.firecrawl.dev/api-reference/endpoint/crawl-get).

Set `APP_STORE_URL=https://apps.apple.com/app/id6805825708` to show the home page's App Store download badge. Leave it unset or blank to hide the badge. The unmodified SVG in `public/images/home/download-on-the-app-store.svg` comes from [Apple's official badge artwork](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg).

Production needs separate RxLab OAuth clients:

- confidential web client for `@rxtech-lab/authjs-rxlab@1.6.1`, including the registered Auth.js callback;
- public iOS PKCE client `client_1ce3e6efd6da4214a61df67949a71622`, configured as `IOS_OAUTH_CLIENT_ID` (no client secret), plus any staged clients in `RXLAB_ALLOWED_CLIENT_IDS`.
- optional `IOS_MINIMUM_APP_VERSION`, a dotted iOS marketing version such as `1.2`. Once set, the
  sticker-list endpoints require `X-iOS-App-Version` from the iOS OAuth client and return `426` with
  `IOS_APP_UPDATE_REQUIRED` when the app is older. Leave it empty until the header-bearing app has
  shipped so an existing production build is not cut off during rollout. iOS requests also send
  the device's preferred language through the standard `Accept-Language` header.

Configure a Neon Postgres database (`DATABASE_URL`, the pooled connection string), a private R2 bucket, Vercel AI Gateway (API key or Vercel OIDC), and Vercel Workflow. Run `bun run db:migrate` before serving traffic.

## API v1

All state-changing endpoints require `Idempotency-Key`. JSON bodies are content-type checked and limited to 1 MB. AI inputs, uploads, layers/keyframes, and event replay have independent bounds.

- `POST/GET /api/v1/stickers` — the authenticated list accepts `?q=&cursor=` for title search
- `POST /api/v1/stickers/import` — turns an image the client already has into a static sticker with an accepted, active root revision, generating nothing
- `GET/PATCH/DELETE /api/v1/stickers/{id}` — `PATCH` renames an owned live sticker
- `GET/POST /api/v1/stickers/{id}/chat/messages`
- `POST /api/v1/stickers/{id}/chat/messages/{messageId}/retry`
- `POST /api/v1/stickers/{id}/revisions` — saves a client-edited document as a new accepted revision
- `POST /api/v1/stickers/{id}/revisions/{revisionId}/{accept|reject|revert}`
- `POST /api/v1/stickers/{id}/exports` — binds an already-rendered, already-verified export set. It runs in the request rather than through the durable runtime (see `lib/services/export-publish.ts`), so the job it returns is usually terminal before the client opens its event stream
- `POST /api/v1/uploads`
- `POST /api/v1/uploads/{assetId}/complete`
- `GET /api/v1/assets/{assetId}/download`
- `GET /api/v1/jobs/{jobId}/events` (replayable SSE with `Last-Event-ID`)
- `POST /api/v1/devices` — registers this install's APNs token; `DELETE /api/v1/devices/{token}` drops it on sign-out. Neither takes an `Idempotency-Key`: the token is the key, and registration is an upsert on it.

Marketplace:

- `GET/POST /api/v1/packs` — browse published packs (`?sort=recent|popular&q=&cursor=`), or `?mine=true` for the authoring list, which includes drafts
- `GET/PATCH/DELETE /api/v1/packs/{packId}` — `packId` accepts the uuid or the public slug
- `POST /api/v1/packs/{packId}/{publish|unpublish}`
- `POST/PUT /api/v1/packs/{packId}/items` — add one, or replace-and-reorder the whole membership
- `DELETE /api/v1/packs/{packId}/items/{stickerId}`
- `POST/DELETE /api/v1/packs/{packId}/install`
- `GET /api/v1/creators/{handle}` — a creator's byline plus every pack of theirs the viewer may see
- `GET /api/v1/library/sections` — "My Stickers" then one section per installed pack; `?q=` searches sticker titles in every section

A saved edit arrives already accepted — the user has seen exactly what they made, so there is no
candidate to review — and its revision id is derived from the idempotency key, so a retried save
replays rather than forking the revision chain. It carries no renditions, so a previously published
sticker drops back to `draft` until it is exported again.

The list envelope exposes an ownership-checked `systemSticker` rendition for Messages. Downloads return `{ url, expiresAt, asset }`. SSE emits only persisted schema-valid events and complete document snapshots; terminal reconnects also receive `X-Job-State` so an already-consumed terminal event is never duplicated.

`/api/v1/library/sections` is separate from `GET /api/v1/stickers` rather than a mode of it, and is
deliberately unpaginated. `GET /api/v1/stickers` stays owner-scoped — every existing caller assumes
each row is a sticker it may edit — and the Messages extension reconciles its cache by removing
whatever a response did not mention, so a pack split across a page boundary would read as a pack
that lost half its stickers. The extension falls back to the flat endpoint on a 404, because it
ships inside the app binary and can be newer than the server.

## Marketplace invariants

- A pack contains only stickers its creator owns and has published; a DB trigger backs the service check.
- Packs are live: installers resolve the current membership on every fetch, so there is no version to update.
- A member that falls back to `draft` (any device edit does this) silently leaves every installer's copy. The creator's edit page names them, since nothing else would.
- Publishing a pack is what makes its members' `system`/`preview` artwork readable by other users — `getReadableAsset` in `lib/services/assets.ts` is the only place that widens ownership, and it authorizes by publication, not by install, so browse can render art to people who have not installed. A borrowed download never echoes the creator's `originalFilename`.
- Self-install is refused: the creator's stickers already appear under "My Stickers".
- A pack slug is immutable once published, so a shared link survives a rename.
- `install_count`/`item_count` are trigger-maintained. Postgres fires row triggers for FK-cascade deletes, so these stay correct on their own; `bun run db:packs:recount` remains as a reconciliation backstop.

## Push notifications

A finished turn is announced from here, not from the phone. Generation runs on the server and the
client's SSE stream dies the moment iOS suspends the app — which is exactly the case a "your sticker
is ready" banner exists for — so the local notification it used to post could only ever fire for a
turn the user was still watching.

- `lib/notifications/apns.ts` talks to APNs over `node:http2` with a token-based (`.p8`) provider
  JWT. HTTP/2 is the only transport APNs accepts and `fetch` will not negotiate it, which is the
  whole reason the file is not a thin wrapper. Provider tokens are cached for 45 minutes, inside
  Apple's one-hour validity and well clear of `TooManyProviderTokenUpdates`.
- `completeJob`/`failJob` push after the terminal transition commits, so a step that re-runs over an
  already-finished job cannot announce it twice. Cleanup and export jobs stay silent.
- Sending is best-effort and never throws: a sticker that generated must not be reported as failed
  because Apple timed out. A 410/`BadDeviceToken` disables that `device_tokens` row rather than
  deleting it, so a dead token is not retried every turn and a later re-registration revives it.
- `device_tokens` is keyed on the token, not on `(user, token)`. A token names an app install, so a
  second account signing in on the same phone takes the row over instead of leaving the first one
  pushing to a device it no longer owns.
- Set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, and `APNS_BUNDLE_ID`. Missing credentials
  are a supported state: nothing is sent and the skip is logged. The `.p8` auth key is issued per
  Apple *team*, not per app, so the RxLab team key already in use elsewhere signs for this topic
  too; `APNS_PRIVATE_KEY` takes the PEM or its base64. The topic is the app's bundle id,
  `app.rxlab.stickerfactory` — not the Messages extension's.

## Credits and entitlements

Generation is metered in points against the shared [RxSubscription](https://github.com/rxtech-lab/rx-subscription-service)
service. `lib/subscription/` holds all of it: `client.ts` is the HTTP wrapper, `pricing.ts` the
hold estimates, `credits.ts` the hold/settle/release cycle and the permission check.

- Points are **held** before a job is queued and **charged** only when it succeeds. Generation is
  asynchronous and fallible, so charging up front would bill people for stickers they never
  received, and charging at the end would let someone queue ten jobs on points for one. The hold
  leaves `available` immediately and comes back whole on failure, cancellation, or a workflow that
  could not be dispatched.
- Successful AI calls use the exact USD charge Vercel AI Gateway returns in
  `providerMetadata.gateway.cost`. Ten USD converts to 700 points. All text calls in one chat turn
  are added before rounding to the nearest point; every image generation is converted and rounded
  separately. The up-front job table is only a reservation estimate, and unused held points are
  released when the exact final amount is settled.
- `generation_jobs.reservation_id` / `reservation_amount` carry the hold. Every terminal transition
  a job can take has to be able to find it again, and no other row outlives all four. Both are
  cleared once the hold closes, so a replayed transition cannot settle twice.
- Reserving happens at each `generationJobs` insert; settling in `completeJob`, releasing in
  `failJob`, `cancelGenerationWorkflow`, and `recordDispatchFailure`. A hold placed for a job that
  then loses the one-active-job-per-sticker race is released by `abandonHold`. A publish settles
  after its response flushes — the exports route hands the settlement `after` from `next/server`,
  because the job is already terminal in the database and the client is waiting on the reply.
- Deleting your own work and still exports remain free. Animated exports keep their fixed charge
  because they run a frame-by-frame encode rather than a paid AI API call.
- Publishing a pack requires the `marketplace.publish:all` permission (legacy `marketplace.publish`
  grants also work) and spends no credits. Ownership and published-sticker validation still apply.
- Failures are told apart deliberately. Out of credits is `402 INSUFFICIENT_CREDITS`, no plan is
  `402 SUBSCRIPTION_REQUIRED`, and a billing service that cannot be reached is `503`, never an empty
  wallet. Settle and release swallow their errors — a job that really ran must not be reported as
  failed because billing hiccuped, and an unreleased hold expires on its own.
- Set `RX_SUBSCRIPTION_URL`, `RX_SUBSCRIPTION_SANDBOX_API_KEY`, and
  `RX_SUBSCRIPTION_PRODUCTION_API_KEY` to serve TestFlight and App Store users together. Both
  keys are server-only secrets. The updated iOS client sends `X-StoreKit-App-Transaction` alongside
  its OAuth token. Apple's official verifier checks its signature, certificate chain/revocation,
  bundle ID, App Store app ID, and environment before selecting the matching key. Plain environment
  headers never select a key, and Xcode-signed transactions are never accepted as Apple proof.
- `APPLE_BUNDLE_ID` and `APPLE_APP_ID` optionally override the existing Sticker Factory identity
  (`app.rxlab.stickerfactory`, `6805825708`). The authenticated web OAuth client uses production;
  mobile clients with missing or invalid proof cannot perform billing operations. Reads and refunds
  remain available without proof; refund routing comes from the saved job.
- Apply migration `0006_job_billing_environment` before deploying. New jobs store their billing
  environment next to the reservation. Background settlement, cancellation, and refunds use that
  saved environment even if the user later switches builds. Never copy a production key into the
  sandbox variable (or vice versa); missing or mismatched keys return an error.
- Roll out a new iOS build together with the server changes. Older mobile builds do not send proof
  and receive `BILLING_ENVIRONMENT_REQUIRED` for billing operations once split keys are enabled.
  No deployment-wide `RX_SUBSCRIPTION_ENVIRONMENT` is needed for dual-environment routing.
- `RX_SUBSCRIPTION_API_KEY` remains supported for legacy/local single-environment deployments.
  An explicit `RX_SUBSCRIPTION_ENVIRONMENT=sandbox|production` remains available for a dedicated
  deployment and old jobs without a recorded environment. Verified requests and recorded job
  environments take precedence. Audit existing open reservations before changing this fallback;
  in a dual-key-only deployment, old holds with no recorded environment are logged and left
  unsettled instead of guessing a balance. Do not backfill historical jobs from the current key.
- Deployed servers reject missing billing configuration with `503 SUBSCRIPTION_NOT_CONFIGURED`.
  Only fully unconfigured local development/tests bypass billing. Apple's public root certificate
  is included in the deployment; this verification does not require an App Store Connect private key.

## Media and deletion invariants

- Private source/output assets use internal UUID references only.
- Source revision fields are DB-trigger immutable; export renditions are separate mutable relations.
- Static publication requires a rendered transparent PNG and a `<500,000` byte system rendition.
- Animated publication verifies real GIF/MP4/system timing against the accepted cycle, including doubled `pingPong` duration.
- Masks must match the target image format/dimensions and contain both transparent and painted alpha pixels.
- Deletion marks a tombstone, blocks new asset binding, deletes known objects, waits past signed-PUT expiry, sweeps again, then cascades Postgres rows.

Personal photos, masks, transcripts, sources, and immutable revisions remain private until project deletion. Web and iOS upload UI must show this disclosure before personal-photo upload.

## Verification

```bash
bun run typecheck
bun run test
bun run lint
bun run test:e2e
bun run build
```

Vitest covers contracts, bearer claims, refresh failure, services, revisions, idempotency, storage verification, SSE, and Workflow snapshots. Playwright uses a guarded temporary PGlite database — Postgres compiled to WebAssembly, so the triggers and constraints are the real ones — and a mock-auth/service harness; its seed endpoint is unavailable in production.

The `Server Tests` GitHub Actions workflow runs type checking, Vitest, and all Playwright browser/API tests on server pushes and pull requests, and can also be started manually. It installs Chromium and uploads failure traces. No database service, Docker container, or external credentials are required.

API specs are grouped by authentication, packs, validation, chat, devices, and stickers under `e2e/api/`, with shared helpers in `e2e/support/api.ts`. Run only HTTP API tests with `bun run test:e2e -- e2e/api`. Playwright starts a local RS256/JWKS issuer on port 3106 and Next.js on port 3105; both ports must be free. API calls use signed bearer tokens through the real verifier. Tests cover invalid authentication, pack CRUD and ownership, idempotency, request validation, device registration, sticker generation/SSE, and a completed chat workflow. The chat router uses the AI SDK's [`MockLanguageModelV3`](https://ai-sdk.dev/docs/ai-sdk-core/testing) through `generateText`, including tool validation and pricing metadata; image/video/storage use the existing deterministic service adapters. This does not evaluate model quality or contact AI Gateway.

PGlite runs the production migration journal in a freshly reset, guarded temporary directory. Workflow data lives under that directory, and `.next-e2e` isolates the test build from a running development server. The E2E environment clears subscription credentials so a local `.env` cannot enable real billing during tests. The token issuer and mock model fixtures live under `e2e/support`; E2E seed and mock selection remain disabled in production.

Real OAuth, Neon/R2, AI Gateway, Workflow observation, and Messages/iOS device behavior remain staging/device checks because they require provisioned external credentials and Apple capabilities.

### Google Analytics / Firebase

Copy the Firebase variables from `analytics.env.example` into `.env.local` or the deployment environment.
Set `NEXT_PUBLIC_ANALYTICS_ENABLED=true` before building to enable browser analytics. Public
variables are embedded at build time, so rebuild after changing them. Local and preview builds
should leave analytics disabled unless testing against a separate GA4 property.

In GA4 Admin → Data streams → the web stream `G-65JFHT2E48`, **turn off Enhanced measurement**.
The app sends its own page views on initial load and completed pathname changes; automatic
history tracking would duplicate them and automatic URL/form collection could include private
values. Query-only and hash-only changes do not count as new page views. Page locations/titles
use masked route paths; queries, fragments, referrers, IDs, handles, and message content are omitted.
Google's SDK still manages anonymous browser/session identifiers for user and engagement analytics.

Browser events: `page_view`, `web_error` (runtime errors, rejected promises, React boundaries),
and `web_log` (console log/info/warn/error severity counts, **not message text**). Error/log events
are capped at 30 per minute per page instance. Unsupported browsers or SDK failures skip reporting.

For server reporting, create a **Measurement Protocol API secret** in that same web stream and set
`GOOGLE_ANALYTICS_API_SECRET` and `GOOGLE_ANALYTICS_SERVER_ENABLED=true`. The Firebase web API key
is public configuration and cannot replace this secret. Server analytics runs independently of
the browser enable switch. `withApiAuth` records `api_request` with status/duration and `server_error`
for 5xx responses; its structured lifecycle logs emit `server_log`. Next.js instrumentation also
reports uncaught route, render, and action errors. Background workflow logs and arbitrary server
console calls remain in the hosting logs and are not automatically forwarded.

Server requests are sent after the response, with a two-second delivery timeout; reporting failure
never changes the application response. Operational events use the synthetic `server.operations`
client identity and `source=server`, not an authenticated user's identity. Filter `source=web` for
website user reports; server events are not attributed to browser sessions. GA4 is used for event
counts/trends, while existing server logs retain diagnostic detail. No raw error messages, stacks,
request bodies, credentials, or user IDs are sent by these event helpers.

Register event-scoped custom dimensions for `source`, `route`, `method`, `status_code`, `log_code`,
`log_level`, `error_kind`, and `error_type`, and a custom metric for `duration_ms` if needed in reports.
Verify browser events in GA4 Realtime after deployment. Server events may appear in standard reports
later; successful Measurement Protocol HTTP responses do not guarantee event validation. Use Google's
[validation endpoint](https://developers.google.com/analytics/devguides/collection/protocol/ga4/validating-events)
with a test property for payload diagnostics. No live GA delivery is exercised by the unit tests.
