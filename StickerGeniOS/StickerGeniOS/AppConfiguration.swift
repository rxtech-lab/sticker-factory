import Foundation

nonisolated struct AppConfiguration: Sendable {
    static let defaultAppName = "Winky Sticker House"
    static let appGroupIdentifier = "group.app.rxlab.stickerfactory"
    static let keychainService = "app.rxlab.sticker-factory.oauth"
    static let keychainAccount = "oauth-token-bundle"
    static let keychainAccessGroupInfoKey = "StickerFactoryKeychainAccessGroup"
    static let refreshLockFilename = "oauth-refresh.lock"

    let appVersion: String?
    let appBuild: String?
    let apiBaseURL: URL
    let oauthIssuer: URL
    let oauthTokenURL: URL
    let oauthClientID: String
    let oauthRedirectURI: String

    static var allowsInsecureSharedStorage: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
            || ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    /// Whether the picker offers to lift a subject out of a photo or Live Photo.
    ///
    /// On everywhere except UI tests, whose fixtures expect the plain reference flow. This was
    /// briefly gated on `#if DEBUG`, which meant the entire feature was invisible in any build
    /// installed on a device: photos went in as ordinary references and the thumbnails were inert,
    /// with nothing on screen explaining why. A flag that silently removes a feature in exactly the
    /// configuration people test with is worse than no flag.
    ///
    /// `--disable-subject-lift` remains as a kill switch if segmentation quality turns out to need
    /// one, since that is the part that cannot be fixed without shipping a new binary.
    static var subjectLiftEnabled: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--disable-subject-lift") { return false }
        if arguments.contains("--ui-testing") { return false }
        return true
    }

    #if DEBUG
    private static let defaultAPIBaseURL = "http://localhost:3000"
    #else
    private static let defaultAPIBaseURL = "https://sticker.rxlab.app"
    #endif

    static func live(bundle: Bundle = .main) -> Self {
        return Self(
            appVersion: optionalConfiguredValue("CFBundleShortVersionString", bundle: bundle),
            appBuild: optionalConfiguredValue("CFBundleVersion", bundle: bundle),
            apiBaseURL: URL(string: configuredValue("StickerFactoryAPIBaseURL", bundle: bundle, fallback: defaultAPIBaseURL))!,
            oauthIssuer: URL(string: configuredValue("StickerFactoryOAuthIssuer", bundle: bundle, fallback: "https://auth.rxlab.app"))!,
            oauthTokenURL: URL(string: configuredValue("StickerFactoryAuthTokenURL", bundle: bundle, fallback: "https://auth.rxlab.app/api/oauth/token"))!,
            oauthClientID: configuredValue("StickerFactoryIOSClientID", bundle: bundle, fallback: "client_1ce3e6efd6da4214a61df67949a71622"),
            oauthRedirectURI: configuredValue("StickerFactoryOAuthRedirectURI", bundle: bundle, fallback: "stickerfactory://oauth/callback")
        )
    }

    private static func configuredValue(_ key: String, bundle: Bundle, fallback: String) -> String {
        optionalConfiguredValue(key, bundle: bundle) ?? fallback
    }

    private static func optionalConfiguredValue(_ key: String, bundle: Bundle) -> String? {
        let raw = bundle.object(forInfoDictionaryKey: key) as? String
        guard let raw, !raw.isEmpty, !raw.contains("$(") else { return nil }
        return raw
    }
}
