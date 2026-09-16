import AnimatedView
import SwiftUI

/// Read-only artwork for a pack member, with its controls when it has any.
///
/// There is no editor here by design — the sticker belongs to its creator, and the viewer only has
/// permission to look at it. Posing is a different thing from editing and is allowed: the controls
/// answer questions the creator wrote into the document, and the answers are the viewer's own. They
/// are saved to the shared pose store, which is where the Messages extension reads the sticker's
/// current pose from, so a mood chosen here is the mood it is sent in.
///
/// Shared with the marketplace's pack detail, which presents a borrowed sticker on the same terms.
struct PackStickerPreview: View {
    let sticker: Sticker
    let api: StickerAPIClientProtocol
    /// Whether the server will hand this account the sticker's playback bundle.
    ///
    /// Owning the sticker or having the pack installed is what the endpoint authorizes, and a pack
    /// that has only been browsed is neither. Passing `false` there is what keeps the marketplace
    /// from asking a question it already knows the answer to, and turns the controls section into
    /// the one sentence that says what would unlock them.
    var canControl = true

    @State private var bundle: StickerPlaybackBundle?
    @State private var settings = StickerControlSettings()
    @State private var assetStore = StickerAssetStore()
    /// The resolved document the store actually holds artwork for. Until it matches the pose on
    /// screen the preview keeps showing the published thumbnail rather than a half-loaded render.
    @State private var loadedDocuments: [AnimatedDocument]?
    @State private var playbackOrigin = Date()
    @State private var exportRequest: StickerViewerExportRequest?
    @State private var errorMessage: String?
    @State private var isLoading = false

    /// Whoever is signed in, and a stable stand-in when nobody is — the same key the full-screen
    /// player and the Messages extension pose under, so the three agree on one saved pose.
    private var accountID: String { (try? SharedKeychainTokenVault().load()?.subject) ?? "local" }

    private var playbackDocuments: [AnimatedDocument]? {
        guard let bundle else { return nil }
        return try? settings.playbackDocuments(bundle.document)
    }
    private var artworkIsReady: Bool { settings.canPlay && playbackDocuments != nil && loadedDocuments == playbackDocuments }

