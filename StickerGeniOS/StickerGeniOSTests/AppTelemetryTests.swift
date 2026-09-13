import Foundation
import StoreKit
import Testing
@testable import StickerGeniOS

@Suite("App telemetry")
@MainActor
struct AppTelemetryTests {
    @Test("StoreKit diagnostics retain codes in telemetry but keep messages on device")
    func storeKitDiagnosticsDoNotUploadMessages() {
        let source = StoreKitError.systemError(NSError(domain: "ASDErrorDomain", code: 530, userInfo: [
            NSLocalizedDescriptionKey: "Private Apple error message",
            NSUnderlyingErrorKey: NSError(domain: "private-account.example", code: 17,
                                         userInfo: [NSLocalizedDescriptionKey: "Private underlying message"])
        ]))
        let failure = SubscriptionStoreKitFailure(source, stage: .refreshRequest)
        let report = failure.report(version: "1.2", build: "3", operatingSystem: "iOS test")
        #expect(report.contains("Private Apple error message"))
        #expect(report.contains("Private underlying message"))
        #expect(report.contains("App: 1.2 (3)"))
        let safe = AppTelemetry.sanitizedError(failure, operation: "subscription_connection", category: "storekit")
        #expect(safe.code == (source as NSError).code)
        #expect(safe.userInfo["storekit_stage"] as? String == "storekit.refresh.request")
        let codes = safe.userInfo["storekit_errors"] as? String ?? ""
        #expect(codes.contains("ASDErrorDomain (530)"))
        #expect(codes.contains("other (17)"))
        #expect(!String(describing: safe.userInfo).contains("Private"))
        #expect(!String(describing: safe.userInfo).contains("private-account"))
    }

    @Test("StoreKit verification failures identify the failed verification")
    func verificationDiagnostics() {
        let failure = SubscriptionStoreKitFailure(
            VerificationResult<AppTransaction>.VerificationError.invalidDeviceVerification,
            stage: .refreshVerification
        )
        #expect(failure.errorCodes.contains("invalidDeviceVerification"))
        #expect(failure.stage == .refreshVerification)
    }

    @Test("Non-fatal reports discard raw error messages and metadata")
    func stripsSensitiveErrorDetails() {
        let source = NSError(domain: "https://private.example/token", code: 503, userInfo: [
            NSLocalizedDescriptionKey: "private prompt",
            NSURLErrorFailingURLErrorKey: URL(string: "https://private.example/secret")!,
            NSUnderlyingErrorKey: NSError(domain: "private user", code: 1)
        ])
        let safe = AppTelemetry.sanitizedError(source, operation: "create_sticker", category: "application")
        #expect(safe.domain == "app.rxlab.stickerfactory.create_sticker")
        #expect(safe.code == 503)
        #expect(safe.userInfo.count == 1)
        #expect(safe.localizedDescription == "application")
    }

    @Test("Instrumentation preserves successful operation results")
    func preservesResults() async {
        let result = await AppTelemetry.measure(.createSticker) { 42 }
        #expect(result == 42)
    }

    @Test("Instrumentation rethrows the original error")
    func preservesErrors() async {
        let expected = NSError(domain: "test", code: 7)
        do {
            _ = try await AppTelemetry.measure(.createSticker) { throw expected }
            Issue.record("Expected the operation error")
        } catch {
            #expect((error as NSError) === expected)
        }
    }

    @Test("Cancellation remains cancellation")
    func preservesCancellation() async {
        do {
            _ = try await AppTelemetry.measure(.createSticker) { throw CancellationError() }
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}
