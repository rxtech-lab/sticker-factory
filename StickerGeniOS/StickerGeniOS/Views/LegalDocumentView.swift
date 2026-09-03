import Foundation
import SwiftUI

nonisolated enum LegalDocument: String, Hashable, Sendable {
    case privacy
    case terms

    var title: String {
        switch self {
        case .privacy: String(localized: "Privacy Policy")
        case .terms: String(localized: "Terms of Service")
        }
    }

    var posterSymbol: String {
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

nonisolated enum MarkdownDocumentLoadingError: LocalizedError, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidMarkdown

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "The server returned an invalid response.")
        case .httpStatus(let status):
            String(localized: "The server could not load this document (\(status)).")
        case .invalidMarkdown:
            String(localized: "The server returned an unreadable document.")
        }
    }
}

nonisolated enum MarkdownDocumentLoader {
    static func load(
        url: URL,
        session: URLSession = .shared,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        request.cachePolicy = cachePolicy

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw MarkdownDocumentLoadingError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw MarkdownDocumentLoadingError.httpStatus(response.statusCode)
        }
        guard response.mimeType == "text/markdown" else {
            throw MarkdownDocumentLoadingError.invalidMarkdown
        }
        guard !data.isEmpty, let markdown = String(data: data, encoding: .utf8) else {
            throw MarkdownDocumentLoadingError.invalidMarkdown
        }
        return markdown
    }
}

nonisolated enum LegalDocumentLoader {
    static func load(
        _ document: LegalDocument,
        baseURL: URL,
        session: URLSession = .shared
    ) async throws -> String {
        try await MarkdownDocumentLoader.load(
            url: document.url(relativeTo: baseURL),
            session: session
        )
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
                PosterProgress(message: String(localized: "Loading \(document.title)…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let markdown):
                ScrollView {
                    MarkdownText(markdown: markdown, style: .document)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
                .refreshable { await load(showingPlaceholder: false) }
            case .failed(let message):
                ContentUnavailableView {
                    PosterSymbolLabel("Unable to Load", posterSymbol: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.poster)
                }
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: document) { await load() }
        .accessibilityIdentifier("legal-document-view")
    }

    /// Pull-to-refresh must not swap the loaded markdown out for the placeholder: the scroll view
    /// owning the refresh gesture only exists in the `.loaded` branch, so returning to `.loading`
    /// tears down the very task doing the reload, and the cancelled request then renders as a
    /// failure. Refreshing keeps the old document on screen behind the system's own spinner.
    private func load(showingPlaceholder: Bool = true) async {
        if showingPlaceholder {
            state = .loading
        }
        do {
            let markdown = try await LegalDocumentLoader.load(document, baseURL: baseURL)
            guard !Task.isCancelled else { return }
            state = .loaded(markdown)
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
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
