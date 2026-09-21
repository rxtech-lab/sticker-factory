# Sticker Factory App Clip

## Implemented flows

- `https://sticker.rxlab.app/share/ios`: RxLab sign-in, static quick generation from text and an optional photo, revision, and PNG sharing.
- `https://sticker.rxlab.app/share/ios/packs/{slug}`: public published/unlisted pack preview. Install opens `https://apps.apple.com/app/id6805825708`.
- Installed full apps handle the same URLs: normal point-billed quick mode, or the matching marketplace pack.
- Library toolbar and marketplace pack detail share these canonical URLs.
- The App Clip uses iOS 26, bundle ID `app.rxlab.stickerfactory.Clip`, and the existing distribution team `T7GYB573Y6`.

## Backend deployment order

1. Use the deployed RxSubscription `GET /api/v1/entitlements` and `POST /api/v1/usage` APIs. No RxSubscription code change or migration is required.
2. Use the existing Sticker Factory application's `quick_mode_allowance` usage item and its configured plan or per-user allowance. The server reads the limit, remaining usage, and reset time from RxSubscription; it does not hard-code a limit or create another usage item. Configure reset and overage policy in RxSubscription. Paid plans should grant this same item if they offer quick-mode allowance.
3. Apply Sticker Factory migration `0003_cuddly_wendell_vaughn` and deploy the Sticker Factory server. Retain `RX_SUBSCRIPTION_URL` and the server-only `RX_SUBSCRIPTION_API_KEY` for the same existing application/environment. Neither the App Clip nor the website receives this secret.
4. The App Clip and main app use the same public OAuth authorization-code/PKCE client, issuer, token endpoint, `stickerfactory://oauth/callback`, and `openid` scope. Both targets read their OAuth settings from `Configuration/Base.xcconfig`. Clip credentials remain in its own keychain service. No separate OAuth registration is required. The App Clip uses the main app's native sign-in component in a sheet with interactive dismissal disabled; Close/Done in the toolbar controls dismissal.
5. Archive the full app with the embedded App Clip. Archive validation checks the shared `STICKER_FACTORY_IOS_CLIENT_ID`.

Quick mode sends `useQuickModeAllowance: true` on creation and revision. This selects the account's plan allowance, not an authenticated device identity. Any authenticated client can request this constrained operation; the server enforces static quick generation/revision and records one attempt before creating its job. Ordinary requests retain point billing. The App Clip allowance endpoint accepts the shared OAuth identity. Leave `APP_CLIP_OAUTH_CLIENT_ID` unset for this setup: it is only a legacy dedicated-client restriction and must not be set to the shared main-app client ID.

## Usage lifecycle

`POST /api/v1/usage` records one attempt against the account's backend-resolved allowance, including per-user overrides. Its `allowed` response gates job creation. The job ID is sent as the usage idempotency key. Sticker Factory does not call usage-reservation, usage-commit, or usage-release endpoints.

Accounts with only the `free` plan (or no plan) do not spend points. If RxSubscription returns any non-free plan, Sticker Factory first holds points through the existing balance reservation API, then records usage. Insufficient points therefore does not consume an attempt. A rejected usage request releases the point hold. Successful jobs settle the actual API-priced cost; failed or cancelled jobs release the point hold. Accepted attempts remain counted even if generation or job creation later fails, because the existing usage API does not provide usage refunds.

The Clip bills as the full app. Its StoreKit proof carries `app.rxlab.stickerfactory.Clip`, and the server accepts that identifier for the full app's App Store record whichever OAuth client signed the token. It uses the same sandbox/production billing keys and points balance as the full app.

Generation and automatic publication are separate durable steps within one operation. A publication retry does not redraw or record another attempt. Closing the App Clip leaves the job running; its pending job is restored on reopening. Pending HTTP requests retain their idempotency key through lost responses and are scoped to the signed-in account. Point settlement failures retain their reservation ID on the Sticker Factory job for reconciliation.

## Apple registration

