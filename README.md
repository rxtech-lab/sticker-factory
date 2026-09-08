# Sticker Factory

Sticker Factory is an iOS 26 sticker studio with a companion web library and two dynamic iMessage apps. AI generation and editing run on the server; the iOS app renders the allowlisted `StickerDocumentV1` contract and exports transparent PNG/GIF/APNG renditions plus opaque-background MP4.

## Workspace

- `server/` — Next.js 16 web library and bearer-authenticated API, Neon Postgres/Drizzle data layer, private Cloudflare R2 storage, Vercel Workflow jobs, and Vercel AI Gateway integration.
- `StickerGeniOS/` — Swift 6 iPhone/iPad app, RxAuthSwift sign-in, deterministic SwiftUI renderer/exporter, shared token broker, and both Messages extensions.
- `server/fixtures/` — canonical JSON fixtures shared with the Swift contract tests.

## WhatsApp and Telegram

Any pack under the **Sticker Packs** tab can be sent to WhatsApp or Telegram from its pack screen.
The pack is cut to the messenger's rules on the phone — one kind per pack, split evenly past the
cap — and every sticker is re-encoded at 512 px: WebP for WhatsApp, PNG or transparent VP9 WebM for
Telegram. See `docs/messenger-export.md`. The VP9 encoder is `StickerGeniOS/packages/VP9Encoder`
(libvpx, rebuilt by its `scripts/build-libvpx.sh`); the WhatsApp hand-off is
`StickerGeniOS/packages/WASticker`.

## The two Messages apps

iOS permits only one `com.apple.message-payload-provider` extension per containing app — a second
one inside the same app fails at install with *"Multiple message payload provider extensions found
in app but only one is allowed"*. That check runs in device-side `installd`, so `xcodebuild` and
the simulator both pass and only a physical device or App Store upload catches it. WinkySticker
therefore ships as its own Messages-only containing app.

| | `StickerGeniOS.app` → `StickerMessages.appex` | `WinkySticker.app` → `WinkyStickerMessages.appex` |
|---|---|---|
| Sends | `MSSticker` via `insert(_ sticker:)` | attachment via `insertAttachment` |
| Size | ≤500 KB, square, one of 300/408/618 px | Large 618 / Medium 408 / Small 300, chosen per send, no byte ceiling |
| Frame rate | whatever fits 500 KB — as low as 4 fps | the document's own, at every size |
| Peelable | yes | no — it is an ordinary image message |
| Contexts | Messages **and** Media | Messages only |
| `NSStickerSharingLevel` | `OS` | *absent, deliberately* |
| Appears in | iMessage drawer, system Stickers app, FaceTime, Markup | iMessage drawer only |

The size row is the whole difference. `insert(_ sticker:)` forces every rendition through Apple's
500 KB ceiling, and `SystemStickerPreset.adaptive` pays for it by spending frame rate before pixels —
618@24 down to 300@4 — so dense artwork arrives visibly choppy. `insertAttachment` has no such
ceiling, so WinkySticker's three sizes differ only in how many pixels they have. A segmented control
above the grid picks between them, and the choice is remembered in the app group.

Size is therefore a **send-time** decision. The export sheet used to ask it once per publish and bake
the answer into the `system` rendition; a publish now renders all three and the question is asked
where the answer is actually known.

`WinkySticker` uses product type `com.apple.product-type.application.messages`, which injects
`LSApplicationLaunchProhibited` and supplies the app binary itself — so it has no Home Screen icon,
no source files, and no Sources build phase. It cannot sign in on its own: it reads the tokens
Sticker Factory wrote to the shared keychain, so **Sticker Factory must be installed and signed
in**.

WinkyStickerMessages omits `NSStickerSharingLevel` and the media context on purpose. In the
system Stickers app, FaceTime and Markup, `insert(_ sticker:)` is the only unrestricted insertion
API and some of those hosts have no `MSConversation` at all, so an entry there would fail on tap.

Both extensions compile the same `StickerMessages/` sources — the folder is a synchronized group in
both targets, with a per-target exception set excluding `MessagesViewController.swift`,
`StickerBrowserViewController.swift`, `Assets.xcassets` and `Info.plist` from the WinkySticker build.

Regenerate either extension's drawer icon with
`scripts/generate-imessage-icon.swift [--icon <name>.icon] [--target <folder>]`. The two currently
share artwork; give WinkySticker its own `.icon` document before submitting, since the two sit
side by side in the drawer.

### Shared app-group caches

Both live under `group.app.rxlab.stickerfactory` in `Library/Caches/`, and `SharedLogoutPurger`
clears both on sign-out:

- `StickerFactoryMessages` — the ≤500 KB Messages renditions. Also backs WinkySticker's
  thumbnails.
- `StickerFactoryMessagesFull` — the attachment renditions, fetched lazily on tap and LRU-trimmed to
  150 MB. One entry per sticker *per size*, keyed by `CacheKey.variant`.

## Renditions a publish uploads

| Asset kind | What it is | Read by |
|---|---|---|
| `master` | 1024² PNG, static stickers only | web library, marketplace, WinkySticker's Large |
| `apng` | 618 px animated PNG at the document's frame rate | web library, marketplace, WinkySticker's Large |
| `attachment` | the same artwork at 408 and 300 px | WinkySticker's Medium and Small |
| `system` | ≤500 KB, 300/408/618 px, frame rate spent to fit | `StickerMessages` only |
| `mp4` | 1024² opaque video | share sheet, when asked for |

