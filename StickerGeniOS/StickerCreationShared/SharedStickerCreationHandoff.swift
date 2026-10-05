import Foundation

/// A small, one-time handoff from the share extension to the app's creation form.
struct SharedStickerCreationRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let prompt: String
    let createdAt: Date
}

enum SharedStickerCreationHandoff {
    private static let appGroup = "group.app.rxlab.stickerfactory"
    private static let filePrefix = "sticker-creation-share-"
    private static let lifetime: TimeInterval = 10 * 60

    enum HandoffError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "Sticker Factory couldn't prepare the shared content. Try again."
        }
    }

    static func stage(prompt: String) throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw HandoffError.unavailable
        }
        removeExpiredFiles(in: container)
        let request = SharedStickerCreationRequest(
            id: UUID(), prompt: String(prompt.prefix(4_000)), createdAt: .now
        )
        try JSONEncoder().encode(request).write(to: fileURL(for: request.id, in: container), options: .atomic)
        var link = URLComponents()
        link.scheme = "stickerfactory"
        link.host = "share"
        link.path = "/create"
        link.queryItems = [URLQueryItem(name: "id", value: request.id.uuidString)]
        guard let url = link.url else { throw HandoffError.unavailable }
        return url
    }

    static func consume(_ url: URL) -> SharedStickerCreationRequest? {
        guard url.scheme?.lowercased() == "stickerfactory", url.host?.lowercased() == "share",
              url.path == "/create", url.user == nil, url.password == nil,
              let idText = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: idText),
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        let file = fileURL(for: id, in: container)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let data = try? Data(contentsOf: file),
              let request = try? JSONDecoder().decode(SharedStickerCreationRequest.self, from: data),
              request.id == id, !request.prompt.isEmpty,
              abs(request.createdAt.timeIntervalSinceNow) <= lifetime else { return nil }
        return request
    }

    private static func fileURL(for id: UUID, in container: URL) -> URL {
        container.appending(path: "\(filePrefix)\(id.uuidString).json")
    }

    private static func removeExpiredFiles(in container: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(filePrefix) {
            guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date.now.timeIntervalSince(date) > lifetime else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
