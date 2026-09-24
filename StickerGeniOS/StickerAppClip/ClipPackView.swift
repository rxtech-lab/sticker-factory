import SwiftUI
import WebKit

private struct PublicClipPack: Decodable {
    struct Creator: Decodable { let displayName: String }
    struct Sticker: Decodable, Identifiable {
        let id: String
        let title: String
        let previewURL: URL?
        let playbackRevisionId: String?
    }
    let title: String
    let summary: String?
    let creator: Creator
    let stickers: [Sticker]
}

struct ClipPackView: View {
    let slug: String
    @State private var pack: PublicClipPack?
    @State private var error: String?
    @State private var viewing: ClipStickerViewer.Item?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let pack {
                        packHeader(pack)
                        HStack {
                            Text("Inside the pack").font(.title3.weight(.heavy))
                                .accessibilityAddTraits(.isHeader)
                            Spacer()
                            Text("\(pack.stickers.count)")
                                .font(.headline)
                                .posterChip(fill: AppColors.lime)
                                .accessibilityLabel("\(pack.stickers.count) stickers")
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 250 : 140), spacing: 16)],
                            spacing: 18
                        ) {
                            ForEach(Array(pack.stickers.enumerated()), id: \.element.id) { index, sticker in
                                Button { open(sticker) } label: { stickerTile(sticker, index: index) }
                                    .buttonStyle(.posterPlain)
                                    .accessibilityLabel(sticker.title)
                                    .accessibilityHint(sticker.playbackRevisionId == nil
                                        ? String(localized: "Opens full screen")
                                        : String(localized: "Opens full screen with poses"))
                                    .accessibilityIdentifier("clip-pack-sticker-\(sticker.id)")
                            }
                        }
                        if pack.stickers.isEmpty {
                            EmptyStateView(title: String(localized: "More stickers soon"),
                                           message: String(localized: "No stickers are available in this pack yet."),
                                           icon: PosterIcon.publish, accent: AppColors.peach)
                        }
                    } else if let error {
                        VStack(spacing: 16) {
                            EmptyStateView(title: String(localized: "Pack unavailable"), message: error,
                                           icon: PosterIcon.publish, accent: AppColors.peach)
                            Button { Task { await load() } } label: {
                                Label("Try again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.poster)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        PosterProgress(message: String(localized: "Loading pack…"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    }
                }
                .padding(24)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Sticker pack")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) {
                Text("Find your next favorite sticker.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppColors.muted)
                Link(destination: StickerShareRoute.appStoreURL) {
                    Label("Install in Sticker Factory", systemImage: "arrow.down.app")
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.posterLime)
            }
            .padding(20)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .background(AppColors.paper.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(AppColors.ink).frame(height: Poster.border) }
        }
        .toolbar { ShareLink(item: StickerShareRoute.packURL(slug)) { Label("Share pack", systemImage: "square.and.arrow.up") } }
        .task(id: slug) { await load() }
        .fullScreenCover(item: $viewing) { ClipStickerViewer(item: $0) }
    }

    private func open(_ sticker: PublicClipPack.Sticker) {
        Haptics.tap(.light)
        viewing = .init(id: sticker.id, title: sticker.title, artwork: sticker.previewURL.map { .url($0) },
                        source: sticker.playbackRevisionId == nil ? nil : .publicPack(slug: slug))
    }

    private func packHeader(_ pack: PublicClipPack) -> some View {
        PosterCard(padding: 22, fill: AppColors.sky) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    PosterEyebrow(text: String(localized: "Shared pack"))
                    Spacer(minLength: 8)
                    Text(PosterIcon.mark).font(.posterDisplay(36)).accessibilityHidden(true)
                }
                Text(pack.title)
                    .font(.posterDisplay(32, weight: .heavy))
                    .tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
                Text("by \(pack.creator.displayName)")
                    .font(.subheadline.weight(.semibold))
                if let summary = pack.summary, !summary.isEmpty {
                    Text(summary).font(.body)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func stickerTile(_ sticker: PublicClipPack.Sticker, index: Int) -> some View {
        let colors = [AppColors.lime, AppColors.peach, AppColors.sky, AppColors.mint]
        return PosterCard(padding: 12, cornerRadius: Poster.tileRadius, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(colors[index % colors.count].opacity(0.35))
                    if let url = sticker.previewURL {
                        AnimatedClipPreview(url: url).padding(8).accessibilityHidden(true)
                    } else {
                        StickerBlobIcon(
                            icon: PosterIcon.staticSticker,
                            fill: colors[index % colors.count],
                            tilt: index.isMultiple(of: 2) ? -6 : 6
                        )
                            .frame(width: 76, height: 80)
                            .accessibilityHidden(true)
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if sticker.playbackRevisionId != nil {
                        Image(systemName: "switch.2")
                            .font(.caption.weight(.bold))
                            .padding(6)
                            .posterSurface(cornerRadius: 10, fill: AppColors.lime, offset: .zero)
                            .padding(6)
                            .accessibilityHidden(true)
                    }
                }
                Text(sticker.title)
                    .font(.subheadline.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if sticker.previewURL == nil {
                    Text("Preview unavailable").font(.caption).foregroundStyle(AppColors.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var packSession: URLSession {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            return ClipPackFixtureProtocol.session
        }
        #endif
        return .shared
    }

    private func load() async {
        pack = nil; error = nil
        do {
            let base = try MessagesAPIConfiguration.baseURL()
            let (data, response) = try await packSession.data(from: base.appending(path: "api/v1/public/packs").appending(path: slug))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw MessagesStickerCreationError.notPublished("This pack is no longer available.")
            }
            pack = try JSONDecoder().decode(PublicClipPack.self, from: data)
        } catch where !QuickModeModel.isCancellation(error) { self.error = error.localizedDescription } catch {}
    }
}

/// WebKit renders APNG/WebP animation without bundling a full-app image/rendering dependency.
struct AnimatedClipPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard url.scheme == "https" else { return }
        let escaped = url.absoluteString.replacingOccurrences(
            of: "&",
            with: "&amp;"
        ).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
        view.loadHTMLString("""
            <meta name='viewport' content='width=device-width,initial-scale=1'>\
            <style>body{margin:0}img{width:100%;height:100%;object-fit:contain;position:absolute}</style>\
            <img src="\(escaped)">
            """, baseURL: nil)
    }
}

#if DEBUG
/// Exercises the public response decoder and screen without contacting a live backend.
private nonisolated final class ClipPackFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClipPackFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let packs = ["happy-cats": ("Happy Cats", "Waving cat"), "space-dogs": ("Space Dogs", "Moon dog")]
        let fixture = url.path.hasPrefix("/api/v1/public/packs/") && url.pathComponents.count == 6
            ? packs[url.lastPathComponent] : nil
        let body: [String: Any]
        if let fixture {
            body = ["title": fixture.0, "summary": "A pack to share with friends.",
                    "creator": ["displayName": "Clip Creator"],
                    "stickers": [["id": "preview-1", "title": fixture.1],
                                 ["id": "posable-1", "title": "Posable pet", "playbackRevisionId": "fixture-revision"]]]
        } else { body = ["error": "Not found"] }
        let response = HTTPURLResponse(url: url, statusCode: fixture == nil ? 404 : 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
