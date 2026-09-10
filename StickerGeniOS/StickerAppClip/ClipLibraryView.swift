import SwiftUI
import Observation

nonisolated private struct ClipLibrarySticker: Decodable, Identifiable {
    struct Asset: Decodable { let id: String }
    let id: String
    let title: String
    let previewAsset: Asset?
}

@MainActor @Observable
private final class ClipLibraryModel {
    private(set) var stickers: [ClipLibrarySticker] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var nextCursor: String?
    var error: String?
    private let thumbnails = NSCache<NSString, UIImage>()

    init() { thumbnails.countLimit = 60 }

    func load(using client: QuickModeModel, more: Bool = false) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            var query = [URLQueryItem(name: "status", value: "published"), URLQueryItem(name: "limit", value: "30")]
            if more, let nextCursor { query.append(URLQueryItem(name: "cursor", value: nextCursor)) }
            struct Page: Decodable { let data: [ClipLibrarySticker]; let nextCursor: String? }
            let page = try JSONDecoder().decode(Page.self, from: await client.get("api/v1/stickers", queryItems: query))
            if more {
                let known = Set(stickers.map(\.id))
                stickers.append(contentsOf: page.data.filter { !known.contains($0.id) })
            } else { stickers = page.data }
            nextCursor = page.nextCursor
            loaded = true
        } catch { self.error = error.localizedDescription }
    }

    func thumbnail(assetID: String, using client: QuickModeModel) async throws -> UIImage {
        if let cached = thumbnails.object(forKey: assetID as NSString) { return cached }
        struct Download: Decodable { let url: URL }
        let download = try JSONDecoder().decode(Download.self, from: await client.get("api/v1/assets/\(assetID)/download"))
        guard download.url.scheme == "https" else { throw MessagesStickerCreationError.invalidResponse }
        let (data, response) = try await URLSession.shared.data(from: download.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 12 * 1024 * 1024,
              let image = UIImage(data: data),
              let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 320, height: 320)) else {
            throw MessagesStickerCreationError.invalidResponse
        }
        thumbnails.setObject(thumbnail, forKey: assetID as NSString)
        return thumbnail
    }
}

