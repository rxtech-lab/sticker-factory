import Foundation
import StoreKit
import Testing
@testable import StickerGeniOS

/// Some Apple IDs cannot read their app transaction at all: TestFlight answers
/// `SKInternalErrorDomain` 21 to both the passive read and the user's retry. That used to leave the
/// paywall on an error card with no way to subscribe or restore.
@Suite("Subscription environment fallback")
struct SubscriptionEnvironmentFallbackTests {
    private static let storeKitFailure = StoreKitError.systemError(NSError(domain: "SKInternalErrorDomain", code: 21))

    @Test("The receipt's file name decides between the two publishable keys", arguments: [
        ("sandboxReceipt", SubscriptionEnvironment.sandbox),
        ("receipt", SubscriptionEnvironment.production),
        (nil, SubscriptionEnvironment.production)
    ] as [(String?, SubscriptionEnvironment)])
    func receiptName(name: String?, expected: SubscriptionEnvironment) {
        #expect(SubscriptionEnvironment.receiptFallback(receiptName: name) == expected)
    }

    @Test("A StoreKit request that throws falls back instead of refusing to connect", arguments: [false, true])
    func requestFailureFallsBack(refreshing: Bool) async throws {
        let environment = try await SubscriptionEnvironment.currentVerified(
            refreshing: refreshing,
            appTransaction: { _ in throw Self.storeKitFailure },
            receiptName: { "sandboxReceipt" }
        )
        #expect(environment == .sandbox)
    }

    @Test("Only a user's retry asks StoreKit to refresh, which can prompt for credentials")
    func refreshIsPassedThrough() async throws {
        var requested: [Bool] = []
        for refreshing in [false, true] {
            _ = try await SubscriptionEnvironment.currentVerified(
                refreshing: refreshing,
                appTransaction: { requested.append($0); throw Self.storeKitFailure },
                receiptName: { nil }
            )
        }
        #expect(requested == [false, true])
    }
}
