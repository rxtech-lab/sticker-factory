import AnimatedView
import SwiftUI

/// A sticker on its own, full screen. A controllable sticker plays live from its published pose
/// bundle with the pose and mood pickers in a drawer beneath it, the same controls the full app
/// uses; any other sticker shows its published artwork.
struct ClipStickerViewer: View {
    enum Artwork {
        case image(UIImage)
        case url(URL)
    }

    struct Item: Identifiable {
        let id: String
        let title: String
        let artwork: Artwork?
        /// `nil` for a sticker without poses.
        let source: ClipPlaybackSource?
    }

    let item: Item
    @State private var loader: ClipPlaybackLoader?
    @State private var document: AnimatedDocument?
    @State private var settings = StickerControlSettings()
    @State private var assets = StickerRenderAssets()
    @State private var loadedDocuments: [AnimatedDocument]?
    @State private var playbackOrigin = Date()
    @State private var failure: String?
    @State private var showingControls = false
    @State private var controlsHeight: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(item: Item) {
        self.item = item
        _loader = State(initialValue: item.source.map { ClipPlaybackLoader(stickerID: item.id, source: $0) })
    }

    /// Speed never changes which artwork a pose needs, so the slider does not reload it.
    private var assetDocuments: [AnimatedDocument]? {
        guard let document else { return nil }
        return (try? settings.playbackDocuments(document))?.map { resolved in
            var resolved = resolved
            resolved.speed = 1
            return resolved
        }
    }
    private var artworkIsReady: Bool {
        document != nil && settings.canPlay && assetDocuments != nil && loadedDocuments == assetDocuments
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                stage
                    .padding(24)
                    .padding(.bottom, showingControls ? controlsHeight : 0)
                    .animation(.easeOut(duration: 0.2), value: showingControls)
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { Haptics.tap(.light); dismiss() }
                        .accessibilityIdentifier("clip-viewer-close")
                }
                if document?.configuration != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Poses", systemImage: "switch.2") { showingControls.toggle() }
                            .accessibilityIdentifier("clip-viewer-poses")
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .task { await loadBundle() }
        .task(id: assetDocuments) { await loadArtwork() }
        .onChange(of: settings) { _, _ in playbackOrigin = Date() }
        .sheet(isPresented: $showingControls) { controls }
    }

    @ViewBuilder private var stage: some View {
        if let document, artworkIsReady {
            StickerConfiguredPreview(document: document, settings: settings, assets: assets, origin: playbackOrigin)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("clip-viewer-live")
        } else {
            ZoomableArtwork(artwork: item.artwork)
                .overlay(alignment: .bottom) {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.white.opacity(0.14), in: Capsule())
                            .accessibilityIdentifier("clip-viewer-poses-unavailable")
                    } else if loader != nil {
                        ProgressView().tint(.white).padding(.bottom, 12)
                    }
                }
                .accessibilityLabel(item.title)
                .accessibilityIdentifier("clip-viewer-artwork")
        }
    }

    @ViewBuilder private var controls: some View {
        if let document {
            NavigationStack {
                StickerBackground {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if settings.canPlay && !artworkIsReady && failure == nil {
                                PosterProgress(message: String(localized: "Loading artwork…"))
                            }
                            StickerPlaybackControls(document: document, settings: $settings, origin: playbackOrigin)
                            Button("Reset") { settings = .defaults(for: document) }
                                .buttonStyle(.posterSecondaryCompact)
                        }
                        .padding(20)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                    }
                }
                .navigationTitle("Poses")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingControls = false }
                    }
                }
            }
            .foregroundStyle(AppColors.ink)
            .fontDesign(.rounded)
            .tint(AppColors.accent)
            .presentationDetents([.fraction(0.4), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationBackground(AppColors.paper)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height + geometry.safeAreaInsets.bottom
            } action: { controlsHeight = $0 }
            .accessibilityIdentifier("clip-viewer-controls")
        }
    }

    private func loadBundle() async {
        guard let loader, document == nil else { return }
        do {
            let bundle = try await loader.load()
            settings = .defaults(for: bundle.document)
            document = bundle.document
            showingControls = true
        } catch where !QuickModeModel.isCancellation(error) { failure = error.localizedDescription } catch {}
    }

    private func loadArtwork() async {
        guard let loader, let assetDocuments, let document else { return }
        do {
            let loaded = try await loader.assets(for: try settings.playbackDocuments(document))
            try Task.checkCancellation()
            assets = loaded
            loadedDocuments = assetDocuments
            failure = nil
            playbackOrigin = Date()
        } catch where !QuickModeModel.isCancellation(error) { failure = error.localizedDescription } catch {}
    }
}

/// Pinch and double-tap zoom over the sticker's published artwork.
private struct ZoomableArtwork: View {
    let artwork: ClipStickerViewer.Artwork?
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scaleEffect(min(4, max(1, scale * pinch)))
            .gesture(MagnifyGesture()
                .updating($pinch) { value, state, _ in state = value.magnification }
                .onEnded { value in scale = min(4, max(1, scale * value.magnification)) })
            .onTapGesture(count: 2) { withAnimation(.snappy) { scale = scale > 1 ? 1 : 2 } }
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder private var content: some View {
        switch artwork {
        case .image(let image): Image(uiImage: image).resizable().scaledToFit()
        case .url(let url): AnimatedClipPreview(url: url)
        case nil: Image(systemName: "photo").font(.system(size: 56)).foregroundStyle(.white.opacity(0.5))
        }
    }
}
