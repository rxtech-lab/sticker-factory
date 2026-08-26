import Foundation

nonisolated struct AppConfiguration: Sendable {
    static let appGroupIdentifier = "group.app.rxlab.stickerfactory"
    static let keychainService = "app.rxlab.sticker-factory.oauth"
    static let keychainAccount = "oauth-token-bundle"
    static let keychainAccessGroupInfoKey = "StickerFactoryKeychainAccessGroup"
    static let refreshLockFilename = "oauth-refresh.lock"

    let apiBaseURL: URL
    let oauthIssuer: URL
    let oauthTokenURL: URL
    let oauthClientID: String
    let oauthRedirectURI: String

    static var allowsInsecureSharedStorage: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    #if DEBUG
    private static let defaultAPIBaseURL = "http://localhost:3000"
    #else
    private static let defaultAPIBaseURL = "https://sticker.rxlab.app"
    #endif

    static func live(bundle: Bundle = .main) -> Self {
        func value(_ key: String, fallback: String) -> String {
            let raw = bundle.object(forInfoDictionaryKey: key) as? String
            guard let raw, !raw.isEmpty, !raw.contains("$(") else { return fallback }
            return raw
        }

        return Self(
            apiBaseURL: URL(string: value("StickerFactoryAPIBaseURL", fallback: defaultAPIBaseURL))!,
            oauthIssuer: URL(string: value("StickerFactoryOAuthIssuer", fallback: "https://auth.rxlab.app"))!,
            oauthTokenURL: URL(string: value("StickerFactoryAuthTokenURL", fallback: "https://auth.rxlab.app/api/oauth/token"))!,
            oauthClientID: value("StickerFactoryIOSClientID", fallback: "client_1ce3e6efd6da4214a61df67949a71622"),
            oauthRedirectURI: value("StickerFactoryOAuthRedirectURI", fallback: "stickerfactory://oauth/callback")
        )
    }
}
