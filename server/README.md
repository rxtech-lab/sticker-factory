# Sticker Factory server

Next.js 16 backend and read-only web library for Sticker Factory. The iOS app creates and renders stickers; this service owns authentication, private project/chat history, immutable revisions, durable AI work, and presigned Cloudflare R2 media access.

## Architecture

- `app/api/v1`: bearer-authenticated iOS and Messages APIs. Ownership always comes from the verified OAuth `sub` claim.
- `app/library`: authenticated web Library, private previews/downloads, parent-based revision comparison, read-only chat, and durable deletion.
- `lib/contracts`: strict Zod `StickerDocumentV1`, operation, event, and API envelopes shared through `fixtures/`.
- `lib/db` and `drizzle/0001_sticker_factory.sql`: Drizzle/libSQL model, active-job constraints, asset deletion guards, and immutable revision triggers.
- `workflows/sticker-generation`: Vercel Workflow generation, editing, validated animation snapshots, export publication, decision transitions, and delayed R2 deletion sweeps.
- `lib/ai`: Vercel AI Gateway adapter (`openai/gpt-image-2`, `openai/gpt-5.6`) plus deterministic local/test adapter.
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

- `POST/GET /api/v1/stickers`
- `GET/DELETE /api/v1/stickers/{id}`
- `GET/POST /api/v1/stickers/{id}/chat/messages`
- `POST /api/v1/stickers/{id}/chat/messages/{messageId}/retry`
- `POST /api/v1/stickers/{id}/revisions/{revisionId}/{accept|reject|revert}`
- `POST /api/v1/stickers/{id}/exports`
- `POST /api/v1/uploads`
- `POST /api/v1/uploads/{assetId}/complete`
- `GET /api/v1/assets/{assetId}/download`
- `GET /api/v1/jobs/{jobId}/events` (replayable SSE with `Last-Event-ID`)

The list envelope exposes an ownership-checked `systemSticker` rendition for Messages. Downloads return `{ url, expiresAt, asset }`. SSE emits only persisted schema-valid events and complete document snapshots; terminal reconnects also receive `X-Job-State` so an already-consumed terminal event is never duplicated.

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
