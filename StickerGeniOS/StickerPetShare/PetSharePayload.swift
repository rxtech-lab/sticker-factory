import Foundation
import UniformTypeIdentifiers

struct PetSharePayload: Codable, Sendable {
    var title: String?
    var url: String?
    var content: String?
    var html: String?

    var previewTitle: String { title ?? URL(string: url ?? "")?.host() ?? "Shared text" }
    var previewText: String { content ?? url ?? "HTML content" }

    var creationPrompt: String {
        let readableHTML = html?
            .replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let excerpt = (content ?? readableHTML ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = [title, excerpt.isEmpty ? nil : String(excerpt.prefix(3_500)), url]
            .compactMap { $0 }
        return String(("Create a sticker inspired by this shared content:\n" + pieces.joined(separator: "\n"))
            .prefix(4_000))
    }
}

enum PetSharePayloadError: LocalizedError {
    case unsupported

    var errorDescription: String? {
        "Share a web page, link, HTML, or text with your pet."
    }
}

@MainActor enum PetSharePayloadLoader {
    static func load(_ items: [Any]) async throws -> PetSharePayload {
        let providers = items.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
        var result = PetSharePayload()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
               let data = await loadDictionary(provider, type: UTType.propertyList.identifier) {
                result.title = clean(data["title"], limit: 200)
                result.url = webURL(data["url"])
                result.content = clean(data["content"], limit: 20_000)
                result.html = clean(data["html"], limit: 40_000)
            }
            if result.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                result.url = webURL(await loadString(provider, type: UTType.url.identifier))
            }
            if result.content == nil, provider.hasItemConformingToTypeIdentifier(UTType.html.identifier) {
                result.html = clean(await loadString(provider, type: UTType.html.identifier), limit: 40_000)
            }
            if result.content == nil, result.html == nil,
               provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                let text = clean(await loadString(provider, type: UTType.plainText.identifier), limit: 20_000)
                if let text, let url = webURL(text) { result.url = url }
                else { result.content = text }
            }
        }
        guard result.url != nil || result.content != nil || result.html != nil else {
            throw PetSharePayloadError.unsupported
        }
        return result
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return String(value.prefix(limit))
    }

    private static func webURL(_ value: String?) -> String? {
        guard let value = clean(value, limit: 2_048), let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil,
              url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }

    private static func loadDictionary(_ provider: NSItemProvider, type: String) async -> [String: String]? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                guard let dictionary = value as? NSDictionary else {
                    continuation.resume(returning: nil)
                    return
                }
                let source = (dictionary["NSExtensionJavaScriptPreprocessingResultsKey"] as? NSDictionary) ?? dictionary
                var strings: [String: String] = [:]
                for (key, value) in source {
                    if let key = key as? String, let value = value as? String { strings[key] = value }
                }
                continuation.resume(returning: strings)
            }
        }
    }

    private static func loadString(_ provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                let string: String?
                if let value = value as? String { string = value }
                else if let value = value as? URL {
                    string = value.isFileURL ? try? String(contentsOf: value, encoding: .utf8) : value.absoluteString
                }
                else if let value = value as? NSAttributedString { string = value.string }
                else if let value = value as? Data { string = String(data: value, encoding: .utf8) }
                else { string = nil }
                continuation.resume(returning: string)
            }
        }
    }
}