struct ClipLibraryView: View {
    @State var generation: QuickModeModel
    let makeModel: @MainActor () -> QuickModeModel
    @State private var library = ClipLibraryModel()
    @State private var showingComposer = false
    @State private var destination: Detail?
    @State private var completedDestination: Detail?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private struct Detail: Identifiable, Hashable {
        let id: String
        let model: QuickModeModel
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your sticker shelf")
                                .font(.posterDisplay(30, weight: .heavy))
                                .tracking(-0.8)
                                .accessibilityAddTraits(.isHeader)
                            Text("Little ideas. Ready to send again.")
                                .foregroundStyle(AppColors.muted)
                        }
                        Spacer(minLength: 0)
                        StickerBlobIcon(icon: PosterIcon.mark, fill: AppColors.lime)
                            .frame(width: 62, height: 64)
                            .accessibilityHidden(true)
                    }
                    if generation.busy {
                        Button { showingComposer = true } label: {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text(generation.message).font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .padding(16)
                            .posterSurface(cornerRadius: 18, fill: AppColors.mint, offset: .zero)
                        }
                        .buttonStyle(.posterPlain)
                        .accessibilityIdentifier("clip-generation-status")
                    } else if let error = generation.error {
                        ErrorBanner(message: error)
                        Button("Resume generation", systemImage: "arrow.clockwise") {
                            showingComposer = true
                            Task { await generation.resume() }
                        }
                        .buttonStyle(.posterSecondary)
                    }
                    if !library.loaded && library.loading {
                        PosterProgress(message: "Loading your stickers…").frame(maxWidth: .infinity)
                    } else if library.loaded && library.stickers.isEmpty {
                        PosterCard(fill: AppColors.sky.opacity(0.25)) {
                            VStack(spacing: 16) {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .font(.system(size: 40))
                                Text("Your first sticker starts here")
                                    .font(.title3.weight(.heavy))
                                Text("Make something you love. Your generated stickers will be waiting here whenever you return.")
                                    .foregroundStyle(AppColors.muted)
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                        }
                        .accessibilityIdentifier("clip-library-empty")
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 140), spacing: 16)],
                            spacing: 20
                        ) {
                            ForEach(library.stickers) { sticker in
                                Button {
                                    destination = Detail(id: sticker.id, model: makeModel())
                                } label: {
                                    ClipStickerTile(sticker: sticker, library: library, client: generation)
                                }
                                .buttonStyle(.posterPlain)
                                .disabled(generation.busy)
                                .accessibilityIdentifier("clip-sticker-\(sticker.id)")
                            }
                        }
                        if library.nextCursor != nil {
                            Button {
                                Task { await library.load(using: generation, more: true) }
                            } label: {
                                Label("Load more stickers", systemImage: "arrow.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.posterSecondary)
                            .disabled(library.loading)
                        }
                        if library.loading { ProgressView().frame(maxWidth: .infinity) }
                    }
                    if let error = library.error {
                        ErrorBanner(message: error)
                        Button("Try again", systemImage: "arrow.clockwise") {
                            Task { await library.load(using: generation, more: library.nextCursor != nil) }
                        }
                        .buttonStyle(.posterSecondary)
                    }
                    Link(destination: StickerShareRoute.appStoreURL) {
                        Label("Get the full app", systemImage: "arrow.up.right")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .font(.subheadline.weight(.bold))
                }
                .padding(24)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await library.load(using: generation) }
        }
        .foregroundStyle(AppColors.ink)
        .navigationTitle("My stickers")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button {
                if !generation.busy && generation.completedGeneration != nil { generation = makeModel() }
                showingComposer = true
            } label: {
                Label(generation.busy ? "View generation" : "New sticker", systemImage: generation.busy ? "sparkles" : "plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.poster)
            .accessibilityIdentifier("clip-new-sticker")
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(AppColors.paper)
        }
        .sheet(isPresented: $showingComposer, onDismiss: {
            if let completedDestination {
                destination = completedDestination
                self.completedDestination = nil
            }
        }, content: {
            NavigationStack {
                QuickModeView(model: generation, presentation: .composer)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                Haptics.tap(.light)
                                showingComposer = false
                            }
                                .accessibilityIdentifier("clip-generation-close")
                        }
                    }
            }
            .presentationDragIndicator(.visible)
        })
        .navigationDestination(item: $destination) { detail in
            QuickModeView(model: detail.model, presentation: .detail)
                .task {
                    if detail.model.image == nil { await detail.model.openSticker(detail.id) }
                }
                .onChange(of: detail.model.completedGeneration) { _, _ in
                    Task { await library.load(using: generation) }
                }
                .accessibilityIdentifier("clip-sticker-detail")
        }
        .task { await library.load(using: generation) }
        .task { await generation.resume() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await library.load(using: generation) }
                if destination == nil { Task { await generation.resume() } }
            }
        }
        .onChange(of: generation.completedGeneration) { _, completion in
            guard completion != nil, let id = generation.stickerID else { return }
            if destination?.id != id {
                let detail = Detail(id: id, model: generation)
                if showingComposer {
                    completedDestination = detail
                    showingComposer = false
                } else { destination = detail }
            }
            Task { await library.load(using: generation) }
        }
    }
}

private struct ClipStickerTile: View {
    let sticker: ClipLibrarySticker
    let library: ClipLibraryModel
    let client: QuickModeModel
    @State private var thumbnail: UIImage?
    @State private var failed = false

