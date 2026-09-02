import Foundation

/// Links emitted by the Messages extension after it starts a generation job.
nonisolated enum StickerDeepLink {
    static func stickerID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "stickerfactory",
              url.host?.lowercased() == "sticker",
              let value = url.pathComponents.last,
              value != "/",
              UUID(uuidString: value) != nil else {
            return nil
        }
        return value.lowercased()
    }
}
