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
                    MarkdownView(markdown)
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

private struct MarkdownView: View {
    private let blocks: [MarkdownBlock]

    init(_ markdown: String) {
        blocks = MarkdownBlock.parse(markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(attributed(content))
                .font(headingFont(level))
                .padding(.top, level == 1 ? 0 : 10)
        case .paragraph(let content):
            Text(attributed(content))
                .font(.body)
                .foregroundStyle(.primary)
                .lineSpacing(4)
        case .bullet(let content):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("•")
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(attributed(content))
                    .lineSpacing(3)
            }
            .padding(.leading, 4)
        case .quote(let content):
            Text(attributed(content))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.secondary.opacity(0.35))
                        .frame(width: 3)
                }
        case .rule:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func attributed(_ source: String) -> AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        default: .headline
        }
    }
}

private enum MarkdownBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet(String)
    case quote(String)
    case rule

    static func parse(_ markdown: String) -> [Self] {
        var blocks: [Self] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                flushParagraph()
                continue
            }

            if line == "---" {
                flushParagraph()
                blocks.append(.rule)
            } else if line.hasPrefix("### ") {
                flushParagraph()
                blocks.append(.heading(3, String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(2, String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.heading(1, String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }

        flushParagraph()
        return blocks
    }
}
