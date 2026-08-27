import Foundation
import SwiftUI

nonisolated enum LegalDocument: String, Hashable, Sendable {
    case privacy
    case terms

    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .terms: "Terms of Service"
        }
    }

    var systemImage: String {
        switch self {
        case .privacy: "hand.raised.fill"
        case .terms: "doc.text.fill"
        }
    }

    func url(relativeTo baseURL: URL) -> URL {
        ["api", "v1", "legal", rawValue].reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }
}

nonisolated enum LegalDocumentLoadingError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidMarkdown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid response."
        case .httpStatus(let status):
            "The server could not load this document (\(status))."
        case .invalidMarkdown:
            "The server returned an unreadable document."
        }
    }
}

nonisolated enum LegalDocumentLoader {
    static func load(
        _ document: LegalDocument,
        baseURL: URL,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: document.url(relativeTo: baseURL))
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        request.cachePolicy = .useProtocolCachePolicy

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LegalDocumentLoadingError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LegalDocumentLoadingError.httpStatus(response.statusCode)
        }
        guard response.mimeType == "text/markdown" else {
            throw LegalDocumentLoadingError.invalidMarkdown
        }
        guard !data.isEmpty, let markdown = String(data: data, encoding: .utf8) else {
            throw LegalDocumentLoadingError.invalidMarkdown
        }
        return markdown
    }
}

struct LegalDocumentView: View {
    let document: LegalDocument
    let baseURL: URL

    @State private var state: LoadingState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView("Loading \(document.title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let markdown):
                ScrollView {
                    MarkdownText(markdown: markdown, style: .document)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: document) { await load() }
        .accessibilityIdentifier("legal-document-view")
    }

    private func load() async {
        state = .loading
        do {
            let markdown = try await LegalDocumentLoader.load(document, baseURL: baseURL)
            guard !Task.isCancelled else { return }
            state = .loaded(markdown)
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

private extension LegalDocumentView {
    enum LoadingState {
        case loading
        case loaded(String)
        case failed(String)
    }
}
