import Foundation
import StoreKit

/// Preserves Apple's error text for on-device debugging. Telemetry uses only `errorCodes`;
/// messages and the report must never be sent to analytics or Crashlytics.
nonisolated struct SubscriptionStoreKitFailure: LocalizedError, Sendable {
    enum Stage: String, Sendable {
        case sharedRequest = "storekit.shared.request"
        case sharedVerification = "storekit.shared.verification"
        case refreshRequest = "storekit.refresh.request"
        case refreshVerification = "storekit.refresh.verification"
    }

    let stage: Stage
    let code: Int
    let errorCodes: String
    let errorMessages: String

    init(_ error: Error, stage: Stage) {
        self.stage = stage
        self.code = (error as NSError).code
        self.errorCodes = Self.codes(for: error).joined(separator: " > ")
        self.errorMessages = Self.messages(for: error).joined(separator: "\nCaused by: ")
    }

    var errorDescription: String? {
        SubscriptionConnectionError.appStoreUnavailable.errorDescription
    }

    func report(version: String, build: String, operatingSystem: String) -> String {
        """
        Subscription connection
        App: \(version) (\(build))
        OS: \(operatingSystem)
        Stage: \(stage.rawValue)
        Errors: \(errorCodes)
        Message: \(errorMessages)
        """
    }

    private static func underlyingError(in error: Error) -> Error? {
        if let storeError = error as? StoreKitError {
            switch storeError {
            case .networkError(let error): return error
            case .systemError(let error): return error
            default: break
            }
        }
        return (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error
    }

    private static func messages(for error: Error, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        var result = [error.localizedDescription]
        if let underlying = underlyingError(in: error) {
            result += messages(for: underlying, depth: depth + 1)
        }
        return result
    }

    private static func codes(for error: Error, depth: Int = 0) -> [String] {
        guard depth < 4 else { return [] }
        let nsError = error as NSError
        var domain = "other"
        var reason: String?
        var underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error

        if let storeError = error as? StoreKitError {
            domain = "StoreKitError"
            switch storeError {
            case .unknown: reason = "unknown"
            case .userCancelled: reason = "userCancelled"
            case .networkError(let error):
                reason = "networkError"
                underlying = error
            case .systemError(let error):
                reason = "systemError"
                underlying = error
            case .notAvailableInStorefront: reason = "notAvailableInStorefront"
            case .notEntitled: reason = "notEntitled"
            default: reason = "other"
            }
        } else if let verification = error as? VerificationResult<AppTransaction>.VerificationError {
            domain = "StoreKitVerificationError"
            switch verification {
            case .revokedCertificate: reason = "revokedCertificate"
            case .invalidCertificateChain: reason = "invalidCertificateChain"
            case .invalidDeviceVerification: reason = "invalidDeviceVerification"
            case .invalidEncoding: reason = "invalidEncoding"
            case .invalidSignature: reason = "invalidSignature"
            case .missingRequiredProperties: reason = "missingRequiredProperties"
            @unknown default: reason = "other"
            }
        } else if [NSURLErrorDomain, SKErrorDomain, NSCocoaErrorDomain,
                   "ASDErrorDomain", "AMSErrorDomain", "SSErrorDomain",
                   "SKInternalErrorDomain"].contains(nsError.domain) {
            domain = nsError.domain
        }

        let label = reason.map { "\(domain).\($0)" } ?? domain
        var result = ["\(label) (\(nsError.code))"]
        if let underlying {
            result += codes(for: underlying, depth: depth + 1)
        }
        return result
    }
}
