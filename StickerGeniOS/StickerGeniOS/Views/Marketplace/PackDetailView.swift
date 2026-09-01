import SwiftUI

/// One pack, in full: what it is, who made it, and a way to add it.
///
/// There is deliberately no cover art at the top. The cover mosaic is built from the pack's own
/// first four members, so above the member grid it said the same thing twice and pushed the
/// stickers themselves below the fold. The header carries the words, the grid carries the artwork,
/// and the install control rides in a bar pinned to the bottom so it stays reachable however far
/// down a large pack the reader has scrolled.
struct PackDetailView: View {
    @Bindable var store: MarketplaceStore
    let packID: String
    @State private var isWorking = false
    @State private var previewedSticker: Sticker?
    @State private var isEditing = false
    /// Set by the editor when the pack is gone, so this screen pops instead of waiting on a detail
    /// the store will never hand back.
    @State private var wasDeleted = false

    @Environment(\.dismiss) private var dismiss

    private var detail: StickerPackDetail? { store.details[packID] }

    var body: some View {
        StickerBackground {
            ScrollView {
                if let detail {
                    VStack(alignment: .leading, spacing: 24) {
                        header(detail)
                        stats(detail)
                        members(detail)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                } else {
                    ProgressView("Loading pack…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 96)
                }
            }
        }
        .navigationTitle(detail?.title ?? String(localized: "Pack"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let detail { bottomBar(detail) }
        }
        .sheet(item: $previewedSticker) { sticker in
            stickerPreview(sticker)
        }
        // Popping happens on the sheet's way out rather than the moment the delete lands: dismissing
        // a sheet and its presenter in the same turn drops the animation halfway.
        .sheet(isPresented: $isEditing, onDismiss: { if wasDeleted { dismiss() } }) {
            if let detail {
                NavigationStack {
                    PackEditorView(store: store, detail: detail) {
                        wasDeleted = true
                        isEditing = false
                    }
                }
            }
        }
        .task(id: packID) { await store.loadDetail(packID: packID) }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ detail: StickerPackDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // A draft or unlisted pack looks exactly like a published one otherwise, so the state
            // leads — it is the first thing that changes how the rest of the screen should be read.
            if detail.state != .published {
                Text(detail.state.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppColors.accentSoft.opacity(0.65), in: Capsule())
            }

            Text(detail.title)
                .font(.largeTitle.weight(.bold))
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            if let summary = detail.summary, !summary.isEmpty {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            NavigationLink(value: CreatorRoute(handle: detail.creator.handle)) {
                HStack(spacing: 10) {
                    CreatorAvatar(name: detail.creator.displayName)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("by \(detail.creator.byline)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(verbatim: "@\(detail.creator.handle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .padding(.leading, 6)
                .padding(.trailing, 14)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
            }
            // `.plain`, or the row picks up the default button chrome and stacks a filled capsule
            // on top of the glass one it already draws for itself.
            .buttonStyle(.plain)
            .accessibilityIdentifier("pack-creator-button")
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The pack's numbers as a row of chips: size, reach, and recency at a glance.
    @ViewBuilder
    private func stats(_ detail: StickerPackDetail) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                PackStatChip(symbol: "square.stack.3d.up", text: Self.itemCountLabel(detail.itemCount))

                // The count of people who added this pack — the marketplace's only social signal.
                PackStatChip(symbol: "square.and.arrow.down", text: detail.installCountLabel)
                    .accessibilityIdentifier("pack-install-count")

                PackStatChip(symbol: "clock", text: Self.dateLabel(detail))
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
        // The house rule puts the keyboard away on a vertical drag; a chip strip is not that.
        .scrollDismissesKeyboard(.never)
    }

    private static func itemCountLabel(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 sticker")
            : String(localized: "\(count.formatted(.number)) stickers")
    }

    /// When the pack last became what it is now. `publishedAt` is nil for anything still a draft,
    /// which is exactly the case where the edit date is the informative one.
    private static func dateLabel(_ detail: StickerPackDetail) -> String {
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        if let published = detail.publishedAt {
            return String(localized: "Published \(published.formatted(style))")
        }
        return String(localized: "Updated \(detail.updatedAt.formatted(style))")
    }

    // MARK: - Members

    @ViewBuilder
    private func members(_ detail: StickerPackDetail) -> some View {
        if detail.stickers.isEmpty {
            EmptyStateView(
                symbol: "square.stack.3d.up",
                title: String(localized: "Nothing published right now"),
                message: String(localized: "The creator is still working on it. Anything they publish shows up here automatically.")
            )
            .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("In this pack")
                    .font(.title3.weight(.semibold))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                    ForEach(detail.stickers) { sticker in
                        Button { previewedSticker = sticker } label: {
                            // Pack members belong to their creator, not the viewer, so the card
                            // drops the draft/status line it shows in the owner's own library.
                            StickerLibraryCard(sticker: sticker, api: store.api, showsStatus: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pack-sticker-\(sticker.id)")
                    }
                }
            }
        }
    }

    // MARK: - Install

    @ViewBuilder
    private func bottomBar(_ detail: StickerPackDetail) -> some View {
        VStack(spacing: 10) {
            // The marketplace list keeps its own banner, and a pushed screen does not inherit it.
            // Without this the only sign that an install failed would be the haptic.
            if let error = store.errorMessage {
                ErrorBanner(message: error)
            }

            if detail.isMine {
                // There is nothing to install — self-install is refused server-side, since the
                // creator's own stickers already sit in their library — so the bar carries the one
                // thing the creator *can* do here. A published pack is editable exactly like a
                // draft: the change reaches everyone who added it.
                Button { openEditor() } label: {
                    Label("Edit pack", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.glassProminent)
                .tint(AppColors.accent)
                .accessibilityIdentifier("pack-edit-button")

                Text("Your own stickers are already in your library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if detail.installed {
                // Already added: the way out stays available but does not compete with the grid,
                // so it drops to plain glass while adding keeps the tinted, prominent treatment.
                Button { toggleInstall(detail) } label: { installLabel(detail) }
                    .buttonStyle(.glass)
                    .tint(.secondary)
                    .disabled(isWorking)
                    .accessibilityIdentifier("pack-install-button")
            } else {
                Button { toggleInstall(detail) } label: { installLabel(detail) }
                    .buttonStyle(.glassProminent)
                    .tint(AppColors.accent)
                    .disabled(isWorking)
                    .accessibilityIdentifier("pack-install-button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
        .animation(.snappy, value: detail.installed)
    }

    @ViewBuilder
    private func installLabel(_ detail: StickerPackDetail) -> some View {
        HStack(spacing: 8) {
            if isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: detail.installed ? "trash" : "plus")
            }
            Text(detail.installed ? "Remove from library" : "Add to library")
        }
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func openEditor() {
        Haptics.tap(.light)
        isEditing = true
    }

    private func toggleInstall(_ detail: StickerPackDetail) {
        Haptics.tap(.light)
        Task {
            isWorking = true
            defer { isWorking = false }
            await store.setInstalled(!detail.installed, packID: detail.id)
            // `setInstalled` rolls its optimistic change back and parks the reason in
            // `errorMessage` rather than throwing, so that is what says how it went.
            if store.errorMessage == nil { Haptics.success() } else { Haptics.failure() }
        }
    }

    // MARK: - Preview sheet

    /// The Library's read-only viewer, unchanged: a pack member is borrowed artwork in both places,
    /// and two sheets that differ only in their padding is one sheet too many.
    private func stickerPreview(_ sticker: Sticker) -> some View {
        NavigationStack {
            PackStickerPreview(sticker: sticker, api: store.api)
                .navigationTitle(sticker.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { previewedSticker = nil }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One of the pack's numbers, on a glass capsule.
private struct PackStatChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .glassChip()
    }
}

/// A creator's initials on a brand-tinted disc.
///
/// Stands in for the profile picture the marketplace does not store yet, and gives the byline row
/// something to anchor on now that there is no cover image above it.
private struct CreatorAvatar: View {
    let name: String

    /// Letters only: the server's last-resort display name is `@handle`, and an avatar reading "@"
    /// is worse than one reading the first letter of the handle.
    private var initials: String {
        let letters = name.split(separator: " ").compactMap { $0.first(where: \.isLetter) }.prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [AppColors.accentSoft, AppColors.secondaryAccentSoft],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 36, height: 36)
            .overlay {
                Text(initials)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppColors.accent)
            }
    }
}

#Preview {
    NavigationStack {
        PackDetailView(store: MarketplaceStore(api: MockStickerAPIClient()), packID: PreviewFixtures.pack.id)
    }
}
