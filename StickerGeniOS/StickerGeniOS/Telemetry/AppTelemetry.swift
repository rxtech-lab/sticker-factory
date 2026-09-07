import FirebaseAnalytics
import FirebaseCore
import FirebaseCrashlytics
import FirebaseInAppMessaging
import Foundation
import SwiftUI

/// Only fixed event names and categorical/count parameters belong here.
/// Never send prompts, search terms, titles, URLs, user IDs, or raw errors.
@MainActor
enum AppTelemetry {
    enum Operation: String {
        case createSticker = "create_sticker"
        case importSticker = "import_sticker"
        case sendMessage = "send_message"
        case retryMessage = "retry_message"
        case confirmPlan = "confirm_plan"
        case cancelPlan = "cancel_plan"
        case stopGeneration = "stop_generation"
        case saveDocument = "save_document"
        case revisionAction = "revision_action"
        case createPack = "create_pack"
        case updatePack = "update_pack"
        case setPackItems = "set_pack_items"
        case publishPack = "publish_pack"
        case unpublishPack = "unpublish_pack"
        case deletePack = "delete_pack"
        case restorePurchases = "restore_purchases"
    }

    private static var isEnabled = false

    static func configure() {
        let process = ProcessInfo.processInfo
        guard !process.arguments.contains("--ui-testing"),
              process.environment["XCTestConfigurationFilePath"] == nil,
              process.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              NSClassFromString("XCTestCase") == nil else { return }
        guard !isEnabled else { return }
        FirebaseApp.configure()
        // Defaults in Info.plist keep collection off until test/preview guards have run.
        Analytics.setAnalyticsCollectionEnabled(true)
        InAppMessaging.inAppMessaging().automaticDataCollectionEnabled = true
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(true)
        isEnabled = true
        #if DEBUG
        Analytics.setUserProperty("debug", forName: "build_channel")
        #else
        Analytics.setUserProperty("release", forName: "build_channel")
        #endif
    }

    static func event(_ name: String, parameters: [String: Any] = [:]) {
        guard isEnabled else { return }
        Analytics.logEvent(name, parameters: parameters)
        Crashlytics.crashlytics().log(name)
    }

    static func screen(_ name: String) {
        event("screen_view", parameters: ["screen_name": name, "screen_class": name])
        guard isEnabled else { return }
        Crashlytics.crashlytics().setCustomValue(name, forKey: "screen")
    }

    static func measure<T>(_ operation: Operation, body: () async throws -> T) async rethrows -> T {
        let start = Date()
        event("workflow_started", parameters: ["operation": operation.rawValue])
        do {
            let result = try await body()
            event("workflow_completed", parameters: [
                "operation": operation.rawValue,
                "duration_ms": Int(Date().timeIntervalSince(start) * 1_000)
            ])
            return result
        } catch {
            if StickerStore.isCancellation(error) {
                event("workflow_cancelled", parameters: ["operation": operation.rawValue])
            } else {
                failure(error, operation: operation.rawValue)
            }
            throw error
        }
    }

    static func failure(_ error: Error, operation: String) {
        guard isEnabled, !StickerStore.isCancellation(error) else { return }
        // Domain/message/userInfo can include server text, URLs and credentials.
        // Preserve only a safe category and numeric code in the non-fatal report.
        let category = error is URLError ? "network" :
            error.subscriptionRefusal != nil ? "subscription_refusal" : "application"
        event("workflow_failed", parameters: ["operation": operation, "category": category])
        guard category != "subscription_refusal" else { return }
        Crashlytics.crashlytics().record(error: sanitizedError(error, operation: operation, category: category))
    }

    static func sanitizedError(_ error: Error, operation: String, category: String) -> NSError {
        NSError(
            domain: "app.rxlab.stickerfactory.\(operation)",
            code: (error as NSError).code,
            userInfo: [NSLocalizedDescriptionKey: category]
        )
    }
}

extension View {
    func telemetryScreen(_ name: String) -> some View {
        onAppear { AppTelemetry.screen(name) }
    }
}
