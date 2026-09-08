import Foundation

nonisolated enum StickerShareRoute: Hashable {
    static let homeURL = URL(string: "https://sticker.rxlab.app/share/ios")!
    static let appStoreURL = URL(string: "https://apps.apple.com/app/id6805825708")!
    case quick
    case pack(String)

    static func packURL(_ slug: String) -> URL { homeURL.appending(path: "packs").appending(path: slug) }
    init?(url: URL) {
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "sticker.rxlab.app",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.lowercased() ?? ""
        guard !encodedPath.contains("%2f"), !encodedPath.contains("%5c") else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if parts == ["share", "ios"] { self = .quick } else if parts.count == 4, Array(parts.prefix(3)) == ["share", "ios", "packs"],
                parts[3].range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil {
            self = .pack(parts[3])
        } else { return nil }
    }
}
