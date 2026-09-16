import Foundation

/// Data only: the server compiles its MDX into these native presentation blocks.
nonisolated struct TutorialDocument: Decodable, Sendable {
    let version: Int
    let locale: String
    let strings: [String: String]
    let sections: [Section]
    let chapters: [Chapter]
    struct Section: Decodable, Identifiable, Sendable { let id: String; let title: String }
    struct Chapter: Decodable, Identifiable, Sendable {
        let id: String; let section: String; let title: String; let steps: [Step]
    }
    struct Step: Decodable, Identifiable, Sendable {
        let id: String; let title: String; let blocks: [Block]; let action: String
    }
    struct Block: Decodable, Sendable {
        enum Kind: String, Decodable, Sendable { case paragraph, heading, callout, list, media, action }
        let type: Kind
        var text: String?
        var items: [String]?
        var ordered: Bool?
        var id: String?
        var caption: String?
        var poster: String?
        var animation: String?
        var title: String?
        var url: String?
    }
    func copy(_ key: String) -> String { strings[key] ?? key }
    /// A string added after a document was published is missing from cached content,
    /// so newer controls carry their own app-localized wording as a fallback.
    func copy(_ key: String, fallback: String) -> String { strings[key] ?? fallback }
    func validated() throws -> Self {
        func unique(_ ids: [String]) -> Bool { !ids.isEmpty && Set(ids).count == ids.count && ids.allSatisfy(TutorialDeepLink.validSlug) }
        func text(_ value: String?) -> Bool { value.map { !$0.isEmpty && $0.count <= 12_000 } ?? false }
        func action(_ value: String) -> Bool {
            guard let url = URL(string: value), case .action = TutorialDeepLink(url: url) else { return false }; return true
        }
        func media(_ value: String?, animated: Bool = false) -> Bool {
            guard let value else { return false }
            let suffix = animated ? #"\.animated\.webp$"# : #"\.webp$"#
            return value.range(of: "^/tutorial/media/\(locale)/[a-z0-9-]+" + suffix, options: .regularExpression) != nil
        }
        let required = [
            "intro", "next", "back", "done", "index", "resume", "tryIt", "completed",
            "step", "of", "play", "pause", "nextChapter", "retry", "mediaError", "read"
        ]
        guard version == 1, ["en", "zh-CN", "zh-HK"].contains(locale),
              sections.count <= 20, chapters.count <= 100, unique(sections.map(\.id)), unique(chapters.map(\.id)),
              sections.allSatisfy({ text($0.title) }),
              required.allSatisfy({ text(strings[$0]) }) else { throw TutorialContentError.invalid }
        for chapter in chapters {
            guard sections.contains(where: { $0.id == chapter.section }), text(chapter.title),
                  chapter.steps.count <= 100, unique(chapter.steps.map(\.id)) else { throw TutorialContentError.invalid }
            for step in chapter.steps {
                guard text(step.title), action(step.action), !step.blocks.isEmpty, step.blocks.count <= 100 else {
                    throw TutorialContentError.invalid
                }
                for block in step.blocks {
                    let valid: Bool
                    switch block.type {
                    case .paragraph, .heading, .callout: valid = text(block.text)
                    case .list: valid = block.items.map { !$0.isEmpty && $0.count <= 100 && $0.allSatisfy { text($0) } } ?? false
                    case .media:
                        let animated = block.animation == nil || media(block.animation, animated: true)
                        valid = text(block.caption) && media(block.poster) && animated
                    case .action: valid = text(block.title) && block.url.map(action) == true
                    }
                    guard valid else { throw TutorialContentError.invalid }
                }
            }
        }
        return self
    }
}
nonisolated enum TutorialContentError: Error { case invalid, unavailable }

/// Public requests use standard URL caching, without the account API's token or cookies.
nonisolated final class TutorialContentClient: NSObject, URLSessionTaskDelegate, Sendable {
    let baseURL: URL
    init(baseURL: URL) { self.baseURL = baseURL }
    func document(locale: String) async throws -> TutorialDocument {
        let url = baseURL.appending(path: "api/v1/tutorial").appending(path: locale)
        let data = try await data(url: url, limit: 512 * 1024, mimeType: "application/json")
        return try JSONDecoder().decode(TutorialDocument.self, from: data).validated()
    }
    func data(url: URL, limit: Int, mimeType: String) async throws -> Data {
        guard accepts(url) else { throw TutorialContentError.invalid }
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(mimeType, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.mimeType == mimeType, response.expectedContentLength <= limit else { throw TutorialContentError.unavailable }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw TutorialContentError.invalid }
            data.append(byte)
        }
        return data
    }
    func accepts(_ url: URL) -> Bool {
        let port = { (url: URL) in url.port ?? (url.scheme == "https" ? 443 : 80) }
        return url.scheme == baseURL.scheme && url.host == baseURL.host && port(url) == port(baseURL)
            && url.user == nil && url.password == nil && url.fragment == nil
            && (url.path.hasPrefix("/api/v1/tutorial/") || url.path.hasPrefix("/tutorial/media/"))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, accepts(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
