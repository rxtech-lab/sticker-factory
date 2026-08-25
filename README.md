# Sticker Factory

Sticker Factory is an iOS 26 sticker studio with a companion web library and a dynamic iMessage extension. AI generation and editing run on the server; the iOS app renders the allowlisted `StickerDocumentV1` contract and exports transparent PNG/GIF/APNG renditions plus opaque-background MP4.

## Workspace

- `server/` — Next.js 16 web library and bearer-authenticated API, Turso/Drizzle data layer, private Cloudflare R2 storage, Vercel Workflow jobs, and Vercel AI Gateway integration.
- `StickerGeniOS/` — Swift 6 iPhone/iPad app, RxAuthSwift sign-in, deterministic SwiftUI renderer/exporter, shared token broker, and the `StickerMessages` extension.
- `server/fixtures/` — canonical JSON fixtures shared with the Swift contract tests.

## Local setup

1. Copy `server/.env.example` to `server/.env.local` and configure the confidential web OAuth client, public iOS client allowlist, Turso, R2, Workflow, and AI Gateway.
2. In `server/`, run `bun install`, `bun run db:migrate`, and `bun run dev`.
3. The checked-in iOS build configurations use `http://localhost:3000` for Debug and `https://sticker.rxlab.app` for Release. Update the public OAuth values in `StickerGeniOS/Configuration/Base.xcconfig` when needed, or inject equivalent settings from Xcode Cloud.
4. Enable the App Group `group.app.rxlab.stickerfactory` and the shared Keychain group for both Apple targets. Enable Associated Domains with `webcredentials:rxlab.app` for the main app, add `T7GYB573Y6.app.rxlab.stickerfactory` to the public RxLab iOS client's Apple App IDs, and register `stickerfactory://oauth/callback` for that client.

The iOS client is public and must never contain an OAuth client secret. User OAuth tokens are accepted only by Sticker Factory APIs and are never forwarded to Vercel AI Gateway.

## Required deployment resources

- A confidential RxLab web OAuth client for Auth.js with `openid email profile`, and a separate public Authorization Code + PKCE iOS client with `openid`.
- A Turso database with `server/drizzle/0001_sticker_factory.sql` applied.
- A private Cloudflare R2 bucket and S3-compatible credentials.
- Vercel Workflow plus AI Gateway credentials or Vercel OIDC authentication.
- Apple App Group, shared Keychain, Associated Domains, main-app, and Messages-extension identifiers/profiles.

## Verification

From `server/`:

```sh
bun run typecheck
bun run lint
bun run test
bun run build
```

Build and test the iOS app with the `StickerGeniOS` scheme. Final Messages insertion, peel/drag, system-wide Stickers, token sharing, and adaptive `<500 KB` renditions must also be verified on a physical iOS 26 device with production entitlements.

Personal-photo uploads are private project references. The product UI discloses their use before upload; project deletion starts the durable database and object-storage purge.