    var body: some View {
        PosterCard(padding: 12, fill: AppColors.card, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).fill(AppColors.sky.opacity(0.2))
                    if let thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFit().padding(12)
                    } else if failed || sticker.previewAsset == nil {
                        Image(systemName: "photo").font(.largeTitle).foregroundStyle(AppColors.muted)
                    } else { ProgressView() }
                }
                .aspectRatio(1, contentMode: .fit)
                Text(sticker.title).font(.subheadline.weight(.bold)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sticker.title)
        .task(id: sticker.previewAsset?.id) {
            thumbnail = nil
            failed = false
            guard let id = sticker.previewAsset?.id else { return }
            do { thumbnail = try await library.thumbnail(assetID: id, using: client) } catch { failed = true }
        }
    }
}

#if DEBUG
/// Deterministic HTTP fixtures for the App Clip interaction tests. The production model,
/// request decoding, job watcher, image download, and completion navigation still run normally.
nonisolated final class ClipLibraryFixtureProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private var delivery: DispatchWorkItem?

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var payload: [String: Any] = [:]
        var imageData: Data?
        if path == "/fixture.png" {
            headers["Content-Type"] = "image/png"
            imageData = try? Data(contentsOf: FileManager.default.temporaryDirectory.appending(path: "clip-library-fixture.png"))
        } else if path.hasSuffix("/allowance") {
            payload = ["used": 1, "chargesPoints": false, "limit": 5, "remaining": 4]
        } else if path.hasSuffix("/events") {
            headers["x-job-state"] = "succeeded"
            headers["Content-Type"] = "text/event-stream"
        } else if path.hasSuffix("/download") {
            payload = ["url": "https://clip-fixtures.invalid/fixture.png"]
        } else if path == "/api/v1/stickers", request.httpMethod == "POST" {
            UserDefaults.standard.set(true, forKey: "clip-library-fixture-created")
            payload = ["stickerId": "new-sticker", "job": ["id": "fixture-job", "state": "queued"]]
        } else if path.hasSuffix("/chat/messages") {
            payload = ["job": ["id": "fixture-revision", "state": "queued"]]
        } else if path == "/api/v1/stickers" {
            if ProcessInfo.processInfo.arguments.contains("--clip-library-error") {
                status = 503
                payload = ["error": ["message": "Your stickers could not be loaded. Please try again."]]
            } else {
                let empty = ProcessInfo.processInfo.arguments.contains("--clip-library-empty")
                let more = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "cursor" } == true
                payload = ["data": empty ? [] : more ? [
                    ["id": "older-sticker", "title": "Sleepy moon", "previewAsset": ["id": "moon-preview"]]
                ] : [
                    ["id": "past-sticker", "title": "Happy cat", "previewAsset": ["id": "cat-preview"]],
                    ["id": "second-sticker", "title": "Party cat", "previewAsset": ["id": "party-preview"]]
                ], "nextCursor": empty || more ? NSNull() : "older-page"]
                if !more, UserDefaults.standard.bool(forKey: "clip-library-fixture-created") {
                    var items = payload["data"] as? [[String: Any]] ?? []
                    items.insert(["id": "new-sticker", "title": "Skateboarding cat", "previewAsset": ["id": "new-preview"]], at: 0)
                    payload["data"] = items
                }
            }
        } else if path.hasPrefix("/api/v1/stickers/") {
            let id = url.lastPathComponent
            let title = id == "new-sticker" ? "Skateboarding cat" : id == "older-sticker" ? "Sleepy moon" : "Happy cat"
            payload = [
                "id": id, "title": title, "status": "published", "activeRevisionId": "revision-1",
                "revisions": [[
                    "id": "revision-1", "candidateState": "published",
                    "previewAssetId": "cat-preview", "document": ["kind": "static"]
                ]]
            ]
        } else {
            status = 404
            payload = ["error": ["message": "No fixture for this request."]]
        }
        let data = imageData ?? (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers) else { return }
        let work = DispatchWorkItem { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        delivery = work
        if path.hasSuffix("/events"), ProcessInfo.processInfo.arguments.contains("--clip-slow-generation") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: work)
        } else { work.perform() }
    }
    override func stopLoading() { delivery?.cancel(); delivery = nil }
}
#endif