    var body: some View {
        StickerBackground {
            ScrollView {
                VStack(spacing: 16) {
                    artwork
                        .aspectRatio(1, contentMode: .fit)
                        .padding(18)
                        .posterSurface(cornerRadius: Poster.cardRadius, fill: AppColors.paper)
                        .padding(20)

                    labels

                    controlsSection
                        .padding(.horizontal, 20)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .task(id: sticker.playbackRevisionId) { await loadBundle() }
        // Every pose is a different document, and each needs its own artwork before it can be
        // drawn. Keyed on the resolved document rather than on the settings so two settings that
        // resolve to the same thing — a still frame moved while `animate` is off, say — do not
        // reload anything.
        .task(id: playbackDocuments) { await loadArtwork() }
        .onChange(of: settings) { _, updated in playbackOrigin = Date(); savePose(updated) }
        .sheet(item: $exportRequest) { StickerViewerExportSheet(request: $0) }
    }

    // MARK: - Artwork

    /// The published thumbnail until a pose can be drawn, then the pose itself.
    ///
    /// Not a spinner in between: the sticker's own artwork is already cached from the grid the
    /// reader tapped, and swapping it for a progress view to load a document that draws the same
    /// picture reads as the sheet losing the sticker.
    @ViewBuilder private var artwork: some View {
        if let bundle, artworkIsReady {
            StickerConfiguredPreview(document: bundle.document, settings: settings,
                assets: assetStore.renderAssets, origin: playbackOrigin)
            .accessibilityIdentifier("pack-sticker-posed-artwork")
        } else {
            // `.preview`: one sticker filling a sheet can afford frames at twice the size a
            // grid tile decodes them at.
            StickerThumbnail(sticker: sticker, api: api, detail: .preview)
        }
    }

    /// What kind of sticker this is, and whether it is one that can be posed.
    private var labels: some View {
        HStack(spacing: 8) {
            Text(sticker.kind.label)
                .posterLabelStyle(10, color: AppColors.muted)

            if sticker.isControllable {
                Label {
                    Text("Controllable")
                } icon: {
                    Image("ControllableSticker")
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                }
                    .posterLabelStyle(9)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .posterCapsule(fill: AppColors.sky, lineWidth: 1, offset: Poster.noShadow)
                    .accessibilityIdentifier("pack-sticker-controllable-badge")
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder private var controlsSection: some View {
        if sticker.isControllable {
            VStack(alignment: .leading, spacing: 14) {
                PosterListHeader("Controls")

                if !canControl {
                    NoticeBanner(message: String(localized: "Add this pack to your library to pose this sticker."))
                } else if let bundle {
                    StickerPlaybackControls(document: bundle.document, settings: $settings, origin: playbackOrigin)
                    Button {
                        exportRequest = .init(document: bundle.document, settings: settings, assets: assetStore.renderAssets)
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.posterSecondaryCompact)
                    .disabled(!artworkIsReady)
                    .accessibilityIdentifier("sticker-viewer-export")

                    HStack(spacing: 10) {
                        Button("Reset") { settings = .defaults(for: bundle.document) }
                            .buttonStyle(.posterSecondaryCompact)
                            .accessibilityIdentifier("pack-sticker-controls-reset")
                        Spacer(minLength: 8)
                        if settings.canPlay && !artworkIsReady { ProgressView().controlSize(.small).tint(AppColors.ink) }
                    }
                } else if isLoading {
                    PosterProgress(message: String(localized: "Loading controls…"))
                        .frame(maxWidth: .infinity)
                }

                if let errorMessage {
                    ErrorBanner(message: errorMessage)
                    Button("Retry loading") { Task { await loadBundle() } }
                        .buttonStyle(.posterSecondaryCompact)
                }
            }
            .accessibilityIdentifier("pack-sticker-controls")
        }
    }

    // MARK: - Work

    private func loadBundle() async {
        guard canControl, let revisionID = sticker.playbackRevisionId, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await api.stickerPlayback(stickerID: sticker.id, revisionID: revisionID)
            try Task.checkCancellation()
            // The summary said this sticker has controls and the bundle says it does not, which
            // only happens against a revision that has moved on. Refusing here keeps the section
            // from drawing an empty list of rows under a heading promising some.
            guard loaded.document.configuration != nil else {
                errorMessage = String(localized: "This sticker's controls are unavailable.")
                return
            }
            // The saved pose first, so reopening the sheet finds the sticker as it was left — and
            // reconciled against this document, so a control the creator has since changed falls
            // back to its default rather than to an answer that no longer means anything.
            settings = StickerControlPreferences().load(
                accountID: accountID, stickerID: sticker.id, document: loaded.document
            )
            bundle = loaded
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadArtwork() async {
        guard let target = playbackDocuments, loadedDocuments != target else { return }
        for document in target {
            guard !Task.isCancelled else { return }
            await assetStore.preload(document: document, api: api)
        }
        guard !Task.isCancelled, target == playbackDocuments else { return }
        guard target.allSatisfy({ assetStore.renderAssets.containsArtwork(for: $0) }) else {
            errorMessage = String(localized: "A sticker frame could not be rendered.")
            return
        }
        errorMessage = nil
        loadedDocuments = target
        playbackOrigin = Date()
    }

    /// Poses are per person, not per sticker: they are written to this account's own shared
    /// defaults, which is where the Messages extension looks when it sends this sticker.
    private func savePose(_ updated: StickerControlSettings) {
        guard let bundle else { return }
        try? StickerControlPreferences().save(
            updated, accountID: accountID, stickerID: sticker.id, document: bundle.document
        )
    }
}

#Preview {
    NavigationStack {
        PackStickerPreview(sticker: PreviewFixtures.borrowedSticker, api: MockStickerAPIClient())
            .navigationTitle(PreviewFixtures.borrowedSticker.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
