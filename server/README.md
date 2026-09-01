# Sticker Factory server

Next.js 16 backend and read-only web library for Sticker Factory. The iOS app creates and renders stickers; this service owns authentication, private project/chat history, immutable revisions, durable AI work, and presigned Cloudflare R2 media access.

## Architecture

- `app/api/v1`: bearer-authenticated iOS and Messages APIs. Ownership always comes from the verified OAuth `sub` claim.
- `app/library`: authenticated web Library, private previews/downloads, parent-based revision comparison, read-only chat, and durable deletion.
- `lib/contracts`: strict Zod `StickerDocumentV1`, operation, event, and API envelopes shared through `fixtures/`.
- `lib/db` and `drizzle/0001_sticker_factory.sql`: Drizzle/libSQL model, active-job constraints, asset deletion guards, and immutable revision triggers.
- `workflows/sticker-generation`: Vercel Workflow generation, editing, validated animation snapshots, export publication, decision transitions, and delayed R2 deletion sweeps.
- `lib/ai`: Vercel AI Gateway adapter (`AI_IMAGE_MODEL` for every image generation/edit and
  `AI_ORCHESTRATOR_MODEL` for chat, routing, planning, review, and animation) plus a deterministic
  local/test adapter.
- `lib/storage`: private R2 S3-compatible storage, signed URLs, checksum/media/transparency verification, and bounded image decoding.

OAuth access tokens are verified against RxLab JWKS and are never forwarded to Vercel AI Gateway. Turso transcripts/revisions and private R2 assets are the recoverable AI context; provider conversation state is not the source of truth.

## Local setup

Requires Bun 1.3+ and native Sharp support.

```bash
bun install
cp .env.example .env.local
bun run db:migrate
bun run dev
```

For a local AI-free environment, set `STICKER_FACTORY_MOCK_SERVICES=true`; jobs still run through the local Vercel Workflow runtime. Never enable mock services in production. Missing OAuth, AI, Turso, or R2 secrets do not prevent a production build; the corresponding runtime operation returns a configuration error.

Production needs separate RxLab OAuth clients:

- confidential web client for `@rxtech-lab/authjs-rxlab@1.6.1`, including the registered Auth.js callback;
- public iOS PKCE client `client_1ce3e6efd6da4214a61df67949a71622`, configured as `IOS_OAUTH_CLIENT_ID` (no client secret), plus any staged clients in `RXLAB_ALLOWED_CLIENT_IDS`.

Configure Turso, a private R2 bucket, Vercel AI Gateway (API key or Vercel OIDC), and Vercel Workflow. Apply the SQL migration before serving traffic.

## API v1

All state-changing endpoints require `Idempotency-Key`. JSON bodies are content-type checked and limited to 1 MB. AI inputs, uploads, layers/keyframes, and event replay have independent bounds.

- `POST/GET /api/v1/stickers` — the authenticated list accepts `?q=&cursor=` for title search
- `POST /api/v1/stickers/import` — turns an image the client already has into a static sticker with an accepted, active root revision, generating nothing
- `GET/PATCH/DELETE /api/v1/stickers/{id}` — `PATCH` renames an owned live sticker
- `GET/POST /api/v1/stickers/{id}/chat/messages`
- `POST /api/v1/stickers/{id}/chat/messages/{messageId}/retry`
- `POST /api/v1/stickers/{id}/revisions` — saves a client-edited document as a new accepted revision
- `POST /api/v1/stickers/{id}/revisions/{revisionId}/{accept|reject|revert}`
- `POST /api/v1/stickers/{id}/exports`
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
- `install_count`/`item_count` are trigger-maintained. SQLite skips row triggers for FK-cascade deletes, so `bun run db:packs:recount` reconciles them.

## Push notifications

A finished turn is announced from here, not from the phone. Generation runs on the server and the
client's SSE stream dies the moment iOS suspends the app — which is exactly the case a "your sticker
is ready" banner exists for — so the local notification it used to post could only ever fire for a
turn the user was still watching.

- `lib/notifications/apns.ts` talks to APNs over `node:http2` with a token-based (`.p8`) provider
  JWT. HTTP/2 is the only transport APNs accepts and `fetch` will not negotiate it, which is the
  whole reason the file is not a thin wrapper. Provider tokens are cached for 45 minutes, inside
  Apple's one-hour validity and well clear of `TooManyProviderTokenUpdates`.
- `completeJobStep`/`failJobStep` push after the terminal transition commits, so a step that re-runs
  over an already-finished job cannot announce it twice. Cleanup and export jobs stay silent.
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

## Media and deletion invariants

- Private source/output assets use internal UUID references only.
- Source revision fields are DB-trigger immutable; export renditions are separate mutable relations.
- Static publication requires a rendered transparent PNG and a `<500,000` byte system rendition.
- Animated publication verifies real GIF/MP4/system timing against the accepted cycle, including doubled `pingPong` duration.
- Masks must match the target image format/dimensions and contain both transparent and painted alpha pixels.
- Deletion marks a tombstone, blocks new asset binding, deletes known objects, waits past signed-PUT expiry, sweeps again, then cascades Turso rows.

Personal photos, masks, transcripts, sources, and immutable revisions remain private until project deletion. Web and iOS upload UI must show this disclosure before personal-photo upload.

## Verification

```bash
bun run typecheck
bun run test
bun run lint
bun run test:e2e
bun run build
```

Vitest covers contracts, bearer claims, refresh failure, services, revisions, idempotency, storage verification, SSE, and Workflow snapshots. Playwright uses a guarded temporary libSQL database and mock-auth/service harness; its seed endpoint is unavailable in production.

Real OAuth, Turso/R2, AI Gateway, Workflow observation, and Messages/iOS device behavior remain staging/device checks because they require provisioned external credentials and Apple capabilities.
