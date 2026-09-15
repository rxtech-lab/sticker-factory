# Sticker generation Live Activity

The app starts a Live Activity when a generation is accepted. A new generation replaces the previous activity, so simultaneous jobs show the most recently started generation. Reconnecting an older chat does not take over the activity. The card shows the newest status message, using the same tool labels as the chat.

Measurable stages show a completed/total count and progress bar on the Lock Screen and expanded Dynamic Island. Composition counts successfully prepared artwork parts (for example, 1/10), video clips, sprite sheets, and generated expression/pose variants, with an initial 0/total event before each phase starts; layout review counts the configurations checked in the current review pass (for example, 1/6). A layout adjustment resets review progress because the new layout must be checked again. Intervening tool messages retain the active stage's count, but stage transitions explicitly clear it. Compact mode shows the current action with the count when available, or elapsed time when there is no measurable progress. Both foreground events and server pushes carry the same counters and clear transitions. Optional progress fields remain compatible with older payloads and require no additional database migration.

The chat screen draws from the same events while it is open, split between two places so neither repeats the other. The navigation bar's title chip carries the status: the live phase, falling back to the server's `stage` before the generic "Working…". The transcript's `AssistantWorkingCard` replaces the bare typing dots with the turn's meter — the newest `note`, an elapsed clock, tokens written, images drawn, clips filmed, and the stage's count and bar when it has one.

Stage wording lives in `StickerToolLabel.stages` and is mirrored by `stageLabels` in `server/lib/notifications/live-activities.ts`, so the Lock Screen and the foreground never word the same stage differently.

Notes (`reportTurnNote`) now update the Live Activity as well as the chat, so the status can advance inside a long stage. Count-only and clear-progress events also advance the snapshot version without dropping its newest text. All job kinds can expose stage counts. The app opts into frequent Live Activity updates; iOS and user settings still control delivery.

Token counts (`reportAiStepUsage` through `withAiStepUsageReporter`) and image/clip counts (`reportTurnWork`) remain app-only events with `pushLiveActivity: false`. These counts are deltas summed by the client; duplicate or older event IDs are ignored so reconnects cannot inflate the meter. The dots card also counts completed tool steps from the current job's transcript, excluding overall phase rows and previous jobs. If no note is available it shows the active tool or last completed tool. Text matching the title status is suppressed, and a new stage or tool event clears the preceding note so it cannot linger into unrelated work.

- Lock Screen: sticker title, current status, and a stale-update indicator.
- Dynamic Island: status and title in the expanded view; compact/minimal system-sized indicators.
- Tapping opens the matching sticker through the existing deep link.
- Completion, failure, and cancellation end the activity, leaving the final message for two minutes. Replacement and sign-out dismiss immediately.
- Candidate and document events do not end an activity: generation may still be working.

## App and server updates

`GenerationLiveActivityManager` requests an ActivityKit push token independently of notification-banner permission. Foreground event streams update the activity directly. The app also fetches `GET /api/v1/live-activities?jobId=…` immediately and every five seconds while active, independently of push-token registration. Failed checks back off to a maximum of 30 seconds and return to five seconds after success. Foreground entry triggers an immediate catch-up; background entry, completion, replacement, and sign-out stop the polling loop. The endpoint is authenticated, owner-scoped, uncached, and read-only. iOS does not allow the Live Activity extension to fetch the network itself or guarantee periodic app execution while suspended, so background updates still use APNs.

Tokens are uploaded to the authenticated `/api/v1/live-activities` endpoint and retried after transient failures and on foreground entry. The response catches up the local state even if the job finished before the token arrived.

The server sends ActivityKit `update` and `end` events through the existing APNs HTTP/2 transport, using the app's bundle ID plus `.push-type.liveactivity`. Each token belongs to a specific activity and generation; notification device tokens are never reused for this purpose. Progress uses normal APNs priority, terminal updates use immediate priority. Per-job serialization and event IDs suppress duplicate/out-of-order server sends. Tokens are owner-scoped, expire after eight hours, and are removed when the activity ends or APNs rejects them permanently.

This uses app-started activities with remote updates, not remote push-to-start. A generation must first be started or opened in the main app while it is active. The Messages extension and App Clip do not create their own Live Activities. Updates remain best-effort and are subject to iOS authorization, delivery budgets, and system presentation limits. After three minutes without updates, the UI identifies the last message as stale.

## Deployment

1. Apply server migration `0010_generation_live_activities` before deploying the new server routes/workflow code.
2. Use the existing `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, and `APNS_BUNDLE_ID` configuration. `APNS_BUNDLE_ID` is the main app ID, `app.rxlab.stickerfactory`. Do not set it to the widget extension ID. The key must permit the Live Activity topic.
3. Keep sandbox and production environments aligned. Debug requests sandbox tokens; Release/TestFlight uses production. The optional existing `APNS_ENVIRONMENT` setting overrides token environments.
4. Provision and embed the new `app.rxlab.stickerfactory.generation-activity` widget extension for distribution. The main app retains its existing push entitlement and now declares `NSSupportsLiveActivities`.

No credentials were changed and no database migration or deployment was performed as part of this code change. Live delivery requires a signed physical-device build and a configured server.

## SwiftUI previews

Open `StickerGenerationActivity.swift` with the `StickerGenerationActivity` scheme selected. The previews cover Lock Screen progress and terminal states, expanded/compact/minimal Dynamic Island, and a stale update. Composition previews include 0/10, 1/10, and 10/10. Review previews cover its counter on the Lock Screen and Dynamic Island, followed by finalization with the timer restored. The widget target is embedded in the main app and shares only its ActivityAttributes contract with it.

Apple reference: [Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

## Missing counters on an existing generation

A durable generation step that is already running retains the workflow implementation it started with. Updating the app or refreshing the dev server does not add counters to old events. Use the updated app and server for a new generation to receive the new stage counters. Earlier `completedParts`/`totalParts` fields are accepted by both the app and push snapshot; still older events that contain no completed count keep the timer rather than inventing progress.
