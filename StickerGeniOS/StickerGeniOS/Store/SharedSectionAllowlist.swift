import Foundation

/// The section ids the user currently expects to see, published to the app group.
///
/// The Messages extension refreshes over the network, so normally it learns about an uninstall on
/// its next run. Offline it cannot: it falls back to its on-disk cache, which still holds the pack
/// the user just removed — and stickers from a removed pack stay insertable.
///
/// Writing the allowlist here lets the extension filter its cached sections without a network
/// round trip. It is a hint, never a source of truth: a missing value means "no opinion", and the
/// cache is served whole exactly as before.
enum SharedSectionAllowlist {
    /// Duplicated rather than shared because the two targets do not compile a common file — the
    /// same reason `SharedAuthConfiguration.appGroupIdentifier` restates it on the extension side.
    static let appGroupIdentifier = "group.app.rxlab.stickerfactory"
    static let defaultsKey = "StickerFactoryVisibleSectionIDs"

    static func publish(installedPackIDs: [String], defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)) {
        guard let defaults else { return }
        defaults.set(["mine"] + installedPackIDs.map { "pack:\($0)" }, forKey: defaultsKey)
    }

    static func clear(defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)) {
        defaults?.removeObject(forKey: defaultsKey)
    }
}
