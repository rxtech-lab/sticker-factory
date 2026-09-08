import SwiftUI
import UIKit

/// Sends one of this app's packs to WhatsApp or Telegram.
///
/// The pack is cut into whatever the messenger accepts — one part per kind, none larger than the
/// cap — and the prepared file for every sticker is fetched the moment the sheet opens: there is
/// no button to press first, because nothing here is encoded, only downloaded. Each part then gets
/// its own button, because both messengers take one pack per hand-off: the person finishes adding
/// it there and comes back for the next.
struct MessengerExportSheet: View {
    @State private var model: MessengerPackExportModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isInstalled = true
    @State private var editingStickerID: String?
    @State private var emojiDraft = ""
    @State private var isEditingEmoji = false

    init(destination: MessengerDestination, pack: StickerPackDetail, api: StickerAPIClientProtocol) {
        _model = State(initialValue: MessengerPackExportModel(destination: destination, pack: pack, api: api))
    }

    private var destination: MessengerDestination { model.destination }
    private var outcome: MessengerSplitOutcome { model.outcome }

    var body: some View {
        NavigationStack {
            StickerBackground {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summary
                        if !isInstalled { notInstalled }
                        if let progress = model.progress { progressCard(progress) }
                        if case .failed(let message) = model.phase { ErrorBanner(message: message) }
                        if let error = model.errorMessage { ErrorBanner(message: error) }
                        if model.phase == .cancelled { cancelledCard }
                        ForEach(outcome.parts) { part in
                            partCard(part)
                        }
                        if !outcome.skipped.isEmpty { skippedCard }
                        if !model.excluded.isEmpty { excludedCard }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(String(localized: "Add to \(destination.label)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        model.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("messenger-export-close")
                }
            }
        }
        .task {
            isInstalled = destination.isInstalled
            // Straight to work: the files were made when the pack was saved, so all that stands
            // between opening and sending is a download, and a download needs no confirmation.
            if model.phase == .idle, !outcome.parts.isEmpty { model.prepare() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { isInstalled = destination.isInstalled }
        }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled()
        .alert("Edit emoji", isPresented: $isEditingEmoji) {
            TextField("Emoji", text: $emojiDraft)
            Button("Cancel", role: .cancel) { editingStickerID = nil }
            Button("Save") {
                if let stickerID = editingStickerID {
                    model.emojis[stickerID] = MessengerEmojiStore.singleEmoji(emojiDraft)
                        ?? MessengerEmojiStore.defaultEmoji
                }
                editingStickerID = nil
            }
        } message: {
            Text("Choose an emoji for this sticker in the exported pack.")
        }
        .accessibilityIdentifier("messenger-export-sheet")
    }

    // MARK: - Header

    private var summary: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(destination.logoAsset)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.pack.title)
                    .font(.posterDisplay(22, weight: .heavy))
                    .foregroundStyle(AppColors.ink)
                Text(summaryText)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("messenger-export-summary")
    }

    private var summaryText: String {
        let limits = destination.limits
        let parts = outcome.parts
        let kinds = Set(parts.map(\.kind))
        var lines: [String] = []
        if parts.count == 1 {
            lines.append(String(localized: "Becomes one \(destination.label) pack."))
        } else if parts.count > 1 {
            lines.append(String(localized: "Becomes \(parts.count) \(destination.label) packs."))
            if kinds.count > 1 {
                lines.append(String(localized: "\(destination.label) keeps still and animated stickers in separate packs."))
            }
            if parts.contains(where: { $0.count > 1 }) {
                lines.append(String(localized: """
                    A \(destination.label) pack holds at most \(limits.maximumStickers) stickers, so \
                    larger groups are split evenly.
                    """))
            }
        } else {
            lines.append(String(localized: "Nothing in this pack can be sent to \(destination.label) yet."))
        }
        lines.append(String(localized: """
            Each pack is handed over on its own. \
            Finish adding it in \(destination.label), then come back for the next.
            """))
        return lines.joined(separator: " ")
    }

    private var notInstalled: some View {
        NoticeBanner(message: String(localized: """
            You can prepare this export now. \
            Install \(destination.label), then come back to add the pack.
            """))
            .accessibilityIdentifier("messenger-not-installed")
    }

