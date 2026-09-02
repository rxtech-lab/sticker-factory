import Foundation

/// The server declining a request on billing grounds, rather than on anything the user did wrong.
///
/// Separate from the generic error path because it wants a different answer: an alert saying
/// "You do not have enough credits" leaves someone stuck, where a paywall lets them carry on. The
/// server is the one enforcing, so this is recognised from what it sent back rather than predicted
/// from the app's own cached balance — which can be stale, and which is not the authority anyway.
nonisolated enum SubscriptionRefusal: Equatable, Sendable {
    /// The user has a plan but not enough credits for this operation.
    case insufficientCredits(required: Int?, available: Int?)
    /// The operation needs a tier the user is not on. Today: publishing to the marketplace.
    case subscriptionRequired
}

nonisolated extension SubscriptionRefusal {
    init?(code: String, details: JSONValue?) {
        switch code {
        case "INSUFFICIENT_CREDITS":
            self = .insufficientCredits(
                required: details?.integer("required"),
                available: details?.integer("available")
            )
        case "SUBSCRIPTION_REQUIRED":
            self = .subscriptionRequired
        default:
            return nil
        }
    }
}

nonisolated extension Error {
    /// This error, if the server turned the request down for want of credits or a plan.
    var subscriptionRefusal: SubscriptionRefusal? {
        guard let envelope = self as? APIErrorEnvelope else { return nil }
        return SubscriptionRefusal(code: envelope.error.code, details: envelope.error.details)
    }
}

private nonisolated extension JSONValue {
    /// Reads a whole number out of an error's `details` object, tolerating its absence.
    func integer(_ key: String) -> Int? {
        guard case .object(let fields) = self, case .number(let value)? = fields[key] else { return nil }
        return Int(value)
    }
}