Large has no column of its own on `sticker_revisions` — it *is* the sharing rendition. Only
`attachment_medium_asset_id` and `attachment_small_asset_id` were added. A sticker published before
they existed carries neither, and WinkySticker walks *up* `StickerAttachmentSize.fallbackChain` to
the largest size it does have rather than refusing to send.

`SHARING_APNG_DIMENSIONS` in `server/lib/contracts/sticker.ts` and `sharingApngDimensions` in
`StickerExporter.swift` walk the same ladder. The server list keeps 1024/768/512/384/256 alongside
the current rungs so revisions published before the switch to 618 still re-validate.

## Local setup

1. Copy `server/.env.example` to `server/.env.local` and configure the confidential web OAuth client, public iOS client allowlist, `DATABASE_URL`, R2, Workflow, and AI Gateway.
2. In `server/`, run `bun install`, `bun run db:migrate`, and `bun run dev`.
3. The checked-in iOS build configurations use `http://localhost:3000` for Debug and `https://sticker.rxlab.app` for Release. Update the public OAuth values in `StickerGeniOS/Configuration/Base.xcconfig` when needed, or inject equivalent settings from Xcode Cloud.
4. Enable the App Group `group.app.rxlab.stickerfactory` and the shared Keychain group for all four Apple targets — `app.rxlab.stickerfactory`, `…​.message`, `app.rxlab.stickerfactory.winkysticker` and `…​.winkysticker.message`. A missing App Group surfaces at runtime as `StickerCacheError.appGroupUnavailable`, which reads like a sign-in bug. Enable Associated Domains with `webcredentials:rxlab.app` for the main app, add `T7GYB573Y6.app.rxlab.stickerfactory` to the public RxLab iOS client's Apple App IDs, and register `stickerfactory://oauth/callback` for that client.

The iOS client is public and must never contain an OAuth client secret. User OAuth tokens are accepted only by Sticker Factory APIs and are never forwarded to Vercel AI Gateway.

## Required deployment resources

- A confidential RxLab web OAuth client for Auth.js with `openid email profile`, and a separate public Authorization Code + PKCE iOS client with `openid`.
- A Neon Postgres database with `bun run db:migrate` applied.
- A private Cloudflare R2 bucket and S3-compatible credentials.
- Vercel Workflow plus AI Gateway credentials or Vercel OIDC authentication.
- Apple App Group, shared Keychain, Associated Domains, and identifiers/profiles for the main app, its Messages extension, and the separate WinkySticker app and extension. `WinkySticker` is a second App Store product; once shipped with `LSApplicationLaunchProhibited`, its bundle id can never be reused for a regular iOS app.

## Verification

Both linters run from the repository root, the same way CI runs them:

```sh
make lint       # SwiftLint over the iOS sources, then ESLint over the server
make lint-fix   # apply what either linter can correct on its own
```

Both are configured with the same structural rule: **no source file over 800 lines**, counting
neither blank lines nor comments — SwiftLint's `file_length` in `StickerGeniOS/.swiftlint.yml`, and
ESLint's `max-lines` in `server/eslint.config.mjs`.

SwiftLint's version is pinned in `StickerGeniOS/.swiftlint-version`, and `make lint-ios` refuses to
run against any other one. Its rules and their options change between releases — 0.63 narrowed what
`line_length`'s `ignores_function_declarations` exempts, and 0.65 added new rules — so an unpinned
linter reports a different set of violations locally than it does in CI. To move to a newer release,
bump that file and fix whatever it reports.

The rest, from `server/`:

```sh
bun run typecheck
bun run test
bun run build
```

Build and test the iOS app with the `StickerGeniOS` scheme; build WinkySticker with the `WinkyStickerMessages` scheme. Note `scripts/ios-test.sh` does not execute `StickerMessagesTests` — an `.appex` is not a valid `TEST_HOST`, so those contract tests are compile-checked only.

The following must be verified on a physical iOS 26 device with production entitlements:

- **Before anything else:** that `WinkySticker` installs at all. The one-payload-provider-per-app rule is enforced by `installd`, so the simulator cannot catch a regression here.
- Both apps appear in the iMessage drawer; only Sticker Factory appears in the system Stickers app, FaceTime, the emoji keyboard and Markup.
- Each of Large / Medium / Small sends, and the received image saves at 618 / 408 / 300 — check the saved file's dimensions rather than eyeballing the bubble.
- **That the three arrive at visibly different sizes at all.** Messages' sizing rule for image attachments is not something `xcodebuild` or the simulator can confirm. If all three render at one bubble width, the size set is a one-line change to `StickerAttachmentSize` and needs no migration — which is why the sizes live in one enum.
- A sticker published *before* attachment renditions still sends at every setting, silently falling back to Large.
- The size control's choice survives closing and reopening the drawer.
- Animated stickers arrive animated **and smooth** at every size — none of the three is under the 500 KB ceiling, so none of them should be choppy the way the `StickerMessages` sticker can be.
- A sticker whose `previewAsset` falls back to the system asset still sends without error.
- Peel/drag is inert in WinkySticker.
- Signing out of Sticker Factory purges both caches and WinkySticker prompts to sign in.
- In airplane mode the grid still renders from cache; an uncached tap explains itself and sends nothing.
- Messages insertion, peel/drag, system-wide Stickers, token sharing, and adaptive `<500 KB` renditions in the original extension.

Personal-photo uploads are private project references. The product UI discloses their use before upload; project deletion starts the durable database and object-storage purge.
