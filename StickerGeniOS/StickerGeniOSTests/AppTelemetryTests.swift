import Foundation
import Testing
@testable import StickerGeniOS

@Suite("App telemetry")
@MainActor
struct AppTelemetryTests {
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
