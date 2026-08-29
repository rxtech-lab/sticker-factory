import Foundation
import SwiftUI

nonisolated enum AboutPage {
    static let supportEmail = "support@rxlab.app"

    /// `mailto:` hands the address to whichever mail client the user has installed.
    static let supportEmailURL = URL(string: "mailto:\(supportEmail)")

    static func url(relativeTo baseURL: URL) -> URL {
        ["api", "v1", "about"].reduce(baseURL) { url, component in
            url.appendingPathComponent(component)
        }
    }

    static func load(
        baseURL: URL,
        session: URLSession = .shared
    ) async throws -> String {
        try await MarkdownDocumentLoader.load(
            url: url(relativeTo: baseURL),
            session: session,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }
}

struct AboutPageView: View {
    let baseURL: URL
    let appName: String
    let appVersion: String?
    let appBuild: String?

    @State private var state: LoadingState = .loading

    private var endpointURL: URL {
        AboutPage.url(relativeTo: baseURL)
    }

    private var title: String {
        String(localized: "About \(appName)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                markdownContent

                VStack(spacing: 12) {
                    LabeledContent("Version", value: displayValue(appVersion))
                    if let appBuild, !appBuild.isEmpty {
                        Divider()
                        LabeledContent("Build number", value: appBuild)
                    }
                }
                .padding(16)
                .background(.thinMaterial, in: .rect(cornerRadius: 16))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("app-version")

                if let supportEmailURL = AboutPage.supportEmailURL {
                    Link(destination: supportEmailURL) {
                        HStack(spacing: 12) {
                            Label("Contact support", systemImage: "envelope")
                            Spacer(minLength: 8)
                            Text(AboutPage.supportEmail)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                    .background(.thinMaterial, in: .rect(cornerRadius: 16))
                    .accessibilityIdentifier("support-email")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load(showingPlaceholder: false) }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: endpointURL) { await load() }
        .accessibilityIdentifier("about-page-view")
    }

    @ViewBuilder
    private var markdownContent: some View {
        switch state {
        case .loading:
            ProgressView(String(localized: "Loading \(appName)…"))
                .frame(maxWidth: .infinity, minHeight: 280)
        case .loaded(let markdown):
            MarkdownText(markdown: markdown, style: .document)
        case .failed(let message):
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    private func displayValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }

    /// Pull-to-refresh must not swap the loaded markdown out for the placeholder: collapsing the
    /// scroll content mid-gesture retracts the refresh control, which cancels the very task doing
    /// the reload, and the cancelled request then renders as a failure. Refreshing keeps the old
    /// document on screen behind the system's own spinner; only a first load shows the placeholder.
    private func load(showingPlaceholder: Bool = true) async {
        if showingPlaceholder {
            state = .loading
        }
        do {
            let markdown = try await AboutPage.load(baseURL: baseURL)
            guard !Task.isCancelled else { return }
            state = .loaded(markdown)
        } catch {
            guard !StickerStore.isCancellation(error) else { return }
            state = .failed(error.localizedDescription)
        }
    }

    private enum LoadingState {
        case loading
        case loaded(String)
        case failed(String)
    }
}
