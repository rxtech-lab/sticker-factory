import Foundation
import RxSubscriptionIOS
import XCTest
@testable import StickerGeniOS

final class SubscriptionAccessTests: XCTestCase {
    func testPublishableKeysSelectOnlyTheMatchingEnvironment() {
        let keys = SubscriptionPublishableKeys(
            xcode: "rxs_pk_xcode_local",
            sandbox: "rxs_pk_sandbox_testflight",
            production: "rxs_pk_production_appstore"
        )

        XCTAssertEqual(keys.key(for: .xcode), "rxs_pk_xcode_local")
        XCTAssertEqual(keys.key(for: .sandbox), "rxs_pk_sandbox_testflight")
        XCTAssertEqual(keys.key(for: .production), "rxs_pk_production_appstore")
        XCTAssertTrue(keys.hasAnyKey)
    }

    func testPublishableKeysRejectSecretsAndMismatchedEnvironments() {
        let keys = SubscriptionPublishableKeys(
            xcode: "rxs_xcode_secret",
            sandbox: "rxs_pk_production_wrong_environment",
            production: nil
        )

        XCTAssertNil(keys.key(for: .xcode))
        XCTAssertNil(keys.key(for: .sandbox))
        XCTAssertNil(keys.key(for: .production))
        XCTAssertFalse(keys.hasAnyKey)
    }

    func testBackendLiveStatusesCountAsActiveSubscriptions() {
        XCTAssertTrue(SubscriptionAccess.isActive(status: "active"))
        XCTAssertTrue(SubscriptionAccess.isActive(status: "trialing"))
        XCTAssertTrue(SubscriptionAccess.isActive(status: "past_due"))
        XCTAssertFalse(SubscriptionAccess.isActive(status: "canceled"))
        XCTAssertFalse(SubscriptionAccess.isActive(status: "expired"))
    }

    func testCreditsUsePointsBalanceAndDefaultToZero() throws {
        let balances = try JSONDecoder().decode(
            [Balance].self,
            from: Data(
                """
                [
                  {"unit":"credits","name":"Legacy credits","precision":0,"amount":999,"available":999},
                  {"unit":"points","name":"Points","precision":0,"amount":80,"available":75}
                ]
                """.utf8
            )
        )

        XCTAssertEqual(SubscriptionBalance.credits(in: balances), 75)
        XCTAssertEqual(SubscriptionBalance.credits(in: []), 0)
    }

    func testActiveSubscriberDoesNotSeePurchaseWallForSubscriptionRefusal() {
        XCTAssertEqual(
            SubscriptionPaywallContent.resolve(
                hasActiveSubscription: true,
                refusal: .subscriptionRequired
            ),
            .suppressed
        )
    }

    func testActiveSubscriberAndCreditRefusalOpenCreditControls() {
        XCTAssertEqual(
            SubscriptionPaywallContent.resolve(
                hasActiveSubscription: true,
                refusal: nil
            ),
            .credits
        )
        XCTAssertEqual(
            SubscriptionPaywallContent.resolve(
                hasActiveSubscription: true,
                refusal: .insufficientCredits(required: 50, available: 10)
            ),
            .credits
        )
    }

    func testFreeUserStillSeesPlans() {
        XCTAssertEqual(
            SubscriptionPaywallContent.resolve(
                hasActiveSubscription: false,
                refusal: nil
            ),
            .plans
        )
        XCTAssertEqual(
            SubscriptionPaywallContent.resolve(
                hasActiveSubscription: false,
                refusal: .subscriptionRequired
            ),
            .plans
        )
    }

    func testTopUpTitleUsesGrantedAmountInsteadOfCatalogPriceCopy() throws {
        let topUp = try decodeTopUp(
            name: "1,000 Points — $9.99",
            amount: 1_000,
            eligible: true
        )

        let title = TopUpPresentation.title(for: topUp)

        XCTAssertTrue(title.contains("1,000"))
        XCTAssertTrue(title.localizedCaseInsensitiveContains("points"))
        XCTAssertFalse(title.contains("$9.99"))
    }

    func testTopUpEligibilityExplainsPurchaseLimit() throws {
        let topUp = try decodeTopUp(
            name: "Points",
            amount: 1_000,
            eligible: false,
            blockedBy: #"[{"ruleType":"purchase_limit","planId":null,"roleId":null}]"#
        )

        XCTAssertEqual(TopUpPresentation.eligibilityText(for: topUp), "Purchase limit reached")
    }

    private func decodeTopUp(
        name: String,
        amount: Int,
        eligible: Bool,
        blockedBy: String = "null"
    ) throws -> TopUpProduct {
        let data = Data(
            """
            {
              "id": "topup-1",
              "key": "points-1000",
              "name": "\(name)",
              "description": "Add points to your balance.",
              "unit": "points",
              "amount": \(amount),
              "priceAmountCents": 999,
              "currency": "usd",
              "eligible": \(eligible),
              "blockedBy": \(blockedBy),
              "purchaseOptions": []
            }
            """.utf8
        )
        return try JSONDecoder().decode(TopUpProduct.self, from: data)
    }
}
