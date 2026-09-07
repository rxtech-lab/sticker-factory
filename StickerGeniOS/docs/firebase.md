# Firebase Analytics, Crashlytics and In-App Messaging

The main StickerGeniOS target bundles GoogleService-Info.plist for
app.rxlab.stickerfactory in the winky-sticker-factory Firebase project.
App Clip and Messages extension do not link Firebase or use this main-app plist.

Firebase is configured at main app startup. Collection is off in Info.plist,
then enabled for ordinary launches. UI tests, unit tests and previews skip
Firebase initialization. Debug launches are tagged build_channel=debug; release
launches use release. Automatic session, engagement and app lifecycle measurement
comes from Analytics. SwiftUI screens are logged manually to avoid UIKit host
screen names.

FirebaseAnalyticsCore excludes advertising identity support. IDFV collection and
ad personalization signals are disabled. No account IDs are assigned. Custom
events exclude prompts, search terms, titles, image bytes, URLs and tokens.
Non-fatal reports replace raw errors with an operation name, category and code.
Crashlytics still collects its standard crash diagnostics and installation data.

## Event coverage

- screen_view: sign-in, library, marketplace, account, creation, chat, pack detail.
- tab_selected, login, logout, tutorial_complete, deep_link_opened.
- search_completed: surface and first-page result count, after debounce.
- workflow_started/completed/failed/cancelled: operation and completion duration
  for sticker creation/import, chat/retry, plan confirmation/rejection, stopping,
  document saving, revision actions, pack creation/editing/publishing/deletion,
  and purchase restoration.
- generation_result: server completion/failure events seen live by the app.
  Workflow completion means the method returned; it does not imply the remote
  generation has finished. Jobs completed while the app is absent may not emit
  this event, so it is not a server-wide generation accounting source.
- sticker_renamed/deleted and pack_installed/uninstalled: successful changes.
- paywall_viewed: user-opened or server refusal.
- export_started/completed, publish_submitted; share: messenger hand-off only,
  not confirmation that the user installed the pack in the other app.

The subscription SDK owns purchases. No custom purchase/revenue event is emitted
on paywall dismissal; that would incorrectly count cancellations as purchases.

## Console setup and verification

The supplied plist contains IS_ANALYTICS_ENABLED=false. The app explicitly
enables SDK collection, but cannot link a Google Analytics property for the
Firebase project. Check Firebase Project settings > Integrations and enable
Google Analytics if it is not linked. Enable Crashlytics for the registered app.

1. Build and launch the main app with -FIRDebugEnabled in the Xcode scheme.
   Exercise navigation, creation, searches, and an export; inspect Analytics
   DebugView. Remove the launch argument after verification.
2. For Crashlytics acceptance, use a temporary local test-crash button as described
   in Firebase's guide. Launch once, detach the debugger, trigger the crash, then
   relaunch without the debugger to upload. Confirm the crash and symbolicated
   stack in the console; remove the temporary button. No deliberate crash control
   is shipped in this app.
3. Device builds generate dSYMs and invoke the final Upload Crashlytics symbols
   phase. Simulator builds skip uploading. The script supports Xcode's standard
   package path and STICKER_FACTORY_PACKAGE_ROOT used by repository build scripts.
   Compile-only validation can set STICKER_FACTORY_SKIP_CRASHLYTICS_UPLOAD=YES;
   ordinary device builds keep upload enabled.
4. Review App Store Connect privacy answers and the published privacy policy for
   Analytics product interaction/usage data and Crashlytics diagnostics before
   distributing a release. Firebase dependencies bundle their SDK privacy
   manifests; those do not replace the app's store disclosures.

References:
- https://firebase.google.com/docs/analytics/get-started?platform=ios
- https://firebase.google.com/docs/crashlytics/ios/get-started
- https://firebase.google.com/docs/analytics/debugview

## In-App Messaging

The main app links the FirebaseInAppMessaging-Beta Swift package product from
the existing Firebase SDK. This includes Firebase's standard message display UI.
Startup enables In-App Messaging after the same test/preview guards as Analytics.
FirebaseInAppMessagingAutomaticDataCollectionEnabled is false in Info.plist until
that startup code runs. No separate Firebase configuration file is required.

Create campaigns in the Firebase console under Messaging > In-App Messaging,
targeting the registered main iOS app. Google Analytics must be enabled for the
Firebase project. Campaigns can use existing Analytics events such as
pack_installed or tutorial_complete as display triggers. Firebase handles
campaign impressions, clicks and dismissals; no duplicate custom campaign
events are emitted by the app.

For device verification, launch with -FIRDebugEnabled, find the Firebase
Installation ID in the In-App Messaging startup log, and use Test on Device in
the campaign editor. Close and reopen the app to fetch/display the test campaign.
Remove the debug argument afterward. SDK integration alone does not create or
publish a campaign; console delivery remains a separate acceptance check.

Reference: https://firebase.google.com/docs/in-app-messaging/get-started?platform=ios
