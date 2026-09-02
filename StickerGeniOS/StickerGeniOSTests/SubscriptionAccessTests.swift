import Foundation
import RxSubscriptionIOS
import XCTest
@testable import StickerGeniOS

final class SubscriptionAccessTests: XCTestCase {
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
}