    private func progressCard(_ progress: MessengerExportProgress) -> some View {
        PosterCard(padding: 14, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().tint(AppColors.coral)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Preparing \(progress.completed + 1) of \(progress.total) · \(progress.stickerTitle)"))
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppColors.ink)
                            .lineLimit(1)
                        if let detail = progress.detail {
                            Text(detail)
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(AppColors.muted)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancel() }
                        .buttonStyle(.posterSecondaryCompact)
                        .accessibilityIdentifier("messenger-export-cancel")
                }
                ProgressView(value: progress.fraction)
                    .tint(AppColors.coral)
            }
        }
        .accessibilityIdentifier("messenger-export-progress")
    }

    private var cancelledCard: some View {
        PosterCard(padding: 14, shadow: Poster.smallShadow) {
            HStack {
                Text("Stopped before every sticker was ready.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                Spacer(minLength: 8)
                Button("Resume") { model.prepare() }
                    .buttonStyle(.posterCompact)
                    .accessibilityIdentifier("messenger-export-resume")
            }
        }
    }

    // MARK: - Parts

    private func partCard(_ part: MessengerPackPart) -> some View {
        PosterCard(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                partHeader(part)
                ForEach(part.stickers) { sticker in
                    stickerRow(sticker)
                }
                partFooter(part)
            }
        }
        // `.contain`, or the card's identifier is stamped onto every row inside it and the rows'
        // own identifiers — the ones the tests and assistive tech find stickers by — disappear.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messenger-part-\(part.id)")
    }

    @ViewBuilder
    private func partHeader(_ part: MessengerPackPart) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if destination.namesPackInApp {
                Text(part.title)
                    .font(.posterDisplay(18, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                Text("Telegram asks for the pack's name when it opens.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(AppColors.muted)
            } else {
                TextField("Pack name", text: Binding(
                    get: { model.partTitles[part.id] ?? part.title },
                    set: { model.partTitles[part.id] = $0 }
                ))
                .font(.posterDisplay(18, weight: .bold))
                .foregroundStyle(AppColors.ink)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("messenger-part-title-\(part.id)")
            }
            HStack(spacing: 6) {
                Text(part.kind.label).posterLabelStyle(9, color: AppColors.muted)
                Text("·").posterLabelStyle(9, color: AppColors.faint)
                Text(part.stickers.count == 1
                    ? String(localized: "1 sticker")
                    : String(localized: "\(part.stickers.count) stickers"))
                    .posterLabelStyle(9, color: AppColors.muted)
            }
        }
    }

    private func stickerRow(_ sticker: Sticker) -> some View {
        HStack(spacing: 12) {
            preview(for: sticker)
                .frame(width: 56, height: 56)
                .padding(4)
                .posterSurface(cornerRadius: Poster.chipRadius, fill: AppColors.paper, lineWidth: Poster.hairline, offset: Poster.noShadow)

            VStack(alignment: .leading, spacing: 3) {
                Text(sticker.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppColors.ink)
                    .lineLimit(1)
                status(for: sticker)
            }
            Spacer(minLength: 8)

            if let failure = model.failures[sticker.id] {
                Button("Exclude") { model.exclude(sticker.id) }
                    .buttonStyle(.posterSecondaryCompact)
                    .accessibilityIdentifier("messenger-exclude-\(sticker.id)")
                    .accessibilityHint(failure)
            } else {
                emojiEditButton(for: sticker)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messenger-sticker-\(sticker.id)")
    }

    @ViewBuilder
    private func preview(for sticker: Sticker) -> some View {
        if let prepared = model.rendered[sticker.id] {
            MessengerPreparedPreview(prepared: prepared, sticker: sticker, api: model.api)
        } else {
            StickerThumbnail(sticker: sticker, api: model.api)
        }
    }

    @ViewBuilder
    private func status(for sticker: Sticker) -> some View {
        if let failure = model.failures[sticker.id] {
            Text(failure)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppColors.coral)
                .fixedSize(horizontal: false, vertical: true)
        } else if let rendered = model.rendered[sticker.id] {
            Text(Self.statusText(rendered))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppColors.muted)
        } else {
            Text("Waiting…")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppColors.faint)
        }
    }

    /// "412 KB · 1.2 s", read off the server's record of the file rather than a local decode.
    ///
    /// The "sped up 2.1× to fit" note that used to sit here is gone with the encoding. That factor
    /// was a fact about a render happening right then; the render now happened when the sticker was
    /// added to the pack, possibly on someone else's phone, and the sheet is no longer the place
    /// that trade-off is made or explained.
    static func statusText(_ prepared: MessengerPreparedSticker) -> String {
        var pieces = [ByteCountFormatter.string(fromByteCount: Int64(prepared.byteCount), countStyle: .file)]
        if prepared.isAnimated, let milliseconds = prepared.durationMilliseconds, milliseconds > 0 {
            let seconds = Double(milliseconds) / 1_000
            pieces.append(String(localized: "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"))
        }
        return pieces.joined(separator: " · ")
    }

    private func emojiEditButton(for sticker: Sticker) -> some View {
        Button {
            editingStickerID = sticker.id
            emojiDraft = model.emojis[sticker.id] ?? MessengerEmojiStore.defaultEmoji
            isEditingEmoji = true
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColors.ink)
                .frame(width: 44, height: 44)
                .posterSurface(cornerRadius: Poster.chipRadius, fill: AppColors.card, lineWidth: Poster.hairline, offset: Poster.noShadow)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit emoji for \(sticker.title)")
        .accessibilityIdentifier("messenger-emoji-\(sticker.id)")
    }

    private func restoreDefaultIfEmpty(_ stickerID: String) {
        if (model.emojis[stickerID] ?? "").isEmpty { model.emojis[stickerID] = MessengerEmojiStore.defaultEmoji }
    }

    @ViewBuilder
    private func partFooter(_ part: MessengerPackPart) -> some View {
        let blockers = model.blockers(for: part)
        if model.handedOff.contains(part.id) {
            NoticeBanner(message: String(localized: """
                Handed to \(destination.label). Finish adding it there; \
                send it again if \(destination.label) did not pick it up.
                """))
        }
        if !blockers.isEmpty, model.phase != .preparing {
            Text(blockers.count == 1
                ? String(localized: "Exclude “\(blockers[0].title)” to send this pack without it.")
                : String(localized: "Exclude the \(blockers.count) stickers that could not be prepared to send this pack without them."))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppColors.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button {
            Haptics.tap(.medium)
            for sticker in part.stickers { restoreDefaultIfEmpty(sticker.id) }
            model.send(part)
        } label: {
            Label(
                model.handedOff.contains(part.id)
                    ? String(localized: "Send to \(destination.label) again")
                    : String(localized: "Add to \(destination.label)"),
                systemImage: "arrow.up.forward.app"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(model.handedOff.contains(part.id) ? .posterSecondary : .poster)
        .disabled(!isInstalled || !model.isReady(part) || !blockers.isEmpty)
        .accessibilityIdentifier("messenger-send-\(part.id)")
    }

    // MARK: - Leftovers

    private var skippedCard: some View {
        PosterCard(padding: 14, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not included")
                    .font(.posterDisplay(16, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                ForEach(outcome.skipped) { skipped in
                    HStack(alignment: .top, spacing: 10) {
                        // Grayed rather than merely listed: a row that looks like every other row
                        // but cannot be sent invites a second attempt at sending it.
                        StickerThumbnail(sticker: skipped.sticker, api: model.api, isUnavailable: true)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skipped.sticker.title)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(AppColors.ink)
                            Text(skipped.reason.message(for: destination))
                                .font(.system(size: 12, design: .rounded))
                                .foregroundStyle(AppColors.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("messenger-skipped-\(skipped.id)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("messenger-skipped")
    }

    private var excludedCard: some View {
        PosterCard(padding: 14, shadow: Poster.smallShadow) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Excluded")
                    .font(.posterDisplay(16, weight: .bold))
                    .foregroundStyle(AppColors.ink)
                ForEach(model.pack.stickers.filter { model.excluded.contains($0.id) }) { sticker in
                    HStack(spacing: 10) {
                        StickerThumbnail(sticker: sticker, api: model.api)
                            .frame(width: 36, height: 36)
                        Text(sticker.title)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(AppColors.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Include") { model.include(sticker.id) }
                            .buttonStyle(.posterSecondaryCompact)
                            .accessibilityIdentifier("messenger-include-\(sticker.id)")
                    }
                }
            }
        }
    }
}

/// The prepared sticker as it will arrive.
///
/// A WebP plays — `ImageIO` decodes the format even though this app cannot write it — so what is
/// previewed is the exact file WhatsApp will receive, at the speed it will play there. A WebM has
/// no system decoder and nothing to fall back to now that renders carry no poster frame, so the
/// Telegram side shows the sticker's published artwork with the file's size beside it.
private struct MessengerPreparedPreview: View {
    let prepared: MessengerPreparedSticker
    let sticker: Sticker
    let api: StickerAPIClientProtocol
    @State private var animation: StickerAnimation?

    var body: some View {
        Group {
            if let animation {
                AnimatedStickerImage(animation: animation)
            } else if prepared.format == .webm {
                StickerThumbnail(sticker: sticker, api: api)
            } else if let still = UIImage(data: prepared.data) {
                Image(uiImage: still).resizable().scaledToFit()
            } else {
                StickerThumbnail(sticker: sticker, api: api)
            }
        }
        .task(id: prepared.stickerID + prepared.format.rawValue + String(prepared.byteCount)) {
            guard prepared.format == .webp, prepared.isAnimated else {
                animation = nil
                return
            }
            let data = prepared.data
            let id = "messenger-\(prepared.stickerID)-\(prepared.byteCount)"
            animation = await Task.detached(priority: .utility) {
                StickerAnimationDecoder.decode(data, id: id, maxPixelSize: StickerAnimationDetail.thumbnail.maxPixelSize)
            }.value
        }
    }
}