- Enable the App Clip/parent capabilities and regenerate signing profiles for both identifiers.
- The Clip entitlement uses `appclips:sticker.rxlab.app`; the full app uses `applinks:sticker.rxlab.app`.
- Verify `https://sticker.rxlab.app/.well-known/apple-app-site-association` returns JSON publicly without an authentication redirect. `APPLE_APP_TEAM_ID` overrides the default team prefix if the distribution team changes.
- In App Store Connect app **6805825708**, configure the App Clip experience for the `/share/ios` invocation prefix, its card artwork and text, and the pack-specific descendant URLs.
- Shared links present Apple's card/banner where supported. They cannot force every browser or messaging app to launch a clip automatically. Unsupported browsers receive the public landing page and App Store link.

## Validation

- Server: `bun run typecheck`; `bun run test tests/unit/app-clip.test.ts tests/unit/workflow-dispatch.test.ts tests/unit/quick-publish.test.ts tests/unit/subscription-credits.test.ts tests/unit/auth-bearer.test.ts`.
- Xcode: build `StickerAppClip`, `StickerGeniOS`, and `StickerMessages`; run `StickerShareRouteTests`. The existing Messages test target uses an `.appex` test host, which Xcode cannot execute; its shared sources are build-checked. The new clip shares the existing creation transport and event watcher.
- Set `_XCAppClipURL` to either canonical URL for local invocation tests. Use a physical-device local experience/TestFlight to check sign-in, the configured attempt allowance and refusal at its limit, share/export, and pack preview/install. Check archived size using Xcode's distribution size report.
- Public Safari/Messages discovery requires an approved and released App Clip and validated domain association. These live checks are separate from local builds.

### App Clip URL UI tests

The shared `StickerAppClip` scheme includes `StickerAppClipUITests`. Run from `StickerGeniOS`:

```sh
xcodebuild -project StickerGeniOS.xcodeproj -scheme StickerAppClip \
  -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

The suite opens URLs with `XCUIApplication.open(_:)`, exercising the actual app URL handlers and rendered screens. It covers launch without a URL, quick-mode and pack links, query strings/fragments/trailing slashes, uppercase hosts and explicit HTTPS ports, successive launches for different packs and quick mode, missing packs/retry, and rejected schemes/hosts/ports/credentials/paths. XCTest relaunches the Clip for each URL; preserving the current screen after an invalid warm invocation remains a device check.

Only Debug builds launched with `--ui-testing` skip restoring saved credentials and use a local URLSession protocol for public pack responses. Tests exercise response decoding, pack titles/creator/sticker rows, and the share/install controls without an account or backend. Fixtures contain no remote image URLs; these URL tests do not validate animated image rendering, generation quotas, App Store handoff, or Apple's public domain discovery. A separate sign-in test opens the same native `RxSignInView` form used by the main app, selects password sign-in, verifies the credential fields, attempts a swipe dismissal, and closes/reopens using the toolbar. The sheet stays open after successful authentication until Done is tapped. Completing OAuth with a real account remains a device check. `_XCAppClipURL` remains useful for manual Xcode local invocation, but the automated suite uses XCTest's URL API because the launch environment alone does not deliver a browsing activity under the UI test runner.

The signed-out welcome does not advertise a fixed generation count. After sign-in, quick mode fetches `quick_mode_allowance` from the server and displays its actual limit, remaining count (or unlimited), and reset time.

Quick-mode display and charging policy come from `GET /api/v1/entitlements`, including its resolved `usage` array. Only explicit `limit: null` and `remaining: null` mean unlimited; missing or inconsistent fields fail closed. An unlimited allowance does not waive non-free-plan point charges. For a mismatched count, verify the `quick_mode_allowance` item, authenticated RxLab user ID, and application/environment selected by the Sticker Factory server secret key; changing a different meter or environment does not change this allowance.

A missing `quick_mode_allowance` item is surfaced as `APP_CLIP_USAGE_NOT_CONFIGURED` (503). Sticker Factory rolls back the unstarted sticker while preserving reference uploads and permits the same request key to retry after configuration is corrected. Ambiguous failures retain their lock to avoid duplicate generation. Pending keys from older code keep their original expiry.
